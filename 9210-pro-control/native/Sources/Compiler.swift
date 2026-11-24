import Foundation

struct CompiledStep: Identifiable {
    let id: String
    let step: Step
    let bytes: Data?
    let fields: [String:Int]
    let positionMM: [Double]
    var saved: JSONObject { ["id":id,"raw":step.raw,"sourceIndex":step.sourceIndex,"hex":bytes?.hex ?? "","fields":fields,"positionMM":positionMM] }
}
struct CommandSchema {
    let classes: [String:[JSONObject]]
    init(url: URL) throws {
        guard let rows = try jsonObject(Data(contentsOf:url)) as? [JSONObject] else { throw ControlError.invalid("命令字段清单格式错误") }
        var classes: [String:[JSONObject]] = [:]
        for row in rows {
            // MixWellBean repeats annotation order 27. The extracted .31
            // firmware consumes rear air at full-frame byte 73 and its Z
            // coordinate at byte 77; alphabetical reflection order reverses them.
            let tieOrder = row.text("class")=="MixWellBean" ? ["rearAirSuctionDosage":0,"mixWellEmptyPos":1] : [:]
            classes[row.text("class")] = row.array("fields").sorted {
                if $0.integer("order") != $1.integer("order") { return $0.integer("order") < $1.integer("order") }
                let left=tieOrder[$0.text("name")] ?? 2,right=tieOrder[$1.text("name")] ?? 2
                return left==right ? $0.text("name") < $1.text("name") : left<right
            }
        }
        self.classes = classes
    }
    func encode(_ name: String, _ values: [String:Int]) throws -> Data {
        guard let fields = classes[name] else { throw ControlError.invalid("缺少命令模型 \(name)") }
        let names=Set(fields.map { $0.text("name") })
        let unknown=Set(values.keys).subtracting(names).sorted()
        guard unknown.isEmpty else { throw ControlError.invalid("命令 \(name) 包含未定义字段：\(unknown.joined(separator:"、"))") }
        var bytes: [UInt8] = []
        for field in fields {
            if let literal = field["literal_bytes"] as? [Int] { bytes += literal.map { UInt8(truncatingIfNeeded:$0) }; continue }
            let key = field.text("name")
            let value = values[key] ?? Int(field.text("initializer")) ?? 0
            let type = field.text("java_type")
            guard type == "int" || type == "byte" else { throw ControlError.invalid("此模型字段类型尚未支持：\(name).\(key)") }
            let width = type == "byte" || field.integer("type") == 0 ? 1 : field.integer("type") == 1 ? 2 : 4
            var encoded = try Wire.integer(value,width:width)
            if field["isTrue"] as? Bool == false { encoded.reverse() }
            bytes += encoded
        }
        return try Wire.frame(payload:bytes)
    }
}

struct Compiler {
    let workspace: Workspace
    let schema: CommandSchema
    var config: JSONObject { workspace.config }
    func finite(_ raw: String, label: String, allowEmpty: Bool = false) throws -> Double {
        let raw=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if raw.isEmpty, allowEmpty { return 0 }
        guard let value = Double(raw), value.isFinite else { throw ControlError.invalid("\(label)必须为有限数字") }
        return value
    }
    func num(_ object: JSONObject, _ key: String) throws -> Double { try finite(object.text(key),label:key) }
    func whole(_ object: JSONObject,_ key:String,within bounds:ClosedRange<Int>) throws -> Int {
        guard let n=exactIntegerValue(object.text(key)),bounds.contains(n) else { throw ControlError.invalid("\(key) 应为 \(bounds.lowerBound)–\(bounds.upperBound) 的整数") }
        return n
    }
    func axis(_ coordinate: Double, _ axis: String, javaFloatProduct: Bool = true) throws -> Int {
        let coefficient = try num(config,axis + "Coefficient")
        let pitch = try num(config,axis + "ScrewPitch")
        guard pitch > 0, coefficient > 0 else { throw ControlError.invalid("\(axis) 轴导程／系数必须大于 0") }
        let product = javaFloatProduct ? Double(Float(coordinate) * Float(coefficient)) : coordinate * coefficient
        let value = floor(product / pitch * 10.0 * 0.1)
        guard value.isFinite, value >= 0, value <= Double(Int32.max) else { throw ControlError.invalid("\(axis) 轴目标步数无效：\(coordinate)") }
        return Int(value)
    }
    func speed(_ type: String, _ gear: Int) throws -> (Int,Int) {
        let value=try workspace.checkedSpeedSetting(type,gear:gear)
        return (value.acceleration,value.speed)
    }
    func motionSpeed(_ type:String,program:Program) throws -> (Int,Int) {
        guard let value=program.motionSpeeds[type] else { return try speed(type,whole(config,ProgramSpeed.configKeys[type]!,within:1...10)) }
        guard (1...10).contains(value.gear),(0...255).contains(value.acceleration),(0...255).contains(value.speed) else { throw ControlError.invalid("程序的 \(ProgramSpeed.labels[type] ?? type) 速度档应为1–10，速度／加速度应为0–255") }
        return (value.acceleration,value.speed)
    }
    func volume(_ value: Double, range: Int, liquid: Int) throws -> Int {
        guard value.isFinite, value >= 0 else { throw ControlError.invalid("体积必须非负") }
        // Zero means no plunger stroke. The calibration intercept applies only
        // when a positive amount is requested, including optional air/blow phases.
        if value==0 { return 0 }
        let curves = workspace.tables["Curve"] as? [JSONObject] ?? []
        var matches:[JSONObject]=[]
        for curve in curves {
            let curveRange=try whole(curve,"range",within:1...Int(Int32.max))
            let liquidID=try whole(curve,"liquid_id",within:1...Int(Int32.max))
            if curveRange==range,liquidID==liquid { matches.append(curve) }
        }
        guard matches.count<=1 else { throw ControlError.invalid("液体 \(liquid) 的 \(range) µL 曲线重复，请在液体曲线中保留一条") }
        guard let c = matches.first else { throw ControlError.invalid("缺少 \(range) µL／液体 \(liquid) 的标定曲线") }
        let proportion = try num(config,"imbProportion")
        guard proportion > 0 else { throw ControlError.invalid("柱塞换算比例必须大于 0") }
        let result = (value * (try num(c,"parameter1")) + (try num(c,"parameter2"))) / proportion
        guard result.isFinite, result >= 0, result < Double(Int32.max) - 1 else { throw ControlError.invalid("体积换算结果超出范围") }
        return Int(floor(result + 0.5))
    }
    func compensated(_ dose: Double, raw: JSONObject, range: Int) throws -> Double {
        let rows = workspace.tables["LiquidCompensation"] as? [JSONObject] ?? []
        var result = dose
        let type=raw["type"] == nil ? 0 : try whole(raw,"type",within:Int(Int32.min)...Int(Int32.max))
        let liquid=raw["liquid_id"] == nil ? 1 : try whole(raw,"liquid_id",within:1...Int(Int32.max))
        for c in rows {
            let rowType=try whole(c,"trapping_type",within:Int(Int32.min)...Int(Int32.max))
            let rowRange=try whole(c,"module",within:1...Int(Int32.max))
            let rowLiquid=try whole(c,"liquid_id",within:1...Int(Int32.max))
            let nature=try whole(c,"nature",within:0...1)
            guard rowType==type,rowRange==range,rowLiquid==liquid else { continue }
            let lower = try num(c,"start_imbibing"), upper = try num(c,"end_imbibing")
            guard lower>=0,upper>=lower else { throw ControlError.invalid("液体补偿区间应为非负且结束量不小于起始量") }
            if dose > lower && dose <= upper {
                let amount=try num(c,"compensation")
                guard amount>=0 else { throw ControlError.invalid("液体补偿量不能为负数，请使用增减方向设置") }
                result = dose + (nature == 1 ? -1 : 1) * amount
            }
        }
        guard result.isFinite,result >= 0 else { throw ControlError.invalid("液体补偿后的体积必须为非负有限数字") }
        return result
    }
    func compile(_ program: Program) throws -> [CompiledStep] {
        try program.expanded().enumerated().map { i,step in
            do { return try compile(step,program:program) }
            catch { throw ControlError.invalid("第 \(i+1) 个执行动作（\(step.name)）：\(error.localizedDescription)") }
        }
    }
    func compile(_ step: Step, program: Program) throws -> CompiledStep {
        let headRange=try workspace.resolvedTableHeadRange(program.worktableID)
        guard program.range==headRange else {
            throw ControlError.invalid("程序为 \(program.range) µL，板位组合对应 \(headRange) µL 移液头，请重新选择板位组合以同步量程")
        }
        let raw = step.raw; let event = try whole(raw,"event_type",within:1...9)
        if event==9 { return try compileSegmentedAspiration(step,program:program) }
        guard event != 8 else { throw ControlError.invalid("循环需要先展开后编译") }
        if let value=raw["auxiliary_functions"],!(value is [JSONObject]) { throw ControlError.invalid("辅助段清单格式错误") }
        let assists=raw.array("auxiliary_functions")
        let supported:[Int:Set<Int>]=[1:[5],2:[5],3:[1,2,3,5],4:[1,3,4,5,6,7,8,9],5:[1,2,3,4,5],6:[],7:[]]
        var assistIDs=Set<Int>()
        for assist in assists {
            let id=try whole(assist,"id",within:1...9)
            guard supported[event]!.contains(id) else { throw ControlError.invalid("\(step.name)不支持辅助段 \(id)") }
            guard assistIDs.insert(id).inserted else { throw ControlError.invalid("辅助段 \(id) 重复；每种辅助段只能设置一次") }
        }
        guard assistIDs.intersection(Set(6...9)).count<=1 else { throw ControlError.invalid("靠壁／贴壁只能选择一个方向和方式") }
        if event == 7 {
            let seconds = try finite(raw.text("wait_time"),label:"等待时间")
            guard seconds >= 0, seconds <= 86400 else { throw ControlError.invalid("等待时间应为 0–86400 秒") }
            return CompiledStep(id:step.id,step:step,bytes:nil,fields:[:],positionMM:[])
        }
        guard (1...6).contains(event) else { throw ControlError.invalid("无法编译动作类型 \(event)") }
        let tables=(workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.number("id",.nan)==Double(program.worktableID) }
        guard tables.count==1,let table=tables.first else { throw ControlError.invalid("台面 ID \(program.worktableID) 缺失或重复") }
        let plates = table.array("WorkTablets")
        guard try whole(table,"Model",within:1...1)==1 else { throw ControlError.invalid("当前编译器支持 9210 的 Model=1 台面") }
        guard !plates.isEmpty else { throw ControlError.invalid("所选台面没有板位") }
        if table["platesNumber"] != nil { guard try whole(table,"platesNumber",within:1...Int(Int32.max))==plates.count else { throw ControlError.invalid("台面板位数量与 platesNumber 不一致") } }
        for (index,item) in plates.enumerated() {
            guard try whole(item,"Number",within:1...plates.count)==index+1 else { throw ControlError.invalid("台面板位 Number 必须按 1–\(plates.count) 排列，不能重复或错位") }
        }
        let plateNumber:Int
        if event==6 {
            let configured=config["shockPlate"] == nil ? 0 : try whole(config,"shockPlate",within:0...plates.count)
            plateNumber=configured==0 ? 1 : configured
        } else { plateNumber=try whole(raw,"plate_number",within:1...plates.count) }
        let plateIndex = plateNumber-1
        guard plates.indices.contains(plateIndex) else { throw ControlError.invalid("台面中没有 T\(plateIndex+1)") }
        let plate = plates[plateIndex]; let material = plate.object("Material")
        let x0 = Float(try num(plate,"XPos")); let y0 = Float(try num(plate,"YPos"))
        if event == 6 {
            _ = try whole(raw,"oscillation_switch",within:0...1)
            _ = try whole(raw,"oscillation_time",within:0...65535)
            _ = try whole(raw,"oscillation_frequency",within:0...65535)
            let requested=raw["module_number"] == nil ? 0 : try whole(raw,"module_number",within:0...255)
            let global=requested==0 ? (config["shockModuleNumber"] == nil ? 1 : try whole(config,"shockModuleNumber",within:0...255)) : 0
            let module=requested==0 ? (global==0 ? 1 : global) : requested
            let values = ["xPos":try axis(Double(x0),"x"),"yPos":try axis(Double(y0),"y"),"oscillationSwitch":raw.integer("oscillation_switch"),"time":raw.integer("oscillation_time"),"frequency":raw.integer("oscillation_frequency"),"moduleNumber":module]
            return CompiledStep(id:step.id,step:step,bytes:try schema.encode("MetalBathBean",values),fields:values,positionMM:[Double(x0),Double(y0)])
        }
        guard !material.isEmpty else { throw ControlError.invalid("板位耗材配置缺失") }
        let rows=try whole(material,"HoleRow",within:1...48),columns=try whole(material,"HoleColum",within:1...48)
        _ = try whole(raw,"x_axis",within:0...(rows-1))
        _ = try whole(raw,"y_axis",within:0...(columns-1))
        if event == 3 || event == 4 { _ = try whole(raw,"speed",within:1...10) }
        if event == 5 {
            _ = try whole(raw,"mix_times",within:1...255)
            _ = try whole(raw,"mix_imb_speed",within:1...10)
            _ = try whole(raw,"mix_trap_speed",within:1...10)
        }
        let xSpacingValue=try num(material,"XSpacing"),ySpacingValue=try num(material,"YSpacing")
        guard xSpacingValue>=0,ySpacingValue>=0 else { throw ControlError.invalid("孔间距 XSpacing／YSpacing 不能为负数") }
        let xSpacing = Float(xSpacingValue)
        let ySpacing = Float(ySpacingValue)
        let xOffset = Float(raw.integer("y_axis")) * xSpacing
        let xIndex = Float(raw.integer("x_axis"))
        let is384 = columns * rows == 384
        let firstRow = plate["_macFirstRow"] as? Bool ?? (plateNumber <= plates.count / 2)
        let yOffset: Float
        if is384 { yOffset = firstRow || y0 > 20 ? -(xIndex * ySpacing) : (xIndex == 0 ? ySpacing : 0) }
        else { yOffset = (firstRow ? -1 : 1) * xIndex * xSpacing }
        let customZ = raw.text("z_customized_pos")
        let z = Float(try finite(customZ.isEmpty ? plate.text("ZPos") : customZ,label:"Z 高度"))
        let raise = event==2 ? 0 : try finite(raw.text("raise_height","0"),label:"抬升高度")
        guard raise>=0 else { throw ControlError.invalid("抬升高度不能为负数") }
        let x = Double(x0 + xOffset), y = Double(y0 + yOffset)
        let xp = try axis(x,"x"), yp = try axis(y,"y"), zp = try axis(Double(z)-raise,"z",javaFloatProduct:false)
        let xs = try motionSpeed("XSpeed",program:program), ys = try motionSpeed("YSpeed",program:program), zs = try motionSpeed("ZSpeed",program:program)
        var v: [String:Int] = ["xPos":xp,"yPos":yp,"axisType":1]
        func set(_ a: String,_ b: String,_ pair:(Int,Int)) { v[a]=pair.0;v[b]=pair.1 }
        let bean: String
        switch event {
        case 1:
            bean="LoadBean";set("xAccelerationSpeed","xSpeed",xs);set("yAccelerationSpeed","ySpeed",ys);set("zAccelerationDownSpeed","zDownSpeed",zs)
            let spacing=try num(config,"loadSecondSpacing")
            guard spacing>=0 else { throw ControlError.invalid("装头第二段距离不能为负数") }
            v["z1Pos"] = try axis(Double(z-Float(spacing)),"z")
            v["z2Pos"]=zp;set("zTakeGunAccelerationSpeed","zTakeGunSpeed",try motionSpeed("LoadSecondSpeed",program:program));set("zUpAccelerationSpeed","zUpSpeed",zs)
        case 2:
            bean="UnLoadBean";set("xAccelerationSpeed","xSpeed",xs);set("yAccelerationSpeed","ySpeed",ys);set("zDownAccelerationSpeed","zDownSpeed",zs)
            let spacing=try num(config,"unLoadSpacing")
            guard spacing>=0 else { throw ControlError.invalid("卸头距离不能为负数") }
            v["z1Pos"] = try axis(Double(z-Float(spacing)),"z")
            set("zUpAccelerationSpeed","zUpSpeed",zs);set("zUnLoadAccelerationSpeed","zUnLoadSpeed",try motionSpeed("UnLoadSpeed",program:program))
        case 3:
            bean="ImbibingBean";set("xAccelerationSpeed","xSpeed",xs);set("yAccelerationSpeed","ySpeed",ys);set("zAccelerationDownSpeed","zDownSpeed",zs)
            v["zImbibingPos"]=zp;set("imbibingAccelerationSpeed","imbibingSpeed",try speed("AspSpeed",raw.integer("speed")));set("emptyPosAccSpeed","emptyPosSpeed",zs);set("completedImbibingAccelerationSpeed","completedImbibingSpeed",zs)
        case 4:
            bean="TrappingBean";set("xAccSpeed","xSpeed",xs);set("yAccSpeed","ySpeed",ys);set("zDownAccSpeed","zDownSpeed",zs);set("zTrappingUpAccSpeed","zTrappingUpSpeed",zs)
            v["zBottleBottomPos"]=zp;v["trappingType"]=0;set("trappingAccSpeed","trappingSpeed",try speed("TrapSpeed",raw.integer("speed")))
        default:
            bean="MixWellBean";set("xAccSpeed","xSpeed",xs);set("yAccSpeed","ySpeed",ys);set("zDownAccSpeed","zDownSpeed",zs);set("mixWellCompletedImbibingZAccSpeed","mixWellCompletedImbibingZSpeed",zs)
            v["zBottleBottomPos"]=zp
            set("imbibingAccSpeed","imbibingSpeed",try speed("MixAspSpeed",raw.integer("mix_imb_speed")));set("trappingAccSpeed","trappingSpeed",try speed("MixTrapSpeed",raw.integer("mix_trap_speed")));set("afterMixImbibingAccSpeed","afterMixImbibingSpeed",try speed("MixAspSpeed",raw.integer("mix_imb_speed")))
        }
        let liquid = [3,4,5].contains(event) && raw["liquid_id"] != nil ? try whole(raw,"liquid_id",within:1...Int(Int32.max)) : 1
        func doseSteps(_ dose: Double) throws -> Int { try volume(dose,range:program.range,liquid:liquid) }
        if [3,4,5].contains(event) {
            let dose = try finite(raw.text("dose"),label:"第 \(step.sourceIndex+1) 步体积")
            guard dose > 0, dose <= Double(program.range) else { throw ControlError.invalid("体积必须大于 0 且不超过 \(program.range) µL") }
            let compensate = event==3 ? 0 : try finite(raw.text("compensate","0"),label:"额外补偿")
            if event == 3 {
                if raw["type"] != nil { _ = try whole(raw,"type",within:Int(Int32.min)...Int(Int32.max)) }
                v["imbibingDosage"] = try doseSteps(compensated(dose,raw:raw,range:program.range))
            }
            else if event == 4 { v["trappingDosage"] = try doseSteps(dose+compensate) }
            else {
                guard step.mixTimes > 0, step.mixTimes <= 255 else { throw ControlError.invalid("混匀次数应为 1–255") }
                v["mixWellDosage"] = try doseSteps(dose);v["mixWellTimes"]=step.mixTimes
                let afterDose = try finite(raw.text("dose_after_mix","0"),label:"混匀后吸液体积")
                guard afterDose>=0,afterDose<=Double(program.range) else { throw ControlError.invalid("混匀后吸液体积应为 0–\(program.range) µL") }
                let after = afterDose+compensate
                v["afterMixImbibingDosage"] = after > 0 ? try doseSteps(after) : 0
            }
        }
        for assist in assists {
            let a = assist.integer("id"); let amount = try finite(assist.text("mDose","0"),label:"辅助段体积／时间")
            guard amount >= 0 else { throw ControlError.invalid("辅助段参数不能为负数") }
            // Match an absent optional phase: no dose, no added Z movement and
            // no speed override when its requested amount is zero.
            if (2...4).contains(a),amount==0 { continue }
            switch a {
            case 1:
                guard amount<=65.535 else { throw ControlError.invalid("辅助段悬停不能超过 65.535 秒") }
                let milliseconds = Int((amount*1000).rounded())
                v[event == 3 ? "imbibingHover" : event == 4 ? "trappingHoverTime" : "mixWellEmptyTime"]=milliseconds
            case 2:
                if event == 3 || event == 5 { v["frontAirDosage"] = try doseSteps(amount) }
            case 3:
                if event == 3 { v["rearEmptyDosage"] = try doseSteps(amount) }
                if event == 5 { v["rearAirSuctionDosage"] = try doseSteps(amount) }
                if event == 4 {
                    let emptyZ=zp-(try axis(15,"z",javaFloatProduct:false))
                    guard emptyZ>=0 else { throw ControlError.invalid("排液后吸空气的 Z 位置低于 0：当前目标须至少为 15 mm") }
                    v["rearSuctionDosage"] = try doseSteps(amount);v["trappingEmptyPos"]=emptyZ
                }
            case 4:
                if event == 4 || event == 5 { v["blowSampleDosage"] = try doseSteps(amount);set("blowSampleAccSpeed","blowSampleSpeed",try motionSpeed("BlowSpeed",program:program)) }
            case 5:
                let height = try axis(num(plate,"ZGradientPos"),"z")
                v[event == 3 ? "completedImbibingPos" : event == 4 ? "zTrappingPos" : event == 5 ? "mixWellCompletedImbibingZPos" : "zUpPos"]=height
            case 6...9:
                guard event == 4 else { continue }
                let adherent = a >= 8
                let zKey = adherent ? "AdherentZ" : "AgainstZ"
                let xKey = (adherent ? "AdherentX" : "AgainstX") + ((a == 6 || a == 8) ? "Left" : "Right")
                guard plate[zKey] != nil, plate[xKey] != nil else { throw ControlError.invalid("台面缺少贴壁／靠壁坐标 \(xKey)") }
                v["zAgainstPos"] = try axis(num(plate,zKey),"z");v["xAgainstPos"] = try axis(num(plate,xKey),"x");v["trappingType"]=adherent ? 2 : 3
                if !adherent { v["zBottleMouthPos"]=zp }
            default: throw ControlError.invalid("未知辅助段 \(a)")
            }
        }
        return CompiledStep(id:step.id,step:step,bytes:try schema.encode(bean,v),fields:v,positionMM:[x,y,Double(z)-raise])
    }
}
