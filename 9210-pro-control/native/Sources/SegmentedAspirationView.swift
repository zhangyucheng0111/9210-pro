import SwiftUI

struct SegmentedAspirationView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var bluetooth:BluetoothController
    let visible:Bool
    @State private var startZ=""
    @State private var endZ=""
    @State private var volume="1"
    @State private var liquidID=1
    @State private var segments="20"
    @State private var zSpeed="1"
    @State private var zAcceleration="1"
    @State private var pSpeed="1"
    @State private var pAcceleration="1"
    @State private var pauseMS="200"
    @State private var showWells=false

    private var settings:ManualControlSettings { model.manualControls }
    private var plates:[JSONObject] { model.workspace.worktable(settings.tableID).array("WorkTablets") }
    private var range:Int { (try? model.workspace.resolvedTableHeadRange(settings.tableID)) ?? 0 }
    private var positionRaw:Binding<JSONObject> {
        Binding(get:{ ["plate_number":settings.segmentedPlate,"x_axis":settings.segmentedRow,"y_axis":settings.segmentedColumn] },set:{ value in
            model.setManualSegmentedPosition(number:settings.segmentedPlate,row:value.integer("x_axis"),column:value.integer("y_axis"))
        })
    }
    private var curves:[JSONObject] { model.workspace.tables["Curve"] as? [JSONObject] ?? [] }
    private var liquidIDs:[Int] {
        Array(Set(curves.filter { $0.integer("range")==range }.map { $0.integer("liquid_id") }.filter { $0>0 })).sorted()
    }
    private var currentZ:Double? {
        let positions=model.mode=="simulation" ? model.simulatedPositions : bluetooth.positions
        guard positions.count==4,positions.allSatisfy({ $0>=0 }) else { return nil }
        let values=ManualCommands(compiler:model.compiler).positionMM(positions)
        guard values.count==4,values[2].isFinite else { return nil }
        return values[2]
    }
    private var request:Result<SegmentedAspirationRequest,Error> {
        Result {
            _=try model.workspace.resolvedTableHeadRange(settings.tableID)
            guard liquidIDs.contains(liquidID) else { throw ControlError.invalid("所选量程没有对应液体标定曲线。") }
            let raw:JSONObject=["start_z":startZ,"end_z":endZ,"dose":volume,"liquid_id":liquidID,"type":0,
                                "segments":segments,"z_speed":zSpeed,"z_acc":zAcceleration,
                                "p_speed":pSpeed,"p_acc":pAcceleration,"pause_ms":pauseMS]
            let value=try SegmentedAspirationRequest.parse(raw,range:range,compiler:model.compiler)
            // Validate geometry, calibration and integer segment sizes before
            // enabling either action, without depending on cached live axes.
            _=try model.compiler.compileManualSegmentedAspiration(value,settings:settings)
            return value
        }
    }
    private var canStart:Bool {
        guard !model.manualControlsLocked,case .success=request else { return false }
        return model.mode != "hardware" || (bluetooth.ready && !bluetooth.uncertain && model.manualFault==nil)
    }
    private var canAdd:Bool {
        guard !model.manualControlsLocked,case .success=request,let program=model.program else { return false }
        return program.range==range && program.worktableID==settings.tableID
    }

    var body:some View {
        // Retain drafts on this parent even while its expensive panel is absent.
        Group { if visible { panel } }
            .onChange(of:range,initial:true) { _,_ in synchronizeHead() }
    }
    private var panel:some View {
            VStack(alignment:.leading,spacing:20) {
                Text("先抬到 Z0 并定位到所选板位 XY，再按正常速度到起始 Z，逐段执行“缓降 → 吸液”，完成后回到 Z0。")
                    .font(StudioTypography.caption).foregroundStyle(.secondary)
                section("板位与孔位") {
                    Picker("吸液板位",selection:Binding(get:{ settings.segmentedPlate },set:{ model.setManualSegmentedPosition(number:$0) })) {
                        if !plates.contains(where:{ $0.integer("Number")==settings.segmentedPlate }) { Text("请选择吸液板位").tag(settings.segmentedPlate) }
                        ForEach(plates,id:\.plateID) { plate in
                            Text("T\(plate.integer("Number")) · \(plate.object("Material").text("Name","未设置耗材"))").tag(plate.integer("Number"))
                        }
                    }.frame(maxWidth:500)
                    if let plate=plates.first(where:{ $0.integer("Number")==settings.segmentedPlate }),!plate.object("Material").isEmpty {
                        DisclosureGroup("起始孔位 \(WellAddress.label(row:settings.segmentedRow,column:settings.segmentedColumn))",isExpanded:$showWells) {
                            StepPositionFields(raw:positionRaw,plates:plates).frame(maxWidth:440).padding(.top,8)
                        }
                    }
                    if case .success(let value)=request,let coordinate=try? model.compiler.compileManualSegmentedAspiration(value,settings:settings) {
                        Text("目标 X \(formatNumber(coordinate.positionMM[0])) / Y \(formatNumber(coordinate.positionMM[1])) mm · Z 使用下方起止高度")
                            .font(StudioTypography.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.disabled(model.manualControlsLocked)
                Divider()
                section("下降范围") {
                    VStack(alignment:.leading,spacing:8) {
                        HStack(spacing:24) {
                            parameter("起始 Z",text:$startZ,unit:"mm")
                            parameter("结束 Z",text:$endZ,unit:"mm")
                        }
                        HStack(spacing:12) {
                            Button("使用当前 Z") { if let z=currentZ { startZ=formatNumber(z) } }
                                .disabled(model.manualControlsLocked || currentZ==nil)
                            Button("读取位置") { model.query(true) }
                                .disabled(model.manualControlsLocked || !bluetooth.ready)
                        }
                    }
                }
                Divider()
                section("吸液设置") {
                    VStack(alignment:.leading,spacing:8) {
                        HStack(spacing:24) {
                            parameter("总吸液量",text:$volume,unit:"µL")
                            Text(range>0 ? "\(range) µL 移液头 · 随板位组合" : "请先在底板中设置组合移液头")
                                .font(StudioTypography.caption).foregroundStyle(.secondary)
                        }
                        Picker("液体",selection:$liquidID) {
                            if !liquidIDs.contains(liquidID) { Text("请选择液体").tag(liquidID) }
                            ForEach(liquidIDs,id:\.self) { id in Text(liquidName(id)).tag(id) }
                        }.frame(maxWidth:440)
                    }.disabled(model.manualControlsLocked)
                }
                Divider()
                section("速度与分段") {
                    VStack(alignment:.leading,spacing:8) {
                        Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:10) {
                            GridRow {
                                parameter("下降速度",text:$zSpeed)
                                parameter("吸液速度",text:$pSpeed)
                            }
                            GridRow {
                                parameter("下降加速度",text:$zAcceleration)
                                parameter("吸液加速度",text:$pAcceleration)
                            }
                            GridRow {
                                parameter("分段数",text:$segments,unit:"段")
                                parameter("段间停留",text:$pauseMS,unit:"ms")
                            }
                        }
                        Text("段间停留是在每段动作完成并读回位置后额外等待，非每段总周期；模拟运行会压缩等待时间。")
                            .font(StudioTypography.caption).foregroundStyle(.secondary)
                        Text("下降速度和加速度 1–255；吸液速度 20 µL头最低1、1000 µL头最低7（固件起速下限）。均为设备编码值，实际速度需实测。")
                            .font(StudioTypography.caption).foregroundStyle(.secondary)
                        if !startZ.isEmpty,!endZ.isEmpty {
                            switch request {
                            case .success(let value):
                                Text("每段约下降 \(formatNumber((value.endZMM-value.startZMM)/Double(value.segments))) mm、吸液 \(formatNumber(value.volumeUL/Double(value.segments))) µL · 合计 \(value.segments) 段")
                                    .font(StudioTypography.caption).monospacedDigit().foregroundStyle(.secondary)
                            case .failure(let error):
                                Text(error.localizedDescription).font(StudioTypography.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                Divider()
                section("执行") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("按所选板位与孔位定位 XY，保留当前柱塞起点。吸液完成后抬到 Z0，保留已吸入量。加入程序时沿用此处板位和孔位。")
                            .font(StudioTypography.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.mode=="simulation" ? "模拟分段吸液" : "开始分段吸液") {
                                if case .success(let value)=request { model.executeSegmentedAspiration(value) }
                            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canStart)
                            Button("停止",role:.destructive) { model.stop() }
                                .disabled(!model.manualBusy || model.isStopping)
                            Button("加入当前程序") {
                                if case .success(let value)=request { model.addSegmentedAspirationToProgram(value) }
                            }.disabled(!canAdd)
                            if let z=currentZ {
                                Text("\(model.mode=="simulation" ? "模拟 Z" : "缓存 Z") \(formatNumber(z)) mm")
                                    .font(StudioTypography.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                        }
                        if let program=model.program {
                            Text(program.range==range && program.worktableID==settings.tableID ? "加入：\(program.name) · \(program.range) µL" : "当前程序需使用相同板位组合后，才可加入。")
                                .font(StudioTypography.caption).foregroundStyle(.secondary)
                        } else {
                            Text("选择或新建程序后，可将上述参数加入程序。").font(StudioTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
    }

    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.system(size:13,weight:.semibold))
            content()
        }
    }

    private func parameter(_ label:String,text:Binding<String>,unit:String="")->some View {
        HStack(spacing:8) {
            Text(label).frame(width:84,alignment:.leading)
            ValidatedNumericField(label,text:text,rule:parameterRule(label)).frame(width:80)
            Text(unit).foregroundStyle(.secondary).frame(width:24,alignment:.leading)
        }.studioParameterRow().disabled(model.manualControlsLocked)
    }
    private func parameterRule(_ label:String)->NumericRule {
        switch label {
        case "下降速度","下降加速度","吸液加速度":return .integer(min:1,max:255)
        case "吸液速度":return .integer(min:range==1000 ? 7 : 1,max:255)
        case "分段数":return .integer(min:1,max:1000)
        case "段间停留":return .integer(min:0,max:60000)
        case "总吸液量":return .decimal(min:Double.leastNonzeroMagnitude,max:Double(range))
        default:return .decimal(min:0)
        }
    }
    private func synchronizeHead() {
        selectAvailableLiquid()
        let minimum=SegmentedAspirationRequest.minimumPSpeed(range:range)
        if let value=exactIntegerValue(pSpeed),value<minimum { pSpeed=String(minimum) }
    }
    private func selectAvailableLiquid() {
        if !liquidIDs.contains(liquidID),let first=liquidIDs.first { liquidID=first }
    }
    private func liquidName(_ id:Int)->String {
        let liquids=model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? []
        return liquids.first { $0.integer("liquid_id")==id }?.text("liquid_type","液体 \(id)")
            ?? curves.first { $0.integer("range")==range && $0.integer("liquid_id")==id }?.text("liquid_type","液体 \(id)")
            ?? "液体 \(id)"
    }
}
