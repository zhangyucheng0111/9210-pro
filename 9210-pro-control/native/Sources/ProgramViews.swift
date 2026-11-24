import SwiftUI
import AppKit
struct ProgramView:View {
    @ObservedObject var model:AppModel
    @State private var showSpeeds=false
    @State private var showCopy=false
    @State private var showPositions=false
    private static let defaultListWidth=244.0
    @AppStorage("programListWidth") private var leftWidth=Self.defaultListWidth
    @AppStorage("programInspectorWidth") private var rightWidth=420.0
    var body:some View {
        LiveProgramColumns(leftWidth:$leftWidth,rightWidth:$rightWidth,left:ProgramLibraryView(model:model,resetWidths:{ leftWidth=Self.defaultListWidth;rightWidth=420 }),center:editor,right:inspector)
        .sheet(isPresented:$showSpeeds) { ProgramSpeedsSheet(model:model) }
        .sheet(isPresented:$showCopy) { CopyStepsSheet(model:model) }
        .sheet(isPresented:$showPositions) { BatchPositionsSheet(model:model) }
    }
    var editor:some View {
        VStack(spacing:0) {
            if model.program != nil {
                programFields.padding(.horizontal,20).padding(.top,19).padding(.bottom,16)
                Divider()
                VStack(spacing:10) {
                    HStack(spacing:8) {
                        Text("步骤").font(.system(size:13,weight:.semibold))
                        Text("\(model.program?.steps.count ?? 0)").font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength:0)
                        Menu { ForEach([1,2,3,4,5,6,7,9],id:\.self) { type in Button(Step.actionNames[type]!) { model.addStep(type) } } } label:{ Label("添加动作",systemImage:"plus") }
                        Menu("编排") {
                            Button("组合循环…") { model.showLoop=true }.disabled(model.program?.steps.isEmpty != false)
                            Button("复制所选（\(model.chosenStepIDs.count)）…") { showCopy=true }.disabled(model.chosenStepIDs.isEmpty)
                            Button("批量改行列…") { showPositions=true }.disabled(model.chosenStepIDs.isEmpty)
                        }
                        Button { model.undoEdit() } label:{ Image(systemName:"arrow.uturn.backward") }.help("撤销").accessibilityLabel("撤销").disabled(!model.canUndo)
                        Button { model.redoEdit() } label:{ Image(systemName:"arrow.uturn.forward") }.help("重做").accessibilityLabel("重做").disabled(!model.canRedo)
                    }.controlSize(.small).disabled(model.programEditingLocked)
                }.padding(.horizontal,16).padding(.top,14).padding(.bottom,12)
                stepTable
                HStack { Text("双击运行该步骤 · 拖动排序 · ⌘ 多选 · ⇧ 连选");Spacer();if model.chosenStepIDs.count>1 { Text("已选 \(model.chosenStepIDs.count) 步") } }.font(StudioTypography.caption).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,8)
                if let problem=model.compileError { Text(problem).font(StudioTypography.caption).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,18).padding(.bottom,10) }
                Divider()
                runControls.padding(14)
            } else {
                Spacer()
                Image(systemName:"list.bullet.rectangle").font(.system(size:34,weight:.light)).foregroundStyle(.secondary)
                Text("还没有程序").font(.title3.weight(.semibold)).padding(.top,10)
                Text("创建自由程序，按需要组合移液动作。").foregroundStyle(.secondary).font(.callout).padding(.top,4)
                Button("新建自由程序…") { model.showNewProgram=true }.buttonStyle(.borderedProminent).padding(.top,14).disabled(model.programEditingLocked)
                Spacer()
            }
        }.background(Style.surface)
    }
    private var stepTable:some View { StepTableView(model:model) }
    var inspector:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if let step=model.step {
                    VStack(alignment:.leading,spacing:5) {
                        Text(step.name+"参数").font(StudioTypography.paneTitle)
                        Text(step.detail).font(StudioTypography.metadata).foregroundStyle(.secondary)
                    }
                    if model.chosenStepIDs.count>1 {
                        Text("已选 \(model.chosenStepIDs.count) 步。下方参数编辑当前这一步；复制、移动、删除作用于全部所选步骤。").font(StudioTypography.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing:6) {
                        Button("上移") { model.moveStep(-1) }
                        Button("下移") { model.moveStep(1) }
                        Button("复制") { model.duplicateStep() }
                        Button("删除",role:.destructive) { model.deleteStep() }
                    }.controlSize(.small)
                    Divider()
                    if step.event==8 {
                        Text(step.detail)
                        Button("编辑循环内步骤…") { model.showLoopEditor=true }
                        Button("解组为普通步骤") { model.ungroupLoop() }
                    } else {
                        StepFields(raw:Binding(get:{ model.selectedRaw },set:{ model.selectedRaw=$0 }),plates:model.plateList,liquids:model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? [],range:model.program?.range ?? 20)
                            .id(step.id)
                    }
                    Divider().padding(.top,4)
                    Button("完整参数…") { model.editRaw() }.controlSize(.small)
                } else { Text("添加或选择一个步骤").foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).disabled(model.programEditingLocked)
        }.background(Style.canvas)
    }
    var programFields:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:8) {
                TextField("程序名称",text:Binding(get:{ model.program?.name ?? "" },set:{ value in model.mutate { $0.name=value } }))
                    .textFieldStyle(.plain).font(StudioTypography.pageTitle).help("点击编辑程序名称").accessibilityLabel("程序名称")
                Image(systemName:"pencil").font(.system(size:12)).foregroundStyle(.secondary).accessibilityHidden(true)
                ContextSaveControls(model:model,title:"保存程序",programScoped:true)
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:12) {
                    tablePicker.fixedSize()
                    rangePicker
                    Spacer(minLength:0)
                    speedButton
                }.fixedSize(horizontal:true,vertical:false)
                VStack(alignment:.leading,spacing:10) {
                    HStack(spacing:12) { tablePicker;rangePicker }
                    speedButton
                }
            }.controlSize(.small)
        }.disabled(model.programEditingLocked)
    }
    private var tablePicker:some View {
        Picker("台面",selection:Binding(get:{ model.program?.worktableID ?? 8 },set:{ model.setProgramTable($0) })) { ForEach((model.workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 },id:\.selfID) { t in Text(t.text("NickName","台面 \(t.integer("id"))")).tag(t.integer("id")) } }
    }
    private var rangePicker:some View {
        Text((model.program.flatMap { try? model.workspace.resolvedTableHeadRange($0.worktableID) }).map { "\($0) µL · 随组合" } ?? "组合未指定移液头")
            .font(StudioTypography.caption).foregroundStyle(.secondary).help("移液头量程由板位组合决定，在位置／底板中设置。")
    }
    private var speedButton:some View {
        Button { showSpeeds=true } label:{ Label("通用速度…",systemImage:"slider.horizontal.3") }
    }
    var runControls:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:12) { checkButton;Spacer(minLength:12);executionButtons }.fixedSize(horizontal:true,vertical:false)
            VStack(alignment:.leading,spacing:10) {
                checkButton
                HStack { Spacer(minLength:0);executionButtons }
            }
        }.frame(maxWidth:.infinity,alignment:.trailing).controlSize(.regular)
    }
    private var checkButton:some View {
        Button("检查程序") { model.compileSelected();if model.compileError == nil { model.notice="检查通过 · \(model.compiled.count) 个执行动作" } }.disabled(model.manualControlsLocked)
    }
    private var executionButtons:some View {
        HStack {
            if model.isRunning && !model.isRunningSingleStep { Button(model.paused ? "继续" : "暂停后续步骤") { model.togglePause() }.disabled(model.isStopping) }
            else {
                Button { model.start() } label:{ Label(model.mode == "simulation" ? "模拟整个程序" : "运行整个程序",systemImage:"play.fill") }.buttonStyle(.borderedProminent).disabled(model.manualControlsLocked || model.program?.steps.isEmpty != false)
            }
        }
    }
}

struct ProgramSpeedsSheet:View {
    @ObservedObject var model:AppModel
    var body:some View {
        MotionSpeedsSheet(model:model,title:"程序通用速度",subtitle:model.program?.name ?? "",
            explanation:"随本程序保存，控制装卸头、吸排液和混匀的对应运动段。吸液、排液和混匀的液体速度在步骤中设置。",
            scopeNote:"吹样需启用辅助段；排液后回吸、混匀空吸的位置移动沿用设备默认速度。",
            initialValues:model.program?.motionSpeeds ?? model.workspace.defaultMotionSpeeds,
            saveLabel:"保存到程序",onSave:{ snapshot in
                guard !model.programEditingLocked else { return false }
                model.mutate { $0.motionSpeeds=snapshot };return true
            },programScoped:true)
    }
}

struct CopyStepsSheet:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copies="1"
    @State private var after="0"
    var indices:[Int] { (model.program?.steps ?? []).enumerated().filter { model.chosenStepIDs.contains($0.element.id) }.map { $0.offset+1 } }
    private let copiesRule=NumericRule.integer(min:1,max:100)
    private var afterRule:NumericRule { .integer(min:0,max:model.program?.steps.count ?? 0) }
    private var addedCount:Int? {
        guard let count=copiesRule.intValue(copies),indices.count<=10000 else { return nil }
        return count*indices.count
    }
    private var parameters:(copies:Int,after:Int)? {
        guard let program=model.program,!indices.isEmpty,program.steps.count<=10000,
              let count=copiesRule.intValue(copies),let position=afterRule.intValue(after),
              let added=addedCount,added<=10000-program.steps.count else { return nil }
        return (count,position)
    }
    private var copiesStepper:Binding<Int> {
        Binding(get:{ copiesRule.intValue(copies) ?? 1 },set:{ copies=String($0) })
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("批量复制步骤").font(.title2)
            Text("已选第 "+indices.map(String.init).joined(separator:"、")+" 步，按原顺序整组复制。").foregroundStyle(.secondary)
            HStack { Text("副本组数").frame(width:100,alignment:.leading);ValidatedNumericField("1–100",text:$copies,rule:copiesRule).frame(width:75).accessibilityLabel("副本组数");Stepper("",value:copiesStepper,in:1...100).labelsHidden();Spacer(minLength:0) }.studioParameterRow()
            HStack { Text("插入到第").frame(width:100,alignment:.leading);ValidatedNumericField("步骤序号",text:$after,rule:afterRule).frame(width:75).accessibilityLabel("副本插入步骤");Text("步后（0 = 开头）");Spacer(minLength:0) }.studioParameterRow()
            if let added=addedCount {
                Text("将新增 \(added) 步。复制后自动选中新副本，可接着批量改行列。").font(StudioTypography.caption).foregroundStyle(.secondary)
            } else {
                Text("副本组数请输入1–100的整数。").font(StudioTypography.caption).foregroundStyle(.red)
            }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction);Spacer();Button("复制步骤") { if let values=parameters,model.copySelectedSteps(copies:values.copies,afterIndex:values.after) { dismiss() } }.buttonStyle(.borderedProminent).disabled(parameters==nil) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:510)
        .onAppear { after=String(indices.last ?? 0) }
    }
}

struct BatchPositionsSheet:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var relative=true
    @State private var row="0"
    @State private var column="2"
    @State private var absoluteRow=0
    @State private var absoluteColumn=0
    private let offsetRule=NumericRule.integer(min:-48,max:48)
    private var positions:(row:Int,column:Int)? {
        if !relative { return (absoluteRow,absoluteColumn) }
        guard let r=offsetRule.intValue(row),let c=offsetRule.intValue(column) else { return nil }
        return (r,c)
    }
    private func offsetStepper(_ value:Binding<String>)->Binding<Int> {
        Binding(get:{ offsetRule.intValue(value.wrappedValue) ?? 0 },set:{ value.wrappedValue=String($0) })
    }
    var preview:(String,Bool) {
        guard var p=model.program else { return ("请选择程序",false) }
        guard let target=positions else { return ("行列偏移请输入−48到48的整数。",false) }
        do {
            try p.changePositions(ids:model.chosenStepIDs,workspace:model.workspace,row:target.row,column:target.column,relative:relative)
            let selected=p.steps.filter { model.chosenStepIDs.contains($0.id) }
            let count=selected.reduce(0) { $0 + ($1.event==8 ? $1.raw.array("loop_steps").filter { (1...5).contains($0.integer("event_type")) || $0.integer("event_type")==9 }.count : ((1...5).contains($1.event) || $1.event==9 ? 1 : 0)) }
            if count==0 { return ("所选步骤没有可调整的孔位",false) }
            let summary=selected.prefix(5).map { $0.name+" · "+$0.detail }.joined(separator:"\n")
            return ("修改 \(count) 个动作孔位\n"+summary,true)
        } catch { return (error.localizedDescription,false) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("批量改行列 · \(model.chosenStepIDs.count) 步").font(.title2)
            Picker("方式",selection:$relative) { Text("整体偏移").tag(true);Text("设为同一孔位").tag(false) }.pickerStyle(.segmented)
            if relative {
                HStack { Text("行偏移").frame(width:80,alignment:.leading);ValidatedNumericField("行",text:$row,rule:offsetRule).frame(width:70).accessibilityLabel("批量行偏移");Stepper("",value:offsetStepper($row),in:-48...48).labelsHidden();Text("正数向下，负数向上").foregroundStyle(.secondary);Spacer(minLength:0) }.studioParameterRow()
                HStack { Text("列偏移").frame(width:80,alignment:.leading);ValidatedNumericField("列",text:$column,rule:offsetRule).frame(width:70).accessibilityLabel("批量列偏移");Stepper("",value:offsetStepper($column),in:-48...48).labelsHidden();Text("正数向右，负数向左").foregroundStyle(.secondary);Spacer(minLength:0) }.studioParameterRow()
                Text("例：A1 和 A3 的列偏移 +2 → A3 和 A5。").font(StudioTypography.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("行",selection:$absoluteRow) { ForEach(0..<24,id:\.self) { Text(WellAddress.rowLabel($0)).tag($0) } }
                    Picker("列",selection:$absoluteColumn) { ForEach(0..<48,id:\.self) { Text(String($0+1)).tag($0) } }
                }
            }
            Text(preview.0).font(.callout).foregroundStyle(preview.1 ? Color.secondary : Color.red).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color(nsColor:.controlBackgroundColor))
            Text("吸液、排液、分段下降吸液、混匀、装头和卸头同步调整；选中循环时也会调整其内部孔位。按各板位耗材检查范围，越界时整批不修改。").font(StudioTypography.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction);Spacer();Button("应用到所选步骤") { if let target=positions,preview.1,model.changeSelectedPositions(row:target.row,column:target.column,relative:relative) { dismiss() } }.buttonStyle(.borderedProminent).disabled(!preview.1) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:530)
    }
}

struct StepPositionFields:View {
    @Binding var raw:JSONObject
    let plates:[JSONObject]
    @State private var cellSize=18.0
    var body:some View {
        let value=raw, plate=value.integer("plate_number")
        let material=plates.first { $0.integer("Number")==plate }?.object("Material") ?? [:]
        let rows=max(1,min(material.integer("HoleRow",1),48)),columns=max(1,min(material.integer("HoleColum",1),48))
        let row=value.integer("x_axis"),column=value.integer("y_axis")
        let valid=(0..<rows).contains(row) && (0..<columns).contains(column)
        return VStack(alignment:.leading,spacing:10) {
            if !valid { Text("当前孔位超出所选耗材，请点击孔位重新选择。").font(StudioTypography.caption).foregroundStyle(.red) }
            ScrollView(.horizontal) {
                WellGrid(rows:rows,columns:columns,row:row,column:column,cellSize:cellSize) { r,c in
                    raw=WellAddress.set(raw,row:r,column:c,rows:rows,columns:columns)
                }
            }.frame(height:24+Double(rows)*(cellSize+4))
                .background { GeometryReader { geometry in
                    let size=max(18,min(60,((geometry.size.width-28)/Double(columns)-4).rounded(.down)))
                    Color.clear.onChange(of:size,initial:true) { _,new in if cellSize != new { cellSize=new } }
                } }
            if valid {
                Text("起点 \(WellAddress.label(row:row,column:column)) → \(WellAddress.label(row:rows-1,column:columns-1)) · \((rows-row)*(columns-column)) 孔").font(StudioTypography.caption).monospacedDigit()
            }
        }
    }
}
