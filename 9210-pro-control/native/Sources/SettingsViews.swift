import SwiftUI

let parameterLabels:[String:String]=[
    "XPos":"X 位置 (mm)","YPos":"Y 位置 (mm)","ZPos":"Z 位置 (mm)","ZGradientPos":"完成后抬升 Z (mm)","ImbPos":"移液轴位置 (mm)",
    "AgainstZ":"靠壁 Z (mm)","AgainstXLeft":"靠左壁 X (mm)","AgainstXRight":"靠右壁 X (mm)","AdherentZ":"贴壁 Z (mm)","AdherentXLeft":"贴左壁 X (mm)","AdherentXRight":"贴右壁 X (mm)",
    "Name":"名称","Code":"型号代码","Factory":"厂家","Volume":"容量 (µL)","HoleRow":"行数","HoleColum":"列数","XSpacing":"X 孔距 (mm)","YSpacing":"Y 孔距 (mm)","XOffset":"X 偏移 (mm)","YOffset":"Y 偏移 (mm)","HoleDiameter":"孔径 (mm)","WellDiameter":"孔径 (mm)","LengthNum":"长度 (mm)","WidthNum":"宽度 (mm)","HeightNum":"高度 (mm)","DepthNum":"深度 (mm)","SupplyType":"耗材类型","ChannelNum":"通道数","StandardHeight":"标准高度 (mm)",
    "liquid_type":"液体名称","range":"量程 (µL)","model":"设备型号","parameter1":"曲线参数 1","parameter2":"曲线参数 2","liquid_id":"液体 ID","type":"类型","module":"量程 (µL)","trapping_type":"吸排类型","nature":"补偿方向 (0加/1减)","start_imbibing":"起始体积 (µL)","end_imbibing":"结束体积 (µL)","compensation":"补偿量 (µL)",
    "xCoefficient":"X 轴系数","yCoefficient":"Y 轴系数","zCoefficient":"Z 轴系数","imbCoefficient":"移液轴系数","xScrewPitch":"X 轴导程","yScrewPitch":"Y 轴导程","zScrewPitch":"Z 轴导程","imbScrewPitch":"移液轴导程","imbProportion":"移液换算比例","imbZero":"移液零位","imbLimitPos":"移液轴限位","xLimitPos":"X 限位","yLimitPos":"Y 限位","zLimitPos":"Z 设备限位参数",
    "loadSecondSpacing":"装头第二段距离","unLoadSpacing":"卸头距离","shockPlate":"震荡板位","shockModuleNumber":"震荡模块编号","trapPlate":"排液板位","unLoadPlate":"卸头板位","dosage":"默认量程","axis":"轴编号","axisName":"轴名称",
    "xFixedStep":"X 点动距离","yFixedStep":"Y 点动距离","zFixedStep":"Z 点动距离","imbibingFixedStep":"移液轴点动距离"
]
func fieldLabel(_ key:String)->String {
    let manualLabels=["xAccSpeed":"手动定位 X 加速度","xSpeed":"手动定位 X 速度","yAccSpeed":"手动定位 Y 加速度","ySpeed":"手动定位 Y 速度","zAccSpeed":"手动定位 Z 加速度","zSpeed":"手动定位 Z 速度"]
    if let label=manualLabels[key] { return label }
    if let type=ProgramSpeed.types.first(where:{ ProgramSpeed.configKeys[$0]==key }) { return "新程序 "+(ProgramSpeed.labels[type] ?? type)+" 默认档" }
    if let label=parameterLabels[key] { return label }
    let prefixes=[("zLoadSecond","装头第二段"),("zUnLoad","卸头"),("imbibing","吸液"),("mixAsp","混匀吸液"),("mixTrap","混匀排液"),("blow","吹样"),("trap","排液"),("x","X 轴"),("y","Y 轴"),("z","Z 轴")]
    for (prefix,name) in prefixes where key.hasPrefix(prefix) {
        let suffix=String(key.dropFirst(prefix.count))
        if let unit=["Gear":"速度档","AccSpeed":"加速度","Speed":"速度","JogSpeed":"点动速度"][suffix] { return name+unit }
    }
    return key
}

private struct SettingsParameterSection<Content:View>:View {
    let title:String
    let separated:Bool
    let content:Content
    init(_ title:String,separated:Bool=true,@ViewBuilder content:()->Content) {
        self.title=title;self.separated=separated;self.content=content()
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if separated { Divider().padding(.bottom,4) }
            Text(title).font(.system(size:13,weight:.semibold))
            VStack(alignment:.leading,spacing:8) { content }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct PositionSettingsView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var bluetooth:BluetoothController
    @State private var tableID=8
    @State private var plateNumber=1
    @State private var materialID=0
    @State private var showPlateJSON=false
    @State private var showNewTable=false
    @State private var pendingDeletion:DeckDeletion?
    private enum DeckDeletion {
        case table(id:Int,name:String),plate(tableID:Int,number:Int)
        var name:String { switch self { case .table(_,let name):return name;case .plate(_,let n):return "T\(n)" } }
        var message:String {
            switch self {
            case .table:return "组合及其板位设置将被移除。"
            case .plate:return "此板位将被移除，后续板位会重新编号。"
            }
        }
    }
    @State private var newTableName="新板位组合"
    @State private var newTableRange=20
    @State private var newTableCount=8
    @State private var calibrationDrafts:[String:PlateCalibrationDraft]=[:]
    @State private var isVisible=false
    @State private var sidebarWidth=530.0
    var tables:[JSONObject] { (model.workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 } }
    var table:JSONObject { model.workspace.worktable(tableID) }
    var plates:[JSONObject] { table.array("WorkTablets") }
    var plate:JSONObject { plates.first { $0.integer("Number")==plateNumber } ?? [:] }
    var draftKey:String { "\(tableID):\(plateNumber)" }
    var calibrationPlate:JSONObject { calibrationDrafts[draftKey]?.merging(into:plate) ?? plate }
    var hasCalibrationChanges:Bool { calibrationDrafts[draftKey]?.hasChanges ?? false }
    var materials:[JSONObject] { model.workspace.tables["Consumables"] as? [JSONObject] ?? [] }
    let coordinates=["XPos","YPos","ZPos","ZGradientPos"]
    private var plateList:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("底板与板位").font(StudioTypography.pageTitle)
            SettingsParameterSection("板位组合",separated:false) {
            Picker("板位组合",selection:Binding(get:{ tableID },set:{ selectTable($0) })) { ForEach(tables,id:\.selfID) { t in Text(tableLabel(t)).tag(t.integer("id")) } }
            HStack {
                Button("新建组合…") { showNewTable=true }
                Button("复制组合") { copyTable() }.disabled(table.isEmpty)
                Button("删除组合…",role:.destructive) { requestTableDeletion() }.disabled(table.isEmpty)
                Spacer(minLength:0)
            }
            TextField("组合名称",text:Binding(get:{ table.text("NickName",table.text("MatrixName")) },set:{ value in model.updateSettings { workspace in var rows=workspace.tables["WorkTable"] as? [JSONObject] ?? [];if let i=rows.firstIndex(where:{ $0.integer("id")==tableID }) { rows[i]["NickName"]=value;workspace.tables["WorkTable"]=rows } } })).studioInput(width:300).disabled(table.isEmpty)
            Picker("组合移液头",selection:Binding(get:{ model.workspace.tableHeadRange(tableID) ?? 0 },set:{ range in editSettings { try $0.setTableHeadRange(tableID,range:range) } })) {
                Text("未指定").tag(0);Text("20 µL").tag(20);Text("1000 µL").tag(1000)
            }.disabled(table.isEmpty)
            }
            Divider()
            Text("板位列表").font(.system(size:13,weight:.semibold))
            HStack { Text("板位").frame(width:40);Text("耗材").frame(maxWidth:.infinity,alignment:.leading);ForEach(["X","Y","Z","抬升Z"],id:\.self) { Text($0).frame(width:60,alignment:.trailing) } }
                .font(.system(size:12,weight:.semibold)).foregroundStyle(.primary)
                .padding(.horizontal,16).padding(.vertical,10)
                .background(Style.tableHeader)
                .overlay(alignment:.bottom) { Rectangle().fill(Style.line).frame(height:1) }
            List(selection:Binding(get:{ Optional(plateNumber) },set:{ if let n=$0 { selectPlate(n) } })) {
                ForEach(plates,id:\.plateID) { p in
                    HStack { Text("T\(p.integer("Number"))").fontWeight(.medium).frame(width:40);Text(p.object("Material").text("Name")).frame(maxWidth:.infinity,alignment:.leading);ForEach(["XPos","YPos","ZPos","ZGradientPos"],id:\.self) { key in Text(p.text(key,"0")).monospacedDigit().frame(width:60,alignment:.trailing) } }.font(.system(size:12)).frame(minHeight:36).padding(.vertical,3).tag(p.integer("Number")).listRowSeparator(.visible)
                }
            }.listStyle(.inset)
            HStack {
                Button("添加板位") { addPlate() }.disabled(table.isEmpty)
                Button("删除板位…",role:.destructive) { requestPlateDeletion() }.disabled(plate.isEmpty)
                Spacer(minLength:0)
            }
        }.padding(20).disabled(model.isRunning || model.manualBusy || model.isStopping)
    }
    private var plateDetails:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Text("T\(plateNumber) 位置参数").font(StudioTypography.paneTitle)
                    Spacer()
                    ContextSaveControls(model:model,title:"保存组合与耗材")
                        .help("组合与耗材仍自动保存；位置草稿请使用“保存此板位位置”。")
                }
                SettingsParameterSection("定位与标定",separated:false) {
                    ViewThatFits(in:.horizontal) {
                        HStack(alignment:.top,spacing:20) {
                            positionCoordinates.frame(width:290,alignment:.topLeading)
                            Divider().frame(height:360)
                            positionJog.frame(width:290,alignment:.topLeading)
                        }.fixedSize(horizontal:false,vertical:true)
                        VStack(alignment:.leading,spacing:20) {
                            positionCoordinates
                            Divider()
                            positionJog
                        }
                    }
                }
                SettingsParameterSection("板位耗材") {
                Text(plate.object("Material").text("Name","未设置"))
                Picker("选择",selection:$materialID) { Text("请选择耗材").tag(0);ForEach(materials,id:\.consumableID) { m in Text(m.text("Name")).tag(m.integer("consumable_id")) } }
                HStack {
                    Button("应用耗材到此板位") { if let m=materials.first(where:{ $0.integer("consumable_id")==materialID }) { model.updateSettings { $0.assignMaterial(m,tableID:tableID,number:plateNumber) } } }.disabled(materialID==0)
                    Button("清空耗材") { model.updateSettings { $0.updatePlate(tableID:tableID,number:plateNumber) { $0["Material"]=JSONObject() } } }
                }
                }
                SettingsParameterSection("预设位置") {
                DisclosureGroup("贴壁 / 靠壁坐标") { VStack(spacing:8) { ForEach(["AgainstZ","AgainstXLeft","AgainstXRight","AdherentZ","AdherentXLeft","AdherentXRight"],id:\.self) { key in plateField(key) } }.padding(.top,8) }
                DisclosureGroup("更多 Z 高度") {
                    VStack(spacing:8) {
                        ForEach(Array(calibrationPlate.array("zMorePosBean").enumerated()),id:\.offset) { i,row in
                            HStack {
                                TextField("名称",text:heightBinding(i,"name")).studioInput(width:160)
                                ValidatedNumericField("mm",text:heightBinding(i,"pos"),rule:.decimal(min:0)).frame(width:80).accessibilityLabel("更多 Z 高度 \(i+1)")
                                Button { updateHeight { if $0.indices.contains(i) { $0.remove(at:i) } } } label:{ Image(systemName:"minus.circle") }
                            }
                        }
                        Button("新增高度") { updateHeight { $0.append(["id":($0.map { $0.integer("id") }.max() ?? 0)+1,"name":"高度 \($0.count+1)","pos":calibrationPlate.text("ZPos","0"),"isSelect":false]) } }
                        Text("可在步骤参数中选择这些 Z 高度。").font(StudioTypography.caption).foregroundStyle(.secondary)
                    }.padding(.top,8)
                }
                Button("板位完整参数草稿…") { showPlateJSON=true }
                }
            }.padding(22).font(.system(size:13)).disabled(table.isEmpty || plate.isEmpty || model.isRunning || model.manualBusy || model.isStopping)
        }
    }
    var body:some View {
        LiveTwoColumns(leftWidth:$sidebarWidth,minimum:530,rightMinimum:340,label:"调整板位列表与参数栏宽度",left:plateList,right:plateDetails)
        .onAppear {
            isVisible=true
            restoreRememberedSelection()
            readCurrentPositionIfIdle()
        }.onDisappear { isVisible=false }
        .onChange(of:bluetooth.ready) { _,ready in if ready { readCurrentPositionIfIdle() } }
        .onChange(of:model.mode) { _,_ in readCurrentPositionIfIdle() }
        .onChange(of:model.workspaceIdentity) { _,_ in
            // Imported workspaces may reuse table IDs and plate numbers.
            // Their coordinates must never inherit a previous workspace's draft.
            calibrationDrafts.removeAll();materialID=0;showPlateJSON=false
            restoreRememberedSelection()
            readCurrentPositionIfIdle()
        }
        .alert("删除「\(pendingDeletion?.name ?? "")」？",isPresented:Binding(get:{ pendingDeletion != nil },set:{ if !$0 { pendingDeletion=nil } }),presenting:pendingDeletion) { request in
            Button("取消",role:.cancel) {}
            Button("删除",role:.destructive) { applyDeletion(request) }
        } message:{ request in Text(request.message) }
        .sheet(isPresented:$showNewTable) {
            VStack(alignment:.leading,spacing:16) {
                Text("新建板位组合").font(.title2)
                TextField("组合名称",text:$newTableName).studioInput(width:300)
                Picker("移液头量程",selection:$newTableRange) { Text("20 µL").tag(20);Text("1000 µL").tag(1000) }
                Stepper("板位数：\(newTableCount)",value:$newTableCount,in:1...48)
                Text("创建空白板位，坐标均为0；创建后设置各板位坐标和耗材。沿用现有坐标可选择“复制组合”。").font(StudioTypography.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer();Button("取消") { showNewTable=false }
                    Button("创建") { createTable() }.disabled(newTableName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }.padding(22).frame(width:440)
        }
        .sheet(isPresented:$showPlateJSON) {
            JSONEditor(title:"T\(plateNumber) 参数草稿 · 应用后仍需保存此板位位置",initial:pretty(calibrationPlate),onSave:{ text in
                do { guard let object=try jsonObject(Data(text.utf8)) as? JSONObject,object.integer("Number")==plateNumber else { throw ControlError.invalid("板位需要 JSON 对象且板位编号保持一致") };updateCalibration { $0.replace(with:object) };showPlateJSON=false } catch { model.error=error.localizedDescription }
            },onCancel:{ showPlateJSON=false })
        }
    }
    private var positionCoordinates:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("板位坐标").font(.system(size:13,weight:.semibold)).padding(.bottom,4)
            ForEach(coordinates,id:\.self) { key in plateField(key) }
            Picker("孔行 Y 方向",selection:Binding(get:{ (calibrationPlate["_macFirstRow"] as? Bool ?? (plateNumber<=plates.count/2)) ? 1 : 0 },set:{ value in updateCalibration { $0.set("_macFirstRow",value:value==1) } })) {
                Text("行号增加，Y 减小").tag(1);Text("行号增加，Y 增大").tag(0)
            }
            HStack { Text("移液轴位置（资料）");Spacer();Text(plate.text("ImbPos","未设置")).monospacedDigit() }.font(StudioTypography.caption).foregroundStyle(.secondary)
            Button("移动到所选板位") { model.moveToPlate(tableID:tableID,number:plateNumber) }
                .disabled(plate.isEmpty || model.manualBusy || model.isStopping || bluetooth.busy || (model.mode=="hardware" && !bluetooth.ready))
            Text("T\(plateNumber) 上方：X \(plate.text("XPos")) / Y \(plate.text("YPos")) / Z 0 mm").font(StudioTypography.caption).foregroundStyle(.secondary)
            Button("用当前 X / Y / Z 填入") {
                let values=model.positionMM;guard values.count==4 else { return }
                updateCalibration { draft in for (i,key) in ["XPos","YPos","ZPos"].enumerated() { draft.set(key,value:formatNumber(values[i])) } }
            }.disabled(model.mode != "hardware" || !bluetooth.ready || model.positionMM.count != 4 || model.manualFault != nil)
            HStack(spacing:8) {
                Button("保存此板位位置") { saveCalibration() }.buttonStyle(.borderedProminent).disabled(!hasCalibrationChanges)
                Button("还原草稿") { calibrationDrafts.removeValue(forKey:draftKey) }.disabled(!hasCalibrationChanges)
            }.padding(.top,6)
            Text(hasCalibrationChanges ? "有未保存的位置草稿 · 正式板位坐标未改变" : "当前显示已保存的位置")
                .font(StudioTypography.caption).foregroundStyle(hasCalibrationChanges ? Color.accentColor : Color.secondary)
            Text("移动到板位使用已保存的 X/Y；读取当前位置不会自动改写板位。")
                .font(StudioTypography.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var positionJog:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(model.mode=="simulation" ? "模拟位置 / 点动" : "当前位置 / 点动").font(.system(size:13,weight:.semibold)).padding(.bottom,4)
            if model.positionMM.count==4 { Text(zip(["X","Y","Z","移液轴"],model.positionMM).map { "\($0.0) \(formatNumber($0.1))" }.joined(separator:"   ")).monospacedDigit() }
            else { Text("尚未读取位置").foregroundStyle(.secondary) }
            Button("读取当前位置") { model.query(true) }.disabled(model.mode != "hardware" || !bluetooth.ready || bluetooth.busy || model.manualBusy || model.isStopping)
            ForEach(Array([("X","xFixedStep",1,2,"左","右"),("Y","yFixedStep",17,18,"前","后"),("Z","zFixedStep",33,34,"上","下"),("移液轴","imbibingFixedStep",49,50,"吸","排")].enumerated()),id:\.offset) { _,row in
                HStack {
                Text(row.0).frame(width:45,alignment:.leading)
                ValidatedNumericField("距离",text:Binding(get:{ model.workspace.config.text(row.1) },set:{ value in model.updateTables { tables in var c=tables["ZWorkConfig"] as? JSONObject ?? [:];c[row.1]=value;tables["ZWorkConfig"]=c } }),rule:.decimal(min:Double.leastNonzeroMagnitude)).frame(width:70).accessibilityLabel(row.0+" 点动距离")
                Text("mm").foregroundStyle(.secondary)
                Button(row.4) { model.jog(direction:row.2,distance:model.workspace.config.text(row.1)) }
                Button(row.5) { model.jog(direction:row.3,distance:model.workspace.config.text(row.1)) }
                }.studioParameterRow().disabled(model.manualBusy || model.isStopping || bluetooth.busy || (model.mode == "hardware" && !bluetooth.ready))
            }
            Text("每次移动自动读取并核对坐标；Z 不按设备限位参数限制最大位置。").font(StudioTypography.caption).foregroundStyle(.secondary)
            if !model.manualStatus.isEmpty { Text(model.manualStatus).font(StudioTypography.caption) }
            if let fault=model.manualFault { Text(fault).font(StudioTypography.caption).foregroundStyle(.red) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func heightBinding(_ i:Int,_ key:String)->Binding<String> { Binding(get:{ let rows=calibrationPlate.array("zMorePosBean");return rows.indices.contains(i) ? rows[i].text(key) : "" },set:{ value in updateHeight { if $0.indices.contains(i) { $0[i][key]=value } } }) }
    func updateHeight(_ change:(inout [JSONObject])->Void) {
        var rows=calibrationPlate.array("zMorePosBean");change(&rows)
        updateCalibration { $0.set("zMorePosBean",value:rows) }
    }
    func plateField(_ key:String)->some View { HStack(spacing:16) { Text(fieldLabel(key)).frame(maxWidth:.infinity,alignment:.leading);ValidatedNumericField("未设置",text:Binding(get:{ calibrationPlate.text(key) },set:{ value in updateCalibration { $0.set(key,value:value.isEmpty ? nil : value) } }),rule:.decimal(min:0,allowEmpty:!coordinates.contains(key))).multilineTextAlignment(.trailing).monospacedDigit().frame(width:112).accessibilityLabel(fieldLabel(key)) }.studioParameterRow() }
    func tableLabel(_ table:JSONObject)->String {
        let range=table.integer("_macHeadRange")
        return table.text("NickName",table.text("MatrixName","组合 \(table.integer("id"))"))+" · "+([20,1000].contains(range) ? "\(range) µL" : "量程未指定")
    }
    func editSettings(_ change:(inout Workspace) throws ->Void) {
        var failure:Error?
        model.updateSettings { workspace in do { try change(&workspace) } catch { failure=error } }
        if let failure=failure { model.error=failure.localizedDescription }
    }
    func updateCalibration(_ change:(inout PlateCalibrationDraft)->Void) {
        guard !plate.isEmpty,!model.manualControlsLocked else { return }
        var draft=calibrationDrafts[draftKey] ?? PlateCalibrationDraft(plate:plate,tableID:tableID)
        change(&draft);calibrationDrafts[draftKey]=draft
    }
    func saveCalibration() {
        guard let draft=calibrationDrafts[draftKey],draft.hasChanges,!model.manualControlsLocked else { return }
        var failure:Error?
        model.updateSettings { workspace in
            do { try workspace.savePlateCalibration(draft,tableID:tableID,number:plateNumber) }
            catch { failure=error }
        }
        if let failure=failure { model.error=failure.localizedDescription;return }
        calibrationDrafts.removeValue(forKey:draftKey);model.save()
    }
    func readCurrentPositionIfIdle() {
        guard isVisible,model.mode=="hardware",bluetooth.ready,!bluetooth.busy,!model.manualControlsLocked else { return }
        model.query(true)
    }
    func rememberSelection() {
        guard !plate.isEmpty,!model.manualControlsLocked else { return }
        let stored=model.workspace.tables["_macPositionSelection"] as? JSONObject ?? [:]
        if stored.integer("tableID")==tableID,stored.integer("plateNumber")==plateNumber,
           stored.object("plateByTable").integer(String(tableID))==plateNumber { return }
        let selection=PositionSettingsSelection(tableID:tableID,plateNumber:plateNumber)
        model.updateSettings { $0.rememberPositionSettingsSelection(selection) }
    }
    func restoreRememberedSelection() {
        let remembered=model.workspace.positionSettingsSelection()
        tableID=remembered.tableID;plateNumber=remembered.plateNumber
        // Record a valid first display too, before a later manual-page change
        // can alter the legacy fallback. Already remembered selections are a no-op.
        rememberSelection()
    }
    func selectTable(_ id:Int,plateNumber requested:Int?=nil) {
        let remembered=model.workspace.positionSettingsSelection(tableID:id)
        tableID=remembered.tableID
        plateNumber=requested.flatMap { n in plates.contains(where:{ $0.integer("Number")==n }) ? n : nil } ?? remembered.plateNumber
        materialID=0;rememberSelection()
    }
    func selectPlate(_ number:Int) { plateNumber=number;materialID=0;rememberSelection() }
    func copyTable() {
        var copied:Int?
        model.updateSettings { copied=$0.copyTable(tableID) }
        if let copied=copied { selectTable(copied) }
    }
    func createTable() {
        var created:Int?
        editSettings { created=try $0.createTable(name:newTableName,range:newTableRange,plateCount:newTableCount) }
        if let created=created { selectTable(created,plateNumber:1);showNewTable=false }
    }
    func clearCalibrationDrafts(tableID:Int) { calibrationDrafts=calibrationDrafts.filter { !$0.key.hasPrefix("\(tableID):") } }
    func addPlate() {
        var added:Int?
        editSettings { added=try $0.addTablePlate(tableID) }
        if let added=added { selectPlate(added) }
    }
    private func requestTableDeletion() {
        if let issue=model.workspace.tableRemovalIssue(tableID) { model.error=issue;return }
        pendingDeletion = .table(id:tableID,name:table.text("NickName",table.text("MatrixName","板位组合")))
    }
    private func requestPlateDeletion() {
        if let issue=model.workspace.plateRemovalIssue(tableID:tableID,number:plateNumber) { model.error=issue;return }
        pendingDeletion = .plate(tableID:tableID,number:plateNumber)
    }
    private func applyDeletion(_ request:DeckDeletion) {
        guard !model.manualControlsLocked else { return }
        switch request {
        case .plate(let id,let number):
            guard id==tableID,number==plateNumber else { return }
            let previousCount=plates.count
            editSettings { try $0.removeTablePlate(tableID:id,number:number,archive:false) }
            if plates.count != previousCount { clearCalibrationDrafts(tableID:id);selectPlate(min(number,plates.count)) }
        case .table(let id,_):
            guard id==tableID else { return }
            editSettings { try $0.removeTable(id,archive:false) }
            if model.workspace.worktable(id).isEmpty { clearCalibrationDrafts(tableID:id);selectTable(model.workspace.positionSettingsSelection().tableID) }
        }
    }

}
extension Dictionary where Key==String,Value==Any { var consumableID:Int { integer("consumable_id") } }

struct SpeedSettingsView:View {
    @ObservedObject var model:AppModel
    @State private var selected="XSpeed"
    @State private var page="speeds"
    @State private var parameterGroup="X 轴"
    @AppStorage("speedNavigationWidth") private var leftWidth=220.0
    let names=["XSpeed":"X 轴","YSpeed":"Y 轴","ZSpeed":"Z 轴","LoadSecondSpeed":"装头第二段","UnLoadSpeed":"退头参数","AspSpeed":"吸液","TrapSpeed":"排液","MixAspSpeed":"混匀吸液","MixTrapSpeed":"混匀排液","BlowSpeed":"吹样"]
    let positioningSpeedKeys=["xAccSpeed","xSpeed","yAccSpeed","ySpeed","zAccSpeed","zSpeed"]
    let preservedKeys=SpeedTable.legacyKeys+["axis","axisName","dosage","imbZero","trapPlate","unLoadPlate","id","zLimitPos"]
    var groups:[JSONObject] { model.workspace.tables["SpeedConfig"] as? [JSONObject] ?? [] }
    var rows:[JSONObject] { groups.first { $0.text("SpeedType")==selected }?.array("SpeedList") ?? [] }
    private var speedSections:[(name:String,types:[String])] {
        let definitions=[("定位轴",["XSpeed","YSpeed","ZSpeed"]),("液体操作",["AspSpeed","TrapSpeed","MixAspSpeed","MixTrapSpeed","BlowSpeed"]),("枪头操作",["LoadSecondSpeed","UnLoadSpeed"])]
        let known=Set(definitions.flatMap { $0.1 })
        var sections=definitions.map { (name:$0.0,types:$0.1.filter { type in groups.contains { $0.text("SpeedType")==type } }) }.filter { !$0.types.isEmpty }
        let other=groups.map { $0.text("SpeedType") }.filter { !known.contains($0) }
        if !other.isEmpty { sections.append((name:"其他速度",types:other)) }
        return sections
    }
    private var parameterGroups:[(name:String,keys:[String],readOnly:Bool)] {
        let definitions:[(String,[String])]=[
            ("X 轴",["xCoefficient","xScrewPitch","xLimitPos","xFixedStep"]),
            ("Y 轴",["yCoefficient","yScrewPitch","yLimitPos","yFixedStep"]),
            ("Z 轴",["zCoefficient","zScrewPitch","zFixedStep"]),
            ("移液轴",["imbCoefficient","imbScrewPitch","imbProportion","imbLimitPos","imbibingFixedStep"]),
            ("装头与卸头",["loadSecondSpacing","unLoadSpacing"]),
            ("新程序默认档位",ProgramSpeed.types.compactMap { ProgramSpeed.configKeys[$0] }),
            ("附件",["shockPlate","shockModuleNumber"])
        ]
        var remaining=Set(model.workspace.config.keys.filter { !preservedKeys.contains($0) && !positioningSpeedKeys.contains($0) })
        var result:[(name:String,keys:[String],readOnly:Bool)]=[]
        for (name,ordered) in definitions {
            let keys=ordered.filter { remaining.contains($0) }
            if !keys.isEmpty { result.append((name,keys,false));remaining.subtract(keys) }
        }
        if !remaining.isEmpty { result.append(("其他参数",remaining.sorted(),false)) }
        let positioning=positioningSpeedKeys.filter { model.workspace.config[$0] != nil }
        if !positioning.isEmpty { result.append(("定位速度保留值",positioning,true)) }
        let preserved=preservedKeys.filter { model.workspace.config[$0] != nil }
        if !preserved.isEmpty { result.append(("原 APP 保留值",preserved,true)) }
        return result
    }
    private var selectedParameters:(name:String,keys:[String],readOnly:Bool)? { parameterGroups.first { $0.name==parameterGroup } ?? parameterGroups.first }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("速度与设备参数").font(StudioTypography.pageTitle)
                Spacer()
                Picker("设置内容",selection:$page) { Text("速度表").tag("speeds");Text("设备参数").tag("parameters") }
                    .pickerStyle(.segmented).frame(width:260)
            }.padding(20)
            Divider()
            LiveTwoColumns(leftWidth:$leftWidth,minimum:180,rightMinimum:432,label:"调整设置列表与参数栏宽度",left:navigation,right:Group {
                if page=="speeds" { speedDetail }
                else { parameterDetail }
            })
        }.disabled(model.isRunning)
        .onAppear { if !groups.contains(where:{ $0.text("SpeedType")==selected }) { selected=groups.first?.text("SpeedType") ?? "" } }
    }
    private var navigation:some View {
        VStack(alignment:.leading,spacing:0) {
            Text(page=="speeds" ? "速度类型" : "参数分类").font(.system(size:13,weight:.semibold)).padding(16)
            Divider()
            if page=="speeds" {
                List(selection:Binding<String?>(get:{ selected },set:{ if let value=$0 { selected=value } })) {
                    ForEach(speedSections,id:\.name) { section in
                        Section {
                            ForEach(section.types,id:\.self) { type in
                                Text(names[type] ?? type)
                                    .font(StudioTypography.row).frame(maxWidth:.infinity,minHeight:32,alignment:.leading)
                                    .tag(type).listRowSeparator(.visible)
                            }
                        } header: {
                            Text(section.name).font(.system(size:12,weight:.semibold)).foregroundStyle(.primary).padding(.top,8)
                        }
                    }
                }.listStyle(.inset)
            } else {
                List(selection:Binding<String?>(get:{ selectedParameters?.name },set:{ if let value=$0 { parameterGroup=value } })) {
                    ForEach(parameterGroups,id:\.name) { group in
                        HStack { Text(group.name);Spacer(minLength:4);if group.readOnly { Text("只读").font(StudioTypography.caption).foregroundStyle(.secondary) } }
                            .font(StudioTypography.row).frame(minHeight:34).tag(group.name).listRowSeparator(.visible)
                    }
                }.listStyle(.inset)
            }
            Divider()
            Button("恢复默认栏宽") { leftWidth=220 }.controlSize(.small).padding(12)
        }.frame(maxHeight:.infinity,alignment:.topLeading)
    }
    private var speedDetail:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text((names[selected] ?? selected)+"速度").font(StudioTypography.paneTitle);Spacer();ContextSaveControls(model:model,title:"保存速度") }.padding([.top,.horizontal],22)
            Text("速度与加速度为 0–255 整数，沿用设备单位。")
                .font(StudioTypography.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.top,8).padding(.bottom,16)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:24) { Text("档位").frame(width:48);Text("加速度").frame(width:112,alignment:.trailing);Text("速度").frame(width:112,alignment:.trailing);Spacer(minLength:0) }
                        .font(.system(size:12,weight:.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal,12).padding(.vertical,12).background(Style.tableHeader)
                        .overlay(alignment:.bottom) { Rectangle().fill(Style.line).frame(height:1) }
                    ForEach(rows,id:\.gear) { row in
                        HStack(spacing:24) {
                            Text("\(row.integer("gear"))").font(.system(size:13,weight:.medium)).monospacedDigit().frame(width:48)
                            speedField(row.integer("gear"),"accSpeed").frame(width:112)
                            speedField(row.integer("gear"),"speed").frame(width:112)
                            Spacer(minLength:0)
                        }.padding(.horizontal,2).studioParameterRow()
                    }
                    Divider().padding(.top,12).padding(.bottom,16)
                    Text(ProgramSpeed.types.contains(selected)
                         ? "此表供新程序或程序通用速度重新选档时读取。已保存的程序保持自身数值；修改现有程序请打开“通用速度”。"
                         : "吸液、排液与混匀步骤按所选档位读取此表；修改后会用于下一次执行。")
                        .font(StudioTypography.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:580,alignment:.leading).padding(.horizontal,22).padding(.bottom,22).padding(.top,16).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    @ViewBuilder private var parameterDetail:some View {
        if let group=selectedParameters {
            VStack(alignment:.leading,spacing:0) {
                HStack { Text(group.name).font(StudioTypography.paneTitle);Spacer();if !group.readOnly { ContextSaveControls(model:model,title:"保存参数") } }.padding([.top,.horizontal],22)
                Text(group.readOnly ? "原值保留 · 只读" : "设备参数").font(StudioTypography.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.top,8).padding(.bottom,16)
                Divider()
                if group.readOnly {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            Text(group.name=="定位速度保留值"
                                 ? "当前固件不采用这些定位速度字段；板位定位与 Z 回零使用固件固定速度。"
                                 : "这些原 APP 字段不参与当前指令。Z 限位为设备维护原值，不作为 Mac 的 Z 行程限制。")
                                .font(StudioTypography.caption).foregroundStyle(.secondary)
                            ForEach(group.keys,id:\.self) { key in
                                HStack { Text(fieldLabel(key));Spacer(minLength:24);Text(model.workspace.config.text(key)).monospacedDigit() }.studioParameterRow().help(key)
                            }
                        }.font(StudioTypography.body).frame(maxWidth:720,alignment:.leading).padding(22)
                    }
                } else {
                    RecordFields(title:group.name,object:Binding(get:{ model.workspace.config },set:{ value in model.updateTables { $0["ZWorkConfig"]=value } }),keys:group.keys,showsTitle:false,groupsFields:false)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        } else { Text("没有设备参数").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
    }
    func speedField(_ gear:Int,_ key:String)->some View { ValidatedNumericField("0",text:Binding(get:{ rows.first { $0.integer("gear")==gear }?.text(key) ?? "" },set:{ value in
        model.updateTables { tables in var all=tables["SpeedConfig"] as? [JSONObject] ?? [];guard let g=all.firstIndex(where:{ $0.text("SpeedType")==selected }) else { return };var list=all[g].array("SpeedList");guard let i=list.firstIndex(where:{ $0.integer("gear")==gear }) else { return };list[i][key]=value;all[g]["SpeedList"]=list;tables["SpeedConfig"]=all }
    }),rule:.integer(min:0,max:255)).multilineTextAlignment(.trailing).accessibilityLabel("\(names[selected] ?? selected) 第\(gear)档 \(key=="accSpeed" ? "加速度" : "速度")") }
}

extension Dictionary where Key==String,Value==Any { var speedType:String { text("SpeedType") };var gear:Int { integer("gear") } }

struct RecordFields:View {
    let title:String
    @Binding var object:JSONObject
    let keys:[String]
    var showsTitle=true
    var groupsFields=true
    private var fieldGroups:[(title:String,keys:[String])] {
        let definitions:[(String,[String])]=[
            ("基本信息",["Name","Code","Factory","liquid_type","liquid_id","model","type","SupplyType"]),
            ("容量与通道",["Volume","range","module","ChannelNum"]),
            ("孔位与间距",["HoleRow","HoleColum","HoleDiameter","WellDiameter","XSpacing","YSpacing","XOffset","YOffset","IsStright"]),
            ("外形尺寸",["LengthNum","WidthNum","HeightNum","DepthNum","StandardHeight"]),
            ("曲线参数",["parameter1","parameter2"]),
            ("补偿设置",["trapping_type","nature","start_imbibing","end_imbibing","compensation"]),
            ("X 轴",["xCoefficient","xScrewPitch","xLimitPos","xFixedStep"]),
            ("Y 轴",["yCoefficient","yScrewPitch","yLimitPos","yFixedStep"]),
            ("Z 轴",["zCoefficient","zScrewPitch","zLimitPos","zFixedStep"]),
            ("移液轴",["imbCoefficient","imbScrewPitch","imbProportion","imbLimitPos","imbibingFixedStep"]),
            ("装头与卸头",["loadSecondSpacing","unLoadSpacing"]),
            ("新程序默认速度档",ProgramSpeed.types.compactMap { ProgramSpeed.configKeys[$0] }),
            ("附件",["shockPlate","shockModuleNumber"])
        ]
        var remaining=Set(keys),result:[(title:String,keys:[String])]=[]
        for (title,ordered) in definitions {
            let group=ordered.filter { remaining.contains($0) }
            guard !group.isEmpty else { continue }
            result.append((title,group));remaining.subtract(group)
        }
        let others=keys.filter { remaining.contains($0) }
        if !others.isEmpty { result.append((result.isEmpty ? "参数" : "其他参数",others)) }
        return result
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if showsTitle { Text(title).font(StudioTypography.paneTitle) }
                if groupsFields {
                    let groups=fieldGroups
                    ForEach(Array(groups.enumerated()),id:\.offset) { index,group in
                        SettingsParameterSection(group.title,separated:index>0) {
                            ForEach(group.keys,id:\.self) { key in fieldRow(key) }
                        }
                    }
                } else {
                    VStack(spacing:10) {
                        ForEach(keys,id:\.self) { key in
                            fieldRow(key)
                        }
                    }
                }
            }.font(.system(size:13)).frame(maxWidth:600,alignment:.leading).padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func fieldRow(_ key:String)->some View {
        HStack(spacing:16) {
            Text(fieldLabel(key)).frame(minWidth:140,maxWidth:.infinity,alignment:.leading)
            if let value=object[key] as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() {
                Toggle("",isOn:Binding(get:{ object[key] as? Bool ?? false },set:{ object[key]=$0 })).labelsHidden()
            } else if let rule=NumericRules.parameter(key:key) {
                ValidatedNumericField("数字",text:Binding(get:{ object.text(key) },set:{ object[key]=$0 }),rule:rule)
                    .multilineTextAlignment(.trailing).monospacedDigit().frame(width:120).accessibilityLabel(fieldLabel(key))
            } else {
                TextField("",text:Binding(get:{ object.text(key) },set:{ object[key]=$0 })).studioInput(width:200).accessibilityLabel(fieldLabel(key))
            }
        }.studioParameterRow().help(key)
    }
}

