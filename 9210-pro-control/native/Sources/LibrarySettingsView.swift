import SwiftUI

struct LibrarySettingsView:View {
    @ObservedObject var model:AppModel
    @State private var tableName="Curve"
    @State private var index:Int?=0
    @State private var moduleFilter:Int?=nil
    @State private var draft:JSONObject=[:]
    @State private var showJSON=false
    @State private var newRecordRequest:LibraryRecordCreationRequest?=nil
    @AppStorage("libraryListWidth") private var leftWidth=340.0
    private let categories=["LiquidParameters","Curve","LiquidCompensation","Consumables"]
    private let names=["LiquidParameters":"液体","Curve":"液体曲线","LiquidCompensation":"液体补偿","Consumables":"耗材库"]
    private var rows:[JSONObject] { model.workspace.tables[tableName] as? [JSONObject] ?? [] }
    private var liquids:[JSONObject] { model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? [] }
    private var moduleKey:String? { tableName=="Curve" ? "range" : tableName=="LiquidCompensation" ? "module" : nil }
    private var modules:[Int] {
        guard let key=moduleKey else { return [] }
        return Set([20,1000]+rows.map { $0.integer(key) }).sorted()
    }
    // Selection and edits always retain the source index, even with a filtered list.
    private var visibleIndices:[Int] {
        let rows=self.rows
        return rows.indices.filter { i in
            guard let key=moduleKey,let module=moduleFilter else { return true }
            return rows[i].integer(key)==module
        }
    }
    private var selected:JSONObject {
        let rows=self.rows
        guard let i=index,rows.indices.contains(i) else { return [:] }
        let row=rows[i]
        if let key=moduleKey,let filter=moduleFilter,row.integer(key) != filter { return [:] }
        return row
    }
    private var editableKeys:[String] {
        if tableName=="Consumables" { return ["Name","Code","Factory","Volume","SupplyType","HoleRow","HoleColum","HoleDiameter","XSpacing","YSpacing","XOffset","YOffset","LengthNum","WidthNum","HeightNum","DepthNum","ChannelNum","IsStright"] }
        return selected.keys.sorted().filter { !["curve_id","liquid_compensation_id","isSelect"].contains($0) }
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("液体与耗材").font(StudioTypography.pageTitle)
                Spacer()
                Picker("资料",selection:$tableName) { ForEach(categories,id:\.self) { key in Text(names[key] ?? key).tag(key) } }.pickerStyle(.segmented).frame(maxWidth:520)
            }.padding(20)
            Divider()
            LiveTwoColumns(leftWidth:$leftWidth,minimum:260,rightMinimum:420,label:"调整资料列表与参数栏宽度",left:libraryList,right:detail)
            Divider()
            Text(tableName=="Consumables" ? "耗材库修改后，可在“位置 / 底板”中重新应用到板位。普通板行列偏移均沿用 X 孔距，384 孔板行偏移使用 Y 孔距。容量、通道、尺寸和偏移不会自动改变板位坐标。" : "液体 ID 关联曲线、补偿与步骤；模块筛选仅改变显示范围。")
                .font(StudioTypography.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,12)
        }
        .disabled(model.manualControlsLocked)
        .onChange(of:tableName) { reconcileSelection() }
        .onChange(of:moduleFilter) { reconcileSelection() }
        .onChange(of:rows.count) { reconcileSelection() }
        .sheet(item:$newRecordRequest) { request in
            LibraryRecordCreationSheet(model:model,request:request,onCreate:{ name,liquidID,module in
                createRecord(request:request,name:name,liquidID:liquidID,module:module)
            })
        }
        .sheet(isPresented:$showJSON) {
            JSONEditor(title:"完整参数",initial:pretty(draft),onSave:{ text in
                do { guard let value=try jsonObject(Data(text.utf8)) as? JSONObject else { throw ControlError.invalid("需要 JSON 对象") };replace(value);showJSON=false }
                catch { model.error=error.localizedDescription }
            },onCancel:{ showJSON=false })
        }
    }
    private var libraryList:some View {
        let rows=self.rows, visibleIndices=self.visibleIndices
        return VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(names[tableName] ?? tableName).font(.system(size:13,weight:.semibold))
                    Spacer()
                    Text(moduleFilter != nil && moduleKey != nil ? "\(visibleIndices.count) / \(rows.count) 条" : "\(rows.count) 条").font(StudioTypography.caption).foregroundStyle(.secondary)
                }
                if moduleKey != nil {
                    Picker("按模块查看",selection:$moduleFilter) {
                        Text("全部模块").tag(Optional<Int>.none)
                        ForEach(modules,id:\.self) { module in Text(moduleLabel(module)).tag(Optional(module)) }
                    }.accessibilityLabel("按模块查看")
                }
            }.padding(16)
            Divider()
            List(selection:$index) {
                ForEach(visibleIndices,id:\.self) { i in
                    VStack(alignment:.leading,spacing:5) {
                        Text(rowName(rows[i])).font(StudioTypography.row).lineLimit(2)
                        Text(rowDetail(rows[i])).font(StudioTypography.metadata).studioMetadata(selected:index==i).lineLimit(2)
                    }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).padding(.vertical,7).tag(i).listRowSeparator(.visible)
                }
            }.listStyle(.inset)
                .overlay {
                    if visibleIndices.isEmpty {
                        VStack(spacing:8) {
                            Text("暂无\(names[tableName] ?? "")记录").font(StudioTypography.row)
                            Text(moduleFilter.map { moduleLabel($0)+" · 点击新增创建记录" } ?? "点击新增创建记录").font(StudioTypography.caption).foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                    }
                }
            Divider()
            HStack {
                Button("新增…") { beginNewRecord() }
                Button("复制") { duplicateRecord() }.disabled(selected.isEmpty)
                Spacer(minLength:8)
                Button("删除",role:.destructive) { deleteRecord() }.disabled(selected.isEmpty)
            }.padding(14)
        }
    }
    private var detail:some View {
        VStack(alignment:.leading,spacing:0) {
            if !selected.isEmpty {
                HStack {
                    Text(rowName(selected)).font(StudioTypography.paneTitle).lineLimit(2)
                    Spacer()
                    ContextSaveControls(model:model,title:tableName=="Consumables" ? "保存耗材" : "保存液体")
                }.padding(20)
                Divider()
                RecordFields(title:rowName(selected),object:Binding(get:{ selected },set:{ value in replace(value) }),keys:editableKeys,showsTitle:false)
                Divider()
                HStack {
                    Button("完整参数…") { draft=selected;showJSON=true }
                    Spacer()
                    if tableName=="Consumables" {
                        Text("容量、通道和尺寸不会自动改变板位坐标。")
                            .font(StudioTypography.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
            } else {
                Text("选择一条记录查看参数").font(StudioTypography.body).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
    }
    private func moduleLabel(_ module:Int)->String { module>0 ? "\(module) µL" : "未指定模块" }
    private func rowName(_ row:JSONObject)->String {
        if tableName=="Consumables" { return row.text("Name","未命名耗材") }
        let name=liquids.first { $0.integer("liquid_id")==row.integer("liquid_id") }?.text("liquid_type") ?? row.text("liquid_type","液体")
        return name+(moduleKey.map { " · "+moduleLabel(row.integer($0)) } ?? "")
    }
    private func rowDetail(_ row:JSONObject)->String {
        if tableName=="Consumables" { return "\(row.integer("HoleRow")) × \(row.integer("HoleColum")) · \(row.text("Factory"))" }
        if tableName=="Curve" { return "p1 \(row.text("parameter1"))   p2 \(row.text("parameter2"))" }
        if tableName=="LiquidCompensation" {
            let direction=row.integer("nature")==1 ? "−" : "+"
            return "\(row.text("start_imbibing"))–\(row.text("end_imbibing")) µL · 补偿 \(direction)\(row.text("compensation")) µL"
        }
        return "ID \(row.integer("liquid_id"))"
    }
    private func reconcileSelection() {
        if let i=index,visibleIndices.contains(i) { return }
        index=visibleIndices.first
    }
    private func replace(_ value:JSONObject) {
        guard !model.manualControlsLocked,let i=index,rows.indices.contains(i) else { return }
        model.updateTables { tables in
            var all=tables[tableName] as? [JSONObject] ?? []
            guard all.indices.contains(i) else { return }
            all[i]=value;tables[tableName]=all
        }
        reconcileSelection()
    }
    private var idKey:String { ["LiquidParameters":"liquid_id","Curve":"curve_id","LiquidCompensation":"liquid_compensation_id","Consumables":"consumable_id"][tableName]! }
    private func append(_ value:JSONObject) {
        guard !model.manualControlsLocked else { return }
        var row=value;row[idKey]=(rows.map { $0.integer(idKey) }.max() ?? 0)+1
        model.updateTables { tables in
            var all=tables[tableName] as? [JSONObject] ?? []
            all.append(row);tables[tableName]=all;index=all.count-1
        }
    }
    private func duplicateRecord() {
        guard !selected.isEmpty else { return }
        if tableName=="Curve" {
            beginNewRecord(copying:selected)
            return
        }
        var row=selected
        if tableName=="Consumables" { row["Name"]=row.text("Name")+" 副本" }
        append(row)
    }
    private func beginNewRecord(copying source:JSONObject?=nil) {
        let contextModule=moduleFilter ?? moduleKey.map { selected.integer($0,20) } ?? 20
        // One presentation value carries the initial context. This avoids a sheet
        // reading an earlier snapshot of separately updated parent @State values.
        newRecordRequest=LibraryRecordCreationRequest(
            tableName:tableName,name:tableName=="Consumables" ? "新耗材" : "新液体",
            liquidID:selected.integer("liquid_id",liquids.first?.integer("liquid_id") ?? 0),
            module:[20,1000].contains(contextModule) ? contextModule : 20,copySource:source)
    }
    private func createRecord(request:LibraryRecordCreationRequest,name:String,liquidID:Int,module:Int) {
        guard !model.manualControlsLocked,tableName==request.tableName else { return }
        let trimmedName=name.trimmingCharacters(in:.whitespacesAndNewlines)
        let liquid=liquids.first { $0.integer("liquid_id")==liquidID && liquidID>0 }
        if moduleKey != nil {
            guard liquid != nil,[20,1000].contains(module) else { return }
            if tableName=="Curve",rows.contains(where:{ $0.integer("liquid_id")==liquidID && $0.integer("range")==module }) { return }
        } else if trimmedName.isEmpty { return }
        let seed:JSONObject
        switch tableName {
        case "LiquidParameters":seed=["liquid_type":trimmedName,"isSelect":false]
        case "Curve":
            var curve=request.copySource ?? ["model":"9210","parameter1":"0","parameter2":"0","type":0]
            curve["liquid_id"]=liquidID;curve["liquid_type"]=liquid?.text("liquid_type") ?? "";curve["range"]=module
            seed=curve
        case "LiquidCompensation":seed=["liquid_id":liquidID,"liquid_type":liquid?.text("liquid_type") ?? "","module":module,"trapping_type":0,"nature":0,"start_imbibing":"0","end_imbibing":"0","compensation":"0"]
        default:seed=["Name":trimmedName,"Code":"","Factory":"","Volume":"20","SupplyType":1,"HoleRow":"8","HoleColum":"12","HoleDiameter":"0","XSpacing":"9","YSpacing":"9","LengthNum":"127.76","WidthNum":"85.48","HeightNum":"0","DepthNum":"0","ChannelNum":"8","IsStright":"false"]
        }
        if moduleKey != nil,moduleFilter != nil { moduleFilter=module }
        append(seed);newRecordRequest=nil
    }
    private func deleteRecord() {
        guard !model.manualControlsLocked,let i=index,rows.indices.contains(i) else { return }
        let visible=visibleIndices
        let next=visible.first { $0>i } ?? visible.last { $0<i }
        model.updateTables { tables in
            var all=tables[tableName] as? [JSONObject] ?? []
            guard all.indices.contains(i) else { return }
            all.remove(at:i);tables[tableName]=all
            index=next.map { $0>i ? $0-1 : $0 }
        }
    }
}


private struct LibraryRecordCreationRequest:Identifiable {
    let id=UUID()
    let tableName:String
    let name:String
    let liquidID:Int
    let module:Int
    let copySource:JSONObject?
}

private struct LibraryRecordCreationSheet:View {
    @ObservedObject var model:AppModel
    let request:LibraryRecordCreationRequest
    let onCreate:(String,Int,Int)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var liquidID:Int
    @State private var module:Int
    init(model:AppModel,request:LibraryRecordCreationRequest,onCreate:@escaping (String,Int,Int)->Void) {
        self.model=model;self.request=request;self.onCreate=onCreate
        _name=State(initialValue:request.name)
        _liquidID=State(initialValue:request.liquidID)
        _module=State(initialValue:request.module)
    }
    private var title:String { ["LiquidParameters":"液体","Curve":"液体曲线","LiquidCompensation":"液体补偿","Consumables":"耗材库"][request.tableName] ?? "记录" }
    private var hasModule:Bool { ["Curve","LiquidCompensation"].contains(request.tableName) }
    private var liquids:[JSONObject] { model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? [] }
    private var rows:[JSONObject] { model.workspace.tables[request.tableName] as? [JSONObject] ?? [] }
    private var duplicateCurve:Bool { request.tableName=="Curve" && rows.contains { $0.integer("liquid_id")==liquidID && $0.integer("range")==module } }
    private var canCreate:Bool {
        if hasModule { return liquids.contains { $0.integer("liquid_id")==liquidID && liquidID>0 } && [20,1000].contains(module) && !duplicateCurve }
        return !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text(request.copySource == nil ? "新增"+title : "复制液体曲线").font(StudioTypography.paneTitle)
            if hasModule {
                VStack(alignment:.leading,spacing:14) {
                    Picker("液体",selection:$liquidID) {
                        if !liquids.contains(where:{ $0.integer("liquid_id")==liquidID }) { Text("请选择液体").tag(0) }
                        ForEach(Array(liquids.enumerated()),id:\.offset) { _,liquid in
                            Text(liquid.text("liquid_type","未命名液体")+" · ID \(liquid.integer("liquid_id"))").tag(liquid.integer("liquid_id"))
                        }
                    }
                    Picker("模块",selection:$module) { Text("20 µL").tag(20);Text("1000 µL").tag(1000) }
                }
                if liquids.isEmpty {
                    Text("请先在“液体”中新增液体，再为它配置曲线或补偿。")
                        .font(StudioTypography.metadata).foregroundStyle(.secondary)
                } else if duplicateCurve {
                    Text("此液体在 \(module) µL 模块已有曲线，请直接编辑已有记录。")
                        .font(StudioTypography.metadata).foregroundStyle(.secondary)
                } else {
                    Text(request.copySource != nil ? "将原曲线参数复制到所选液体和模块，创建后可继续调整。" : "创建后可继续填写\(request.tableName=="Curve" ? "曲线参数" : "体积区间和补偿量")。")
                        .font(StudioTypography.metadata).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing:16) {
                    Text(request.tableName=="Consumables" ? "耗材名称" : "液体名称")
                    TextField("名称",text:$name).studioInput(width:240)
                }.studioParameterRow()
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.copySource == nil ? "新增" : "复制") { onCreate(name,liquidID,module) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!canCreate || model.manualControlsLocked)
            }
        }.padding(28).frame(width:440).disabled(model.manualControlsLocked)
    }
}
