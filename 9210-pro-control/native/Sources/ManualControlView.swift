import SwiftUI

private enum ManualFunction:String,CaseIterable,Identifiable {
    case load="插枪头"
    case unload="卸枪头"
    case aspirate="吸液"
    case dispense="放液"
    case mix="混匀"
    case segmented="分段下降吸液"
    case reset="复位"
    var id:String { rawValue }
    var symbol:String {
        switch self {
        case .load: return "arrow.down.to.line"
        case .unload: return "arrow.up.from.line"
        case .aspirate: return "arrow.up"
        case .dispense: return "arrow.down"
        case .mix: return "arrow.up.arrow.down"
        case .segmented: return "arrow.down.forward"
        case .reset: return "arrow.counterclockwise"
        }
    }
    var liquidEvent:Int? {
        switch self {
        case .aspirate: return 3
        case .dispense: return 4
        case .mix: return 5
        default: return nil
        }
    }
}

struct ManualControlView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var bluetooth:BluetoothController
    @State private var showSpeeds=false
    @State private var selectedFunction:ManualFunction? = .load
    var settings:ManualControlSettings { model.manualControls }
    var tables:[JSONObject] { model.manualControlTables }
    var plates:[JSONObject] { model.workspace.worktable(settings.tableID).array("WorkTablets") }

    var body:some View {
        HSplitView {
            VStack(alignment:.leading,spacing:0) {
                Text("手动操作").font(StudioTypography.paneTitle).padding(.horizontal,16).padding(.vertical,20)
                Divider()
                List(selection:$selectedFunction) {
                    Section {
                        functionRow(.load)
                        functionRow(.unload)
                    } header: { functionHeader("枪头操作") }
                    Section {
                        functionRow(.aspirate)
                        functionRow(.dispense)
                        functionRow(.mix)
                        functionRow(.segmented)
                    } header: { functionHeader("移液操作") }
                    Section {
                        functionRow(.reset)
                    } header: { functionHeader("设备") }
                }.listStyle(.inset).disabled(model.manualControlsLocked)
            }.frame(minWidth:180,idealWidth:210,maxWidth:260)
            VStack(spacing:0) {
              ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack(alignment:.firstTextBaseline,spacing:16) {
                        Text((selectedFunction ?? .load).rawValue).font(StudioTypography.pageTitle)
                        Spacer(minLength:12)
                        ContextSaveControls(model:model,title:"保存手动设置")
                            .help("保存台面、装卸头、吸排液、混匀与分段吸液设置及通用速度。")
                    }
                    HStack(spacing:12) {
                        HStack(spacing:10) {
                            Text("台面配置")
                            Picker("台面配置",selection:Binding(get:{ settings.tableID },set:{ model.setManualTable($0) })) {
                                if !tables.contains(where:{ $0.integer("id")==settings.tableID }) { Text("请选择台面").tag(settings.tableID) }
                                ForEach(tables,id:\.selfID) { table in
                                    Text(table.text("NickName","台面 \(table.integer("id"))")).tag(table.integer("id"))
                                }
                            }
                            .labelsHidden().frame(minWidth:140,maxWidth:300)
                            Text((try? model.workspace.resolvedTableHeadRange(settings.tableID)).map { "\($0) µL" } ?? "未指定移液头").font(StudioTypography.metadata).foregroundStyle(.secondary)
                        }
                        Button("通用速度…") { showSpeeds=true }
                        Spacer(minLength:0)
                        Text(model.mode=="simulation" ? "模拟操作" : "实机操作").foregroundStyle(.secondary)
                    }.disabled(model.manualControlsLocked)
                    Divider()
                    VStack(alignment:.leading,spacing:0) {
                      switch selectedFunction ?? .load {
                    case .load:
                        tipSection(event:1,title:"插枪头")
                    case .unload:
                        tipSection(event:2,title:"卸枪头")
                    case .aspirate,.dispense,.mix:
                        if let event=selectedFunction?.liquidEvent {
                            ManualLiquidOperationView(model:model,event:event).id(event)
                        }
                    case .segmented:
                        EmptyView()
                    case .reset:
                        Text(model.mode=="simulation" ? "模拟位置归零。" : "工作站复位后自动读取并核对零点。")
                            .font(StudioTypography.body).foregroundStyle(.secondary)
                      }
                      SegmentedAspirationView(model:model,bluetooth:bluetooth,visible:selectedFunction == .segmented)
                    }
                    if !model.manualStatus.isEmpty { Text(model.manualStatus).font(.callout).textSelection(.enabled) }
                    if let fault=model.manualFault,model.mode=="hardware" { Text(fault).font(.callout).foregroundStyle(.red) }
                    if model.mode=="hardware",!bluetooth.ready { Text("连接工作站后可执行实机操作。").font(StudioTypography.caption).foregroundStyle(.secondary) }
                }
                .font(StudioTypography.body).padding(24).frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
              }
              if selectedFunction != .segmented {
                  Divider()
                  fixedExecutionBar
              }
            }.frame(minWidth:640)
        }
        .groupBoxStyle(StudioGroupBoxStyle())
        .sheet(isPresented:$showSpeeds) { ManualSpeedsSheet(model:model) }
    }

    private func functionHeader(_ title:String)->some View {
        Text(title).font(StudioTypography.section).foregroundStyle(Style.ink)
            .padding(.top,10).padding(.bottom,5)
    }

    private func functionRow(_ function:ManualFunction)->some View {
        HStack(spacing:10) {
            Image(systemName:function.symbol).frame(width:16).accessibilityHidden(true)
            Text(function.rawValue)
        }
        .font(StudioTypography.row)
        .frame(maxWidth:.infinity,minHeight:36,alignment:.leading)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Style.line)
        .tag(function)
    }

    private func tipSection(event:Int,title:String)->some View {
        let number=event==1 ? settings.loadPlate : settings.unloadPlate
        let plate=plates.first { $0.integer("Number")==number } ?? [:]
        let preview=commandPreview(event:event)
        return VStack(alignment:.leading,spacing:20) {
                Text("选择板位、排数和起始孔位；点击孔位会选中右方及下方区域，设置自动保存。")
                    .font(StudioTypography.caption).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:12) {
                    Text("板位与孔位").font(.system(size:13,weight:.semibold))
                    HStack(spacing:12) {
                        Picker("板位",selection:Binding(get:{ event==1 ? settings.loadPlate : settings.unloadPlate },set:{ model.setManualPlate(event:event,number:$0) })) {
                            if !plates.contains(where:{ $0.integer("Number")==number }) { Text("请选择板位").tag(number) }
                            ForEach(plates,id:\.plateID) { p in
                                Text("T\(p.integer("Number")) · \(p.object("Material").text("Name","未设置耗材"))").tag(p.integer("Number"))
                            }
                        }.frame(maxWidth:440,alignment:.leading)
                    }.disabled(model.manualControlsLocked)
                    if !plate.object("Material").isEmpty {
                        positionSelector(event:event,material:plate.object("Material")).disabled(model.manualControlsLocked)
                    }
                }
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    Text("定位与速度").font(.system(size:13,weight:.semibold))
                    VStack(alignment:.leading,spacing:8) {
                        switch preview {
                        case .success(let command):
                            if command.positionMM.count>=3 {
                                Text("目标 X \(formatNumber(command.positionMM[0]))   Y \(formatNumber(command.positionMM[1]))   Z \(formatNumber(command.positionMM[2])) mm")
                                    .font(StudioTypography.metadata).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        case .failure(let error):
                            Text(error.localizedDescription).font(StudioTypography.caption).foregroundStyle(.red)
                        }
                        Text(event==1 ? "使用手动通用速度中的 X／Y／Z 和装头第二段参数。" : "使用手动通用速度中的 X／Y／Z 和卸头参数。退头速度已编码，机械响应取决于固件。")
                            .font(StudioTypography.caption).foregroundStyle(.secondary)
                    }
                }
        }.frame(maxWidth:.infinity,alignment:.topLeading)
    }

    private var fixedExecutionBar:some View {
        HStack(spacing:16) {
            Text("执行").font(.system(size:13,weight:.semibold))
            Spacer(minLength:12)
            Button(model.isStopping ? "正在停止…" : "停止",role:.destructive) { model.stop() }
                .disabled(!model.manualBusy || model.isStopping)
            switch selectedFunction ?? .load {
            case .load,.unload:
                let event=selectedFunction == .unload ? 2 : 1
                let title=event==1 ? "插枪头" : "卸枪头"
                Button("\(model.mode=="simulation" ? "模拟" : "执行")\(title)") { model.executeManualTip(event) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canExecute(preview:commandPreview(event:event)))
            case .aspirate,.dispense,.mix:
                let function=selectedFunction ?? .aspirate
                let event=function.liquidEvent ?? 3
                Button("\(model.mode=="simulation" ? "模拟" : "执行")\(function.rawValue)") { model.executeManualLiquid(event) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canExecute(preview:model.manualLiquidPreview(event)))
            case .reset:
                Button(model.mode=="simulation" ? "模拟复位" : "执行复位") { model.resetDevice() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canReset)
            case .segmented:
                EmptyView()
            }
        }
        .padding(.horizontal,24).padding(.vertical,16)
        .frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
        .background(Style.surface)
    }

    private func commandPreview(event:Int)->Result<CompiledStep,Error> {
        Result { try model.compiler.compileManualTip(event:event,settings:settings) }
    }

    private func canExecute(preview:Result<CompiledStep,Error>)->Bool {
        guard !model.manualControlsLocked,case .success=preview else { return false }
        return model.mode != "hardware" || (bluetooth.ready && !bluetooth.uncertain && model.manualFault==nil)
    }

    private func positionSelector(event:Int,material:JSONObject)->some View {
        let rows=max(1,min(material.integer("HoleRow",1),48))
        let columns=max(1,min(material.integer("HoleColum",1),48))
        let row=event==1 ? settings.loadRow : settings.unloadRow
        let column=event==1 ? settings.loadColumn : settings.unloadColumn
        let valid=(0..<rows).contains(row) && (0..<columns).contains(column)
        let selectedRow=(0..<rows).contains(row) ? row : 0
        let selectedColumn=(0..<columns).contains(column) ? column : 0
        let count=(0..<columns).contains(column) ? columns-column : 0
        return VStack(alignment:.leading,spacing:12) {
            if rows>1 || columns>1 {
                HStack(alignment:.top,spacing:12) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("排数（列）").font(StudioTypography.metadata).foregroundStyle(.secondary)
                        Picker("排数（列）",selection:Binding(get:{ count },set:{ model.setManualPosition(event:event,row:selectedRow,column:columns-$0) })) {
                            if count==0 { Text("重新选择").tag(0) }
                            ForEach(1...columns,id:\.self) { Text("\($0) 排").tag($0) }
                        }.labelsHidden().frame(width:120)
                    }.frame(width:132,alignment:.leading)
                    VStack(alignment:.leading,spacing:8) {
                        Text("起始行").font(StudioTypography.metadata).foregroundStyle(.secondary)
                        Picker("起始行",selection:Binding(get:{ row },set:{ model.setManualPosition(event:event,row:$0,column:selectedColumn) })) {
                            if !(0..<rows).contains(row) { Text("重新选择").tag(row) }
                            ForEach(0..<rows,id:\.self) { Text(WellAddress.rowLabel($0)).tag($0) }
                        }.labelsHidden().frame(width:100)
                    }.frame(width:112,alignment:.leading)
                    VStack(alignment:.leading,spacing:8) {
                        Text("起始列").font(StudioTypography.metadata).foregroundStyle(.secondary)
                        Picker("起始列",selection:Binding(get:{ column },set:{ model.setManualPosition(event:event,row:selectedRow,column:$0) })) {
                            if !(0..<columns).contains(column) { Text("重新选择").tag(column) }
                            ForEach(0..<columns,id:\.self) { Text(String($0+1)).tag($0) }
                        }.labelsHidden().frame(width:100)
                    }.frame(width:112,alignment:.leading)
                    Spacer(minLength:0)
                }
                ScrollView(.horizontal) {
                    WellGrid(rows:rows,columns:columns,row:row,column:column,cellSize:24,select:{ r,c in model.setManualPosition(event:event,row:r,column:c) })
                }.frame(height:28+Double(rows)*28)
                if valid {
                    Text("起点 \(WellAddress.label(row:row,column:column)) → \(WellAddress.label(row:rows-1,column:columns-1)) · \(count) 排 · \((rows-row)*count) 孔")
                        .font(StudioTypography.caption).monospacedDigit()
                } else {
                    Text("当前孔位超出所选耗材，请重新选择。").font(StudioTypography.caption).foregroundStyle(.red)
                }
            } else {
                HStack {
                    Text("孔位 A1 · 1 排").font(StudioTypography.caption).monospacedDigit()
                    if !valid { Button("恢复 A1") { model.setManualPosition(event:event,row:0,column:0) } }
                }
            }
        }
    }
}
