import Foundation

extension Workspace {
    mutating func updatePlate(tableID:Int,number:Int,_ change:(inout JSONObject)->Void) {
        var tables=self.tables["WorkTable"] as? [JSONObject] ?? []
        guard let t=tables.firstIndex(where:{ $0.integer("id")==tableID }) else { return }
        var plates=tables[t].array("WorkTablets")
        guard let p=plates.firstIndex(where:{ $0.integer("Number")==number }) else { return }
        change(&plates[p]);tables[t]["WorkTablets"]=plates;self.tables["WorkTable"]=tables
    }
    mutating func assignMaterial(_ item:JSONObject,tableID:Int,number:Int) {
        updatePlate(tableID:tableID,number:number) { plate in
            var material=plate.object("Material")
            for key in ["Name","Code","HoleRow","HoleColum","XSpacing","YSpacing","XOffset","YOffset","SupplyType","WellDiameter","IsStright"] {
                if let value=item[key] { material[key]=value }
            }
            for (source,target) in [("LengthNum","Length"),("WidthNum","Width"),("HeightNum","HeightNum"),("DepthNum","DepthNum"),("HoleDiameter","WellDiameter")] {
                if let value=item[source] { material[target]=value }
            }
            material["consumable_id"]=item["consumable_id"];plate["Material"]=material
        }
    }
    /// Mac-only metadata; vendor Dosage is not a reliable installed-head range.
    func tableHeadRange(_ id:Int)->Int? {
        let range=worktable(id).integer("_macHeadRange")
        return [20,1000].contains(range) ? range : nil
    }
    mutating func setTableHeadRange(_ id:Int,range:Int) throws {
        guard [0,20,1000].contains(range) else { throw ControlError.invalid("移液头量程只能选择20或1000 µL") }
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let index=rows.firstIndex(where:{ $0.integer("id")==id }) else { throw ControlError.invalid("找不到板位组合") }
        // Keep an explicit zero as "unspecified" so legacy inference cannot
        // silently undo the user's choice on the next save/reload.
        rows[index]["_macHeadRange"]=range
        tables["WorkTable"]=rows
        if range != 0 {
            for i in programs.indices where programs[i].worktableID==id {
                programs[i].range=range;programs[i].raw["range"]=range
            }
            for i in deletedPrograms.indices where deletedPrograms[i].worktableID==id {
                deletedPrograms[i].range=range;deletedPrograms[i].raw["range"]=range
            }
        }
    }
    var deletedTables:[JSONObject] { tables["_macDeletedWorkTables"] as? [JSONObject] ?? [] }
    func deletedPlates(tableID:Int)->[JSONObject] {
        (tables["_macDeletedPlates"] as? [JSONObject] ?? []).filter { $0.integer("tableID")==tableID }
    }
    private func nextTableID()->Int? {
        let rows=(tables["WorkTable"] as? [JSONObject] ?? [])+deletedTables
        let oldPlateTables=(tables["_macDeletedPlates"] as? [JSONObject] ?? []).map { $0.integer("tableID") }
        let used=Set((rows.map { $0.integer("id") }+oldPlateTables).filter { $0>0 })
        let highWater=(tables["_macRemovedTableHighWater"] as? Int) ?? 0
        let maximum=max(used.max() ?? 0,highWater)
        if maximum<Int(Int32.max) { return maximum+1 }
        var candidate=1
        for id in used.sorted() where id==candidate { candidate+=1 }
        return highWater==0 && candidate<=Int(Int32.max) ? candidate : nil
    }
    static func blankPlate(_ number:Int,firstRow:Bool)->JSONObject {
        ["Number":number,"Code":"T\(number)","XPos":"0","YPos":"0","ZPos":"0","ZGradientPos":"0",
         "ImbPos":"0","Material":JSONObject(),"_macFirstRow":firstRow]
    }
    mutating func createTable(name:String,range:Int,plateCount:Int=8) throws ->Int {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,[20,1000].contains(range),(1...48).contains(plateCount) else {
            throw ControlError.invalid("请填写组合名称、20或1000 µL量程及1–48个板位")
        }
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let id=nextTableID() else { throw ControlError.invalid("板位组合编号已用尽") }
        rows.append(["id":id,"Model":1,"NickName":name,"MatrixName":name,"_macHeadRange":range,
                     "WorkTablets":(1...plateCount).map { Self.blankPlate($0,firstRow:$0<=plateCount/2) },
                     "platesNumber":plateCount,"trapPlate":0,"unLoadPlate":0])
        tables["WorkTable"]=rows
        return id
    }
    mutating func copyTable(_ id:Int) -> Int? {
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard var row=rows.first(where:{ $0.integer("id")==id }) else { return nil }
        guard let next=nextTableID() else { return nil }
        row["id"]=next;row["NickName"]=row.text("NickName",row.text("MatrixName","台面"))+" 副本"
        row["MatrixName"]=row.text("NickName");rows.append(row);tables["WorkTable"]=rows
        return next
    }
    func tableProgramNames(_ id:Int)->[String] {
        programs.filter { $0.worktableID==id }.map { "\($0.name)（\($0.range) µL）" }
        + deletedPrograms.filter { $0.worktableID==id }.map { "\($0.name)（已删除程序，\($0.range) µL）" }
    }
    func tableRemovalIssue(_ id:Int)->String? {
        guard !worktable(id).isEmpty else { return "找不到板位组合" }
        let names=tableProgramNames(id)
        return names.isEmpty ? nil : "此组合仍被以下程序使用，请先给程序选择其他组合："+names.joined(separator:"、")
    }
    mutating func removeTable(_ id:Int,archive:Bool=true) throws {
        if let issue=tableRemovalIssue(id) { throw ControlError.invalid(issue) }
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let index=rows.firstIndex(where:{ $0.integer("id")==id }) else { throw ControlError.invalid("找不到板位组合") }
        let removed=rows.remove(at:index)
        tables["WorkTable"]=rows
        if archive { tables["_macDeletedWorkTables"]=deletedTables+[removed] }
        else {
            // Do not reuse a removed ID and accidentally attach an old plate or
            // manual liquid draft to a new combination.
            tables["_macRemovedTableHighWater"]=max(id,(tables["_macRemovedTableHighWater"] as? Int) ?? 0)
            if var manual=manualControls {
                manual.liquidSteps=manual.liquidSteps.filter { !$0.key.hasPrefix("\(id):") };manualControls=manual
            }
        }
        if manualControls?.tableID==id {
            let previous=manualControls!
            var replacement=ManualControlSettings.defaults(workspace:self)
            replacement.loadGear=previous.loadGear;replacement.unloadGear=previous.unloadGear
            var speeds=previous;speeds.seedMotionSpeeds(workspace:self)
            replacement.motionSpeeds=speeds.motionSpeeds
            replacement.liquidSteps=previous.liquidSteps
            manualControls=replacement
        }
    }
    mutating func restoreTable(_ id:Int) throws {
        var removed=deletedTables,rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard !rows.contains(where:{ $0.integer("id")==id }),let index=removed.firstIndex(where:{ $0.integer("id")==id }) else {
            throw ControlError.invalid("无法恢复此组合：编号不存在或已被使用")
        }
        rows.append(removed.remove(at:index));rows.sort { $0.integer("id")<$1.integer("id") }
        tables["WorkTable"]=rows;tables["_macDeletedWorkTables"]=removed
    }
    private func stepRaws(_ steps:[Step])->[JSONObject] {
        func flatten(_ raw:JSONObject)->[JSONObject] {
            raw.integer("event_type")==8 ? raw.array("loop_steps").flatMap(flatten) : [raw]
        }
        return steps.flatMap { flatten($0.raw) }
    }
    func plateRemovalIssue(tableID:Int,number:Int)->String? {
        let plates=worktable(tableID).array("WorkTablets")
        guard plates.contains(where:{ $0.integer("Number")==number }) else { return "找不到所选板位" }
        guard plates.count>1 else { return "组合至少保留一个板位；可以删除整个组合" }
        var names:[String]=[]
        let shock=config.integer("shockPlate")==0 ? 1 : config.integer("shockPlate")
        for (program,deleted) in programs.map({ ($0,false) })+deletedPrograms.map({ ($0,true) }) where program.worktableID==tableID {
            let raws=stepRaws(program.steps)
            let refers=raws.contains { raw in
                let event=raw.integer("event_type")
                return event==6 ? shock==number : event != 7 && raw["plate_number"] != nil && raw.integer("plate_number")==number
            }
            if refers { names.append(program.name+(deleted ? "（已删除程序）" : "")) }
            // The vendor shock plate is shared globally; do not silently change
            // another table's target while renumbering this one.
            if shock>number,raws.contains(where:{ $0.integer("event_type")==6 }) {
                return "此组合的震荡步骤使用全局板位 T\(shock)，请先调整震荡步骤再删除前面的板位"
            }
        }
        return names.isEmpty ? nil : "T\(number)仍被以下程序使用，请先修改对应步骤："+names.joined(separator:"、")
    }
    /// Freeze the vendor's count-based front/back orientation before changing
    /// the list, so adding/removing a plate never flips existing well offsets.
    private func stablePlateDirections(_ plates:[JSONObject])->[JSONObject] {
        plates.enumerated().map { index,row in
            var result=row
            if result["_macFirstRow"] == nil { result["_macFirstRow"]=index+1<=plates.count/2 }
            return result
        }
    }
    private mutating func remapPlateReferences(tableID:Int,_ remap:(Int)->Int) {
        func change(_ raw:JSONObject)->JSONObject {
            var result=raw
            if raw.integer("event_type")==8 { result["loop_steps"]=raw.array("loop_steps").map(change) }
            else if raw.integer("event_type") != 6,raw.integer("event_type") != 7,raw["plate_number"] != nil {
                result["plate_number"]=remap(raw.integer("plate_number"))
            }
            return result
        }
        func update(_ program:Program)->Program {
            guard program.worktableID==tableID else { return program }
            var result=program
            result.steps=result.steps.map { step in var result=step;result.raw=change(step.raw);return result }
            return result
        }
        programs=programs.map(update);deletedPrograms=deletedPrograms.map(update)
        if var manual=manualControls {
            if manual.tableID==tableID {
                manual.loadPlate=remap(manual.loadPlate);manual.unloadPlate=remap(manual.unloadPlate)
                manual.segmentedPlate=remap(manual.segmentedPlate)
                if manual.loadPlate==0 { manual.loadRow=0;manual.loadColumn=0 }
                if manual.unloadPlate==0 { manual.unloadRow=0;manual.unloadColumn=0 }
                if manual.segmentedPlate==0 { manual.segmentedRow=0;manual.segmentedColumn=0 }
            }
            // Drafts belong to every table, not just the currently selected one.
            // Preserve invalid imported text; a removed target becomes zero so
            // ordinary compiler validation requires an explicit new selection.
            for key in manual.liquidSteps.keys where key.hasPrefix("\(tableID):") {
                guard var draft=manual.liquidSteps[key],let number=exactIntegerValue(draft.raw.text("plate_number")),(1...48).contains(number) else { continue }
                draft.raw["plate_number"]=remap(number);manual.liquidSteps[key]=draft
            }
            manualControls=manual
        }
    }
    mutating func addTablePlate(_ tableID:Int,firstRow:Bool=false) throws ->Int {
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let index=rows.firstIndex(where:{ $0.integer("id")==tableID }) else { throw ControlError.invalid("找不到板位组合") }
        var plates=stablePlateDirections(rows[index].array("WorkTablets"))
        guard plates.count<48 else { throw ControlError.invalid("每个组合最多48个板位") }
        let number=plates.count+1;plates.append(Self.blankPlate(number,firstRow:firstRow))
        rows[index]["WorkTablets"]=plates;rows[index]["platesNumber"]=plates.count;tables["WorkTable"]=rows
        return number
    }
    mutating func removeTablePlate(tableID:Int,number:Int,archive:Bool=true) throws {
        if let issue=plateRemovalIssue(tableID:tableID,number:number) { throw ControlError.invalid(issue) }
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let index=rows.firstIndex(where:{ $0.integer("id")==tableID }) else { throw ControlError.invalid("找不到板位组合") }
        var plates=stablePlateDirections(rows[index].array("WorkTablets"))
        guard let plateIndex=plates.firstIndex(where:{ $0.integer("Number")==number }) else { throw ControlError.invalid("找不到所选板位") }
        let removed=plates.remove(at:plateIndex)
        if archive {
            var deleted=tables["_macDeletedPlates"] as? [JSONObject] ?? []
            deleted.append(["id":UUID().uuidString,"tableID":tableID,"number":number,"plate":removed])
            tables["_macDeletedPlates"]=deleted
        }
        for i in plates.indices {
            let previous=plates[i].integer("Number")
            if plates[i].text("Code")=="T\(previous)" { plates[i]["Code"]="T\(i+1)" }
            plates[i]["Number"]=i+1
        }
        rows[index]["WorkTablets"]=plates;rows[index]["platesNumber"]=plates.count
        for key in ["trapPlate","unLoadPlate"] { let n=rows[index].integer(key);if n>=number { rows[index][key]=n==number ? 0 : n-1 } }
        tables["WorkTable"]=rows
        remapPlateReferences(tableID:tableID) { $0==number ? 0 : $0>number ? $0-1 : $0 }
    }
    mutating func restoreTablePlate(_ id:String) throws ->(tableID:Int,number:Int) {
        var deleted=tables["_macDeletedPlates"] as? [JSONObject] ?? [],rows=tables["WorkTable"] as? [JSONObject] ?? []
        guard let removedIndex=deleted.firstIndex(where:{ $0.text("id")==id }) else { throw ControlError.invalid("找不到已删除板位") }
        let removed=deleted[removedIndex],tableID=removed.integer("tableID")
        guard let tableIndex=rows.firstIndex(where:{ $0.integer("id")==tableID }) else { throw ControlError.invalid("请先恢复所属板位组合") }
        var plates=stablePlateDirections(rows[tableIndex].array("WorkTablets"))
        guard plates.count<48 else { throw ControlError.invalid("每个组合最多48个板位") }
        let number=max(1,min(removed.integer("number"),plates.count+1))
        let shock=config.integer("shockPlate")==0 ? 1 : config.integer("shockPlate")
        if number<=shock,(programs+deletedPrograms).filter({ $0.worktableID==tableID }).contains(where:{ stepRaws($0.steps).contains { $0.integer("event_type")==6 } }) {
            throw ControlError.invalid("恢复会改变震荡板位编号，请先调整此组合的震荡步骤")
        }
        plates.insert(removed.object("plate"),at:number-1)
        for i in plates.indices {
            let previous=plates[i].integer("Number")
            if plates[i].text("Code")=="T\(previous)" { plates[i]["Code"]="T\(i+1)" }
            plates[i]["Number"]=i+1
        }
        rows[tableIndex]["WorkTablets"]=plates;rows[tableIndex]["platesNumber"]=plates.count
        for key in ["trapPlate","unLoadPlate"] { let n=rows[tableIndex].integer(key);if n>=number { rows[tableIndex][key]=n+1 } }
        deleted.remove(at:removedIndex);tables["WorkTable"]=rows;tables["_macDeletedPlates"]=deleted
        remapPlateReferences(tableID:tableID) { $0>=number ? $0+1 : $0 }
        return (tableID,number)
    }

}

struct ManualMotionPlan {
    let bytes:Data
    let target:[Int32]
    let axes:[Int]
    let waitsForReply:Bool
    let summary:String
    func matches(_ positions:[Int32])->Bool {
        positions.count==4 && axes.allSatisfy { abs(Int64(positions[$0])-Int64(target[$0]))<=2 }
    }
}

// Use the same completion/readback loop with Bluetooth and with recorded replies in offline checks.
@MainActor struct ManualMotionExecutor {
    var requestCompletion:(Data) async throws -> Void
    var sendOnly:(Data) async throws -> Void
    var readPositions:() async throws -> [Int32]
    var pause:() async throws -> Void = { try await Task.sleep(nanoseconds:300_000_000) }
    var onPosition:([Int32])->Void = { _ in }
    var maximumPolls=100
    func execute(_ plan:ManualMotionPlan) async throws -> [Int32] {
        try Task.checkCancellation()
        if plan.waitsForReply { try await requestCompletion(plan.bytes) }
        else { try await sendOnly(plan.bytes) }
        let deadline=Date().addingTimeInterval(30)
        var latest:[Int32]=[],matched=0
        for _ in 0..<maximumPolls {
            try Task.checkCancellation()
            latest=try await readPositions()
            try Task.checkCancellation()
            onPosition(latest)
            matched=plan.matches(latest) ? matched+1 : 0
            if matched >= (plan.waitsForReply ? 1 : 2) { return latest }
            if plan.waitsForReply || Date()>=deadline { break }
            try await pause()
        }
        throw ControlError.invalid("移动后坐标未到目标：目标步数 \(plan.target)，设备回报 \(latest)。已停止后续移动，请复位同步坐标")
    }
}

struct ManualCommands {
    let compiler:Compiler
    static let axes=["x","y","z","imb"]
    // Firmware coordinates: the original APP's X-left (1) increases X; X-right (2) decreases it.
    // Confirmed by two recorded 010C/8103 traces and offline execution of all eight firmware directions.
    static let directions:[Int:(Int,Int)]=[1:(0,1),2:(0,-1),17:(1,-1),18:(1,1),33:(2,-1),34:(2,1),49:(3,1),50:(3,-1)]
    func jog(direction:Int,distance:String) throws -> Data {
        let axis:[Int:String]=[1:"x",2:"x",17:"y",18:"y",33:"z",34:"z",49:"imb",50:"imb"]
        guard let key=axis[direction] else { throw ControlError.invalid("未知点动方向") }
        let mm=try compiler.finite(distance,label:"点动距离")
        guard mm>0 else { throw ControlError.invalid("点动距离必须大于 0") }
        let coefficient=try compiler.num(compiler.config,key+"Coefficient"),pitch=try compiler.num(compiler.config,key+"ScrewPitch")
        guard coefficient>0,pitch>0 else { throw ControlError.invalid("运动轴系数和导程必须大于 0") }
        // CommandDetails.packAxisFixedStepCmd uses this Float product, without the axis-position *10*0.1 expression.
        let steps=floor(Double(Float(mm)*Float(coefficient))/pitch)
        guard steps>=1,steps<=Double(Int32.max) else { throw ControlError.invalid("点动步数超出范围") }
        return try compiler.schema.encode("JogBean",["moveType":direction,"moveStep":Int(steps)])
    }
    func limitSteps(_ axis:Int) throws -> Int {
        let key=Self.axes[axis],limit=try compiler.num(compiler.config,key+"LimitPos")
        guard limit>0 else { throw ControlError.invalid("\(key) 轴行程上限必须大于 0") }
        return try compiler.axis(limit,key,javaFloatProduct:false)
    }
    func validate(_ target:Int,axis:Int,useConfiguredLimit:Bool=true) throws {
        let name=["X","Y","Z","移液轴"][axis],key=Self.axes[axis]
        guard target>=0,target<=Int(Int32.max) else {
            throw ControlError.invalid("\(name) 目标必须大于等于 0 且在设备坐标编码范围内，未发送移动指令")
        }
        // The exported ZLimitPos is a device-maintenance setting, not a verified travel bound.
        // Existing plate Z positions exceed it; retain zero/encoding checks without imposing it on Z moves.
        if axis==2 || !useConfiguredLimit { return }
        let limit=try limitSteps(axis)
        guard target<=limit else {
            let mm=Double(target)*compiler.config.number(key+"ScrewPitch")/compiler.config.number(key+"Coefficient")
            throw ControlError.invalid("\(name) 目标 \(formatNumber(mm)) mm 超出 0–\(compiler.config.text(key+"LimitPos")) mm 行程，未发送移动指令")
        }
    }
    func absoluteXYZ(_ xyz:[Int],useConfiguredXYLimits:Bool=true) throws -> Data {
        guard xyz.count==3 else { throw ControlError.invalid("需要 X / Y / Z 目标位置") }
        var values=["axisType":1,"moveType":0]
        for i in 0..<3 {
            try validate(xyz[i],axis:i,useConfiguredLimit:useConfiguredXYLimits)
            let axis=Self.axes[i]
            values[axis+"Pos"]=xyz[i]
            values[axis+"AccSpeed"]=try compiler.whole(compiler.config,axis+"AccSpeed",within:0...255)
            values[axis+"Speed"]=try compiler.whole(compiler.config,axis+"Speed",within:1...255)
        }
        return try compiler.schema.encode("MoveAxisBean",values)
    }
    func plannedJog(direction:Int,distance:String,positions:[Int32]) throws -> ManualMotionPlan {
        guard positions.count==4,positions.allSatisfy({ $0>=0 }),let (axis,sign)=Self.directions[direction] else { throw ControlError.invalid("当前位置无效，请先复位并读取位置") }
        let bytes=try jog(direction:direction,distance:distance)
        let delta=Int(Wire.u32(try Wire.decode(bytes).payload,1))
        let end=Int(positions[axis])+sign*delta
        try validate(end,axis:axis)
        var target=positions;target[axis]=Int32(end)
        // Captured firmware reports stale Z after 010C upwards to exactly zero.
        // Android's 0102 absolute move has captured 8102 completion + Z=0 readback.
        let zeroZ=axis==2 && end==0
        let command=zeroZ ? try absoluteXYZ(target.prefix(3).map(Int.init),useConfiguredXYLimits:false) : bytes
        let name=["X","Y","Z","移液轴"][axis],key=Self.axes[axis]
        let mm=Double(end)*compiler.config.number(key+"ScrewPitch")/compiler.config.number(key+"Coefficient")
        return ManualMotionPlan(bytes:command,target:target,axes:zeroZ ? [0,1,2] : [axis],waitsForReply:zeroZ,summary:"\(name) → \(formatNumber(mm)) mm"+(zeroZ ? " · 绝对定位回零" : ""))
    }
    func plateMove(tableID:Int,number:Int,positions:[Int32]) throws -> ManualMotionPlan {
        let tables=(compiler.workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.number("id",.nan)==Double(tableID) }
        guard tables.count==1,let table=tables.first else { throw ControlError.invalid("台面 ID \(tableID) 缺失或重复") }
        _ = try compiler.whole(table,"Model",within:1...1)
        let plates=table.array("WorkTablets")
        guard !plates.isEmpty,number>0,plates.indices.contains(number-1) else { throw ControlError.invalid("找不到所选 9210 板位") }
        if table["platesNumber"] != nil {
            guard try compiler.whole(table,"platesNumber",within:1...Int(Int32.max))==plates.count else { throw ControlError.invalid("台面板位数量与 platesNumber 不一致") }
        }
        for (index,item) in plates.enumerated() {
            guard try compiler.whole(item,"Number",within:1...plates.count)==index+1 else { throw ControlError.invalid("台面板位 Number 必须按 1–\(plates.count) 排列，不能重复或错位") }
        }
        let plate=plates[number-1]
        guard positions.count==4,positions.allSatisfy({ $0>=0 }) else { throw ControlError.invalid("当前位置无效，请先复位并读取位置") }
        let x=try compiler.num(plate,"XPos"),y=try compiler.num(plate,"YPos")
        // Reproduce packAxisMovePosCmd: the Android button sends Z=0, above the plate.
        let xyz=[try compiler.axis(x,"x"),try compiler.axis(y,"y"),0]
        let bytes=try absoluteXYZ(xyz,useConfiguredXYLimits:false)
        return ManualMotionPlan(bytes:bytes,target:xyz.map(Int32.init)+[positions[3]],axes:[0,1,2],waitsForReply:true,summary:"T\(number) 上方 · X \(formatNumber(x)) / Y \(formatNumber(y)) / Z 0 mm")
    }
    func positionMM(_ positions:[Int32]) -> [Double] {
        guard positions.count==4 else { return [] }
        return zip(positions,["x","y","z","imb"]).map { steps,axis in
            let coefficient=compiler.config.number(axis+"Coefficient"),pitch=compiler.config.number(axis+"ScrewPitch")
            return coefficient>0 ? Double(steps)*pitch/coefficient : 0
        }
    }
}
