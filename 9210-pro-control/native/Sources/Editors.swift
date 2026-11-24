import SwiftUI

struct NewProgramSheet: View {
    @ObservedObject var model:AppModel
    @State private var name="新程序"
    @State private var table=8
    @State private var folderID:String?
    private var range:Int? { try? model.workspace.resolvedTableHeadRange(table) }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            Text("新建自由程序").font(StudioTypography.pageTitle)
            Text("从空白开始，组合动作、设置参数，之后可以随时调整。").font(.system(size:12)).foregroundStyle(Style.muted)
            TextField("程序名称",text:$name).studioInput(width:360).controlSize(.large)
            Picker("使用台面",selection:$table) { ForEach((model.workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 },id:\.selfID) { t in Text(t.text("NickName","台面 \(t.integer("id"))")).tag(t.integer("id")) } }
            if !model.workspace.programFolders.isEmpty {
                Picker("文件夹",selection:$folderID) {
                    Text("根目录").tag(nil as String?)
                    ForEach(model.workspace.programFolders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }
            }
            Text(range.map { "\($0) µL 移液头 · 随板位组合" } ?? "请先在位置／底板中为此组合指定移液头量程。")
                .font(StudioTypography.caption).foregroundStyle(.secondary)
            Text("可添加装头、卸头、吸液、排液、分段下降吸液、混匀、震荡、等待和循环。").font(.system(size:11)).foregroundStyle(Style.muted)
            HStack { Button("取消") { model.showNewProgram=false };Spacer();Button("创建空白程序") { if let range=range { model.createProgram(name:name,range:range,table:table,folderID:folderID) } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || range==nil) }
        }.padding(28).frame(width:540)
        .onAppear {
            table=model.program?.worktableID ?? 8
            folderID=model.selection.flatMap { model.workspace.programFolderAssignments[$0] }
        }
    }
}

// The main inspector and the loop editor expose the same step parameters.
struct StepFields: View {
    @Binding var raw:JSONObject
    let plates:[JSONObject]
    let liquids:[JSONObject]
    var range:Int=20
    var motionContext:String="程序"
    var wellGridMaxWidth:CGFloat?=nil
    var event:Int { raw.integer("event_type") }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            if [3,4,5,9].contains(event) {
                section("体积",separated:false) {
                    field(event == 9 ? "总吸液量" : event == 5 ? "混匀量" : "转移量","dose",unit:"µL")
                    if event == 4 { field("额外补偿","compensate",unit:"µL") }
                    if event == 5 {
                        field("混匀次数","mix_times",unit:"次")
                    }
                    if event != 5 { liquidPicker }
                }
            }
            if [3,4,5].contains(event) {
                section("吸排速度") {
                    if event == 5 {
                        speed("吸液速度档","mix_imb_speed")
                        speed("排液速度档","mix_trap_speed")
                    } else { speed(event == 3 ? "吸液速度档" : "排液速度档","speed") }
                }
            }
            if event == 9 {
                section("下降范围") {
                    field("起始 Z","start_z",unit:"mm",placeholder:"必填")
                    field("结束 Z","end_z",unit:"mm",placeholder:"必填")
                    field("分段数","segments",unit:"段")
                }
                section("分段速度") {
                    field("下降速度","z_speed")
                    field("下降加速度","z_acc")
                    field("吸液速度","p_speed")
                    field("吸液加速度","p_acc")
                    field("段间停留","pause_ms",unit:"ms")
                    Text("每段动作完成并读回位置后的额外等待；完成全部吸液后返回 Z0。")
                        .font(StudioTypography.caption).foregroundStyle(.secondary)
                }
            }
            if (1...5).contains(event) || event == 9 {
                section("位置与孔位",separated:[3,4,5,9].contains(event)) {
                    Picker("板位",selection:Binding(get:{ raw.integer("plate_number") },set:{ value in
                        var next=raw;next["plate_number"]=value
                        let material=plates.first { $0.integer("Number")==value }?.object("Material") ?? [:]
                        raw=WellAddress.set(next,row:next.integer("x_axis"),column:next.integer("y_axis"),rows:material.integer("HoleRow"),columns:material.integer("HoleColum"))
                    })) {
                        ForEach(plates,id:\.plateID) { p in Text("T\(p.integer("Number")) · \(p.object("Material").text("Name"))").tag(p.integer("Number")) }
                    }.frame(minHeight:28)
                    StepPositionFields(raw:$raw,plates:plates)
                        .frame(maxWidth:wellGridMaxWidth ?? .infinity,alignment:.leading)
                    if event != 9 {
                        field("自定 Z 高度","z_customized_pos",unit:"mm",placeholder:"台面").padding(.top,4)
                        let presets=plates.first { $0.integer("Number")==raw.integer("plate_number") }?.array("zMorePosBean") ?? []
                        if !presets.isEmpty {
                            Menu("选择 Z 高度预设") {
                                Button("使用板位 Z") { raw["z_customized_pos"]="" }
                                ForEach(Array(presets.enumerated()),id:\.offset) { i,p in Button(p.text("name","高度 \(i+1)")+" · "+p.text("pos")+" mm") { raw["z_customized_pos"]=p.text("pos") } }
                            }
                        }
                    }
                }
            }
            if event == 7 { section("等待",separated:false) { field("等待时间","wait_time",unit:"秒") } }
            if event == 6 {
                section("震荡",separated:false) {
                    field("模块编号","module_number")
                    Picker("震荡",selection:Binding(get:{ raw.integer("oscillation_switch",1) },set:{ raw["oscillation_switch"]=$0 })) { Text("关闭").tag(0);Text("开启").tag(1) }
                    field("震荡时间","oscillation_time",unit:"秒")
                    field("震荡频率","oscillation_frequency")
                }
            }
            if [3,4,5].contains(event) { auxiliaryFields }
            if [3,4,5,9].contains(event) {
                DisclosureGroup("参数说明") {
                    VStack(alignment:.leading,spacing:10) {
                        if event == 5 {
                            Text("混匀后实际吸液量为体积加补偿；合计不大于 0 时不吸液。")
                        }
                        if [3,4,5].contains(event) {
                            Text(event == 5 ? "混匀后吸液沿用吸液档；X/Y/Z 移动使用\(motionContext)通用速度。" : "此处调整液体吸排速度；X/Y/Z 移动使用\(motionContext)通用速度。")
                        }
                        if event == 9 {
                            Text("先按正常定位速度到起始 Z，等待完成后，再按下方速度逐段“缓降 → 吸液”。结束停在结束 Z；体积先统一补偿和标定，再按段分配。")
                            Text("速度和加速度为设备编码值，独立于程序通用速度。范围1–255；1000 µL头吸液速度最低7（固件起速下限）。分段数1–1000，停留0–60000 ms。")
                        }
                    }.font(StudioTypography.caption).foregroundStyle(.secondary).padding(.top,8)
                }.font(StudioTypography.caption).foregroundStyle(.secondary)
            }
            if [1,3,4,5].contains(event) {
                section("抬升设置") {
                    field("抬升高度","raise_height",unit:"mm")
                }
            }
        }.font(StudioTypography.body)
    }
    private var auxiliaryFields:some View {
        VStack(alignment:.leading,spacing:12) {
            Divider().padding(.bottom,2)
            HStack(spacing:12) {
                Text("辅助功能").font(.system(size:13,weight:.semibold))
                Spacer(minLength:8)
                Menu {
                    ForEach(availableAuxiliaryIDs,id:\.self) { id in
                        Button(auxiliaryNames[id] ?? "辅助功能") { addAuxiliary(id) }
                    }
                } label:{ Label("添加辅助功能",systemImage:"plus") }
                    .controlSize(.small).fixedSize().disabled(availableAuxiliaryIDs.isEmpty)
            }
            if event == 5 {
                VStack(alignment:.leading,spacing:8) {
                    liquidPicker
                    field("混匀后吸液","dose_after_mix",unit:"µL")
                    field("混匀后吸液补偿","compensate",unit:"µL")
                }
            }
            ForEach(Array(raw.array("auxiliary_functions").enumerated()),id:\.offset) { index,a in
                HStack(spacing:8) {
                    Text(auxiliaryName(a)).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:8)
                    if (1...4).contains(a.integer("id")) {
                        ValidatedNumericField("参数",text:auxiliaryDoseBinding(index),rule:auxiliaryParameterRule(a.integer("id")))
                            .multilineTextAlignment(.trailing).monospacedDigit().frame(width:96)
                            .accessibilityLabel(auxiliaryName(a))
                        Text(a.integer("id")==1 ? "秒" : "µL").foregroundStyle(.secondary).frame(width:26,alignment:.leading)
                    } else {
                        Text("使用台面预设").foregroundStyle(.secondary)
                    }
                    Button { removeAuxiliary(index) } label:{ Image(systemName:"minus.circle").frame(width:24,height:24) }
                        .buttonStyle(.borderless).help("移除"+auxiliaryName(a)).accessibilityLabel("移除"+auxiliaryName(a))
                }.font(StudioTypography.body).foregroundStyle(.primary).studioParameterRow()
            }
            if raw.array("auxiliary_functions").filter({ (6...9).contains($0.integer("id")) }).count>1 {
                Text("靠壁／贴壁只能保留一种，请移除冲突项或重新选择。")
                    .font(StudioTypography.caption).foregroundStyle(.red)
            }
            if raw.array("auxiliary_functions").isEmpty {
                Text("尚未添加辅助功能").font(StudioTypography.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var auxiliaryNames:[Int:String] { [1:"悬停",2:"前吸空气",3:"后吸空气",4:"吹样",5:"完成后抬升",6:"靠左壁",7:"靠右壁",8:"贴左壁",9:"贴右壁"] }
    private var auxiliaryCodes:[Int:String] { [1:"Hover",2:"Front_Suction_Volume",3:"Rear_Suction_Volume",4:"Blow_Sample",5:"Gradient",6:"AgainstXLeft",7:"AgainstXRight",8:"AdherentXLeft",9:"AdherentXRight"] }
    private var availableAuxiliaryIDs:[Int] {
        let supported=event == 3 ? [1,2,3,5] : event == 4 ? [1,3,4,5,6,7,8,9] : [1,2,3,4,5]
        let existing=Set(raw.array("auxiliary_functions").map { $0.integer("id") })
        return supported.filter { !existing.contains($0) }
    }
    private func auxiliaryParameterRule(_ id:Int)->NumericRule { .decimal(min:0,max:id==1 ? 65.535 : nil) }
    private func auxiliaryDoseBinding(_ index:Int)->Binding<String> {
        Binding(get:{
            let rows=raw.array("auxiliary_functions")
            return rows.indices.contains(index) ? rows[index].text("mDose","0") : ""
        },set:{ value in
            var rows=raw.array("auxiliary_functions")
            guard rows.indices.contains(index) else { return }
            rows[index]["mDose"]=value
            raw["auxiliary_functions"]=rows
        })
    }
    private func addAuxiliary(_ id:Int) {
        guard availableAuxiliaryIDs.contains(id) else { return }
        var rows=raw.array("auxiliary_functions")
        if (6...9).contains(id) { rows.removeAll { (6...9).contains($0.integer("id")) } }
        rows.append(["id":id,"assistEvent":auxiliaryCodes[id] ?? "","auxiliary_functions":auxiliaryNames[id] ?? "","mDose":"1"])
        raw["auxiliary_functions"]=rows
    }
    private func removeAuxiliary(_ index:Int) {
        var rows=raw.array("auxiliary_functions")
        guard rows.indices.contains(index) else { return }
        rows.remove(at:index)
        raw["auxiliary_functions"]=rows
    }
    private var liquidPicker:some View {
        Picker("液体",selection:Binding(get:{ raw.integer("liquid_id",1) },set:{ id in
            var next=raw;next["liquid_id"]=id;next["liquid_type"]=liquids.first { $0.integer("liquid_id") == id }?.text("liquid_type") ?? "";raw=next
        })) { ForEach(liquids,id:\.liquidID) { l in Text(l.text("liquid_type")).tag(l.integer("liquid_id")) } }
            .studioParameterRow()
    }
    private func auxiliaryName(_ row:JSONObject)->String { auxiliaryNames[row.integer("id")] ?? row.text("auxiliary_functions","辅助功能") }
    @ViewBuilder private func section<Content:View>(_ title:String,separated:Bool=true,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:12) {
            if separated { Divider().padding(.bottom,2) }
            Text(title).font(.system(size:13,weight:.semibold)).foregroundStyle(.primary)
            VStack(alignment:.leading,spacing:10) { content() }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func field(_ label:String,_ key:String,unit:String="",placeholder:String="0") -> some View {
        HStack(spacing:8) {
            Text(label).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            ValidatedNumericField(placeholder,text:Binding(get:{ raw.text(key) },set:{ value in
                var next=raw;next[key]=value
                if key == "x_axis" || key == "y_axis" { next["hole_id_list"]=[] }
                raw=next
            }),rule:fieldRule(key)).multilineTextAlignment(.trailing).monospacedDigit().frame(width:96).accessibilityLabel(label)
            Text(unit).foregroundStyle(.secondary).frame(width:26,alignment:.leading)
        }.studioParameterRow()
    }
    func speed(_ label:String,_ key:String) -> some View {
        HStack(spacing:8) {
            Text(label)
            Spacer(minLength:8)
            Picker(label,selection:Binding(get:{ raw.integer(key,3) },set:{ raw[key]=$0 })) { ForEach(1...10,id:\.self) { Text("\($0)").tag($0) } }
                .labelsHidden().frame(width:130).accessibilityLabel(label)
        }.studioParameterRow()
    }
    private func fieldRule(_ key:String)->NumericRule {
        if key=="dose" { return .decimal(min:Double.leastNonzeroMagnitude,max:Double(range)) }
        if key=="dose_after_mix" { return .decimal(min:0,max:Double(range)) }
        if key=="p_speed" { return .integer(min:range==1000 ? 7 : 1,max:255) }
        return NumericRules.step(key:key)
    }
}
extension Dictionary where Key==String,Value==Any {
    var plateID:Int { integer("Number") }
    var liquidID:Int { integer("liquid_id") }
}

struct AuxiliaryEditor: View {
    let event:Int
    let initial:[JSONObject]
    let onSave:([JSONObject])->Void
    let onCancel:()->Void
    @State private var rows:[JSONObject]=[]
    @State private var selected=1
    let names=[1:"悬停",2:"前吸空气",3:"后吸空气",4:"吹样",5:"完成后抬升",6:"靠左壁",7:"靠右壁",8:"贴左壁",9:"贴右壁"]
    let codes=[1:"Hover",2:"Front_Suction_Volume",3:"Rear_Suction_Volume",4:"Blow_Sample",5:"Gradient",6:"AgainstXLeft",7:"AgainstXRight",8:"AdherentXLeft",9:"AdherentXRight"]
    var options:[Int] { event == 3 ? [1,2,3,5] : event == 4 ? [1,3,4,5,6,7,8,9] : [1,2,3,4,5] }
    var conflictingWallPositions:Bool { rows.filter { (6...9).contains($0.integer("id")) }.count>1 }
    var invalidParameters:Bool {
        rows.contains { row in
            let id=row.integer("id")
            return (1...4).contains(id) && !parameterRule(id).isValid(row.text("mDose","0"))
        }
    }
    private func parameterRule(_ id:Int)->NumericRule { .decimal(min:0,max:id==1 ? 65.535 : nil) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("辅助段").font(StudioTypography.pageTitle)
            Text("体积为 µL，悬停为秒。空气段和吹样量为 0 时不执行该段；抬升和贴壁位置沿用所选台面的配置。").font(.system(size:12)).foregroundStyle(Style.muted)
            ForEach(Array(rows.enumerated()),id:\.offset) { index,row in
                HStack {
                    Text(names[row.integer("id")] ?? row.text("auxiliary_functions")).frame(width:100,alignment:.leading)
                    if row.integer("id") < 5 {
                        ValidatedNumericField("参数",text:Binding(get:{ rows.indices.contains(index) ? rows[index].text("mDose","0") : "" },set:{ if rows.indices.contains(index) { rows[index]["mDose"]=$0 } }),rule:parameterRule(row.integer("id"))).frame(width:100).accessibilityLabel(names[row.integer("id")] ?? "辅助段参数")
                        Text(row.integer("id")==1 ? "秒" : "µL").font(.system(size:11)).foregroundStyle(Style.muted)
                    } else { Text("使用台面预设").font(.system(size:11)).foregroundStyle(Style.muted) }
                    Spacer();Button { rows.remove(at:index) } label:{ Image(systemName:"minus.circle") }
                }.studioParameterRow()
            }
            if rows.isEmpty { Text("当前没有辅助段").foregroundStyle(Style.muted).padding(.vertical,14) }
            if conflictingWallPositions { Text("靠壁／贴壁只能保留一种，请移除冲突项或重新选择。").font(StudioTypography.caption).foregroundStyle(.red) }
            HStack {
                Picker("添加",selection:$selected) { ForEach(options,id:\.self) { id in Text(names[id] ?? "").tag(id) } }.frame(width:240)
                Button("添加") {
                    if (6...9).contains(selected) { rows.removeAll { (6...9).contains($0.integer("id")) } }
                    if !rows.contains(where:{ $0.integer("id")==selected }) { rows.append(["id":selected,"assistEvent":codes[selected] ?? "","auxiliary_functions":names[selected] ?? "","mDose":"1"]) }
                }
            }
            Divider()
            HStack { Button("取消",action:onCancel);Spacer();Button("保存辅助段") { onSave(rows) }.buttonStyle(.borderedProminent).disabled(conflictingWallPositions || invalidParameters) }
        }.padding(28).frame(width:590)
        .onAppear { rows=initial;selected=options.first ?? 1 }
    }
}

struct LoopEditorSheet: View {
    @ObservedObject var model:AppModel
    @State private var children:[Step]=[]
    @State private var selection:String?
    @State private var countText="1"
    var count:Int? { NumericRule.integer(min:1,max:1000).intValue(countText) }
    var canSave:Bool { guard let count=count else { return false };return !children.isEmpty && children.count<=10000/count }
    var selectedIndex:Int? { children.firstIndex { $0.id == selection } }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("编辑循环").font(StudioTypography.pageTitle);Spacer()
                Text("次数");ValidatedNumericField("次数",text:$countText,rule:.integer(min:1,max:1000)).frame(width:70).accessibilityLabel("循环次数")
            }
            Text("循环内可增删动作、修改参数和调整顺序。每轮按相同参数执行。").font(.system(size:12)).foregroundStyle(Style.muted)
            HSplitView {
                VStack(alignment:.leading,spacing:12) {
                    Menu("添加动作") { ForEach([1,2,3,4,5,6,7,9],id:\.self) { type in Button(Step.actionNames[type]!) { var s=Step.blank(type);if type==9,model.program?.range==1000 { s.raw["p_speed"]=7 };children.insert(s,at:selectedIndex.map { $0+1 } ?? children.count);selection=s.id } } }
                    List(selection:$selection) {
                        ForEach(Array(children.enumerated()),id:\.element.id) { i,s in
                            VStack(alignment:.leading,spacing:5) { Text("\(i+1). \(s.name)");Text(s.event == 7 ? s.detail : "\(s.detail) · \(s.displayDose)").font(.system(size:11)).foregroundStyle(Style.muted) }.padding(.vertical,4).tag(s.id)
                        }
                    }
                    HStack {
                        Button { move(-1) } label:{ Image(systemName:"arrow.up") }.disabled(selectedIndex == nil || selectedIndex == 0)
                        Button { move(1) } label:{ Image(systemName:"arrow.down") }.disabled(selectedIndex == nil || selectedIndex == children.count-1)
                        Button("复制") { if let i=selectedIndex { let s=children[i].copied();children.insert(s,at:i+1);selection=s.id } }.disabled(selectedIndex == nil)
                        Spacer()
                        Button("删除",role:.destructive) { if let i=selectedIndex { children.remove(at:i);selection=children.isEmpty ? nil : children[min(i,children.count-1)].id } }.disabled(selectedIndex == nil)
                    }
                }.frame(minWidth:300).padding(.trailing,14)
                ScrollView {
                    if let i=selectedIndex {
                        VStack(alignment:.leading,spacing:18) {
                            Text(children[i].name).font(.headline)
                            StepFields(raw:Binding(get:{ children.indices.contains(i) ? children[i].raw : [:] },set:{ if children.indices.contains(i) { children[i].raw=$0 } }),plates:model.plateList,liquids:model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? [],range:model.program?.range ?? 20)
                        }.padding(12)
                    } else { Text("选择一个动作编辑参数").foregroundStyle(Style.muted).padding() }
                }.frame(minWidth:320)
            }.frame(height:500)
            Divider()
            HStack {
                Button("取消") { model.showLoopEditor=false };Spacer()
                Text("\(children.count) 步 × \(count.map(String.init) ?? "—") 次").font(.system(size:11,design:.monospaced)).foregroundStyle(Style.muted)
                Button("保存循环") { if let count=count { model.saveLoop(children:children,count:count) } }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }.padding(26).frame(width:860)
        .onAppear { children=(model.step?.raw.array("loop_steps") ?? []).map { Step(id:UUID().uuidString,raw:$0,sourceIndex:-1) };selection=children.first?.id;countText=model.step?.raw.text("loop_count","1") ?? "1" }
    }
    func move(_ delta:Int) { guard let i=selectedIndex,children.indices.contains(i+delta) else { return };children.swapAt(i,i+delta) }
}
