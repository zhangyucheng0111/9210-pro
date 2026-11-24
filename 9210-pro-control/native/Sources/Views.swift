import SwiftUI

struct MainView: View {
    @ObservedObject var model:AppModel
    @ObservedObject var bluetooth:BluetoothController
    @State private var tab=0
    init(model:AppModel) { self.model=model;self.bluetooth=model.bluetooth }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Text("9210 Pro").font(.system(size:20,weight:.semibold))
                Rectangle().fill(Style.line).frame(width:1,height:20)
                HStack(spacing:7) {
                    Circle().fill(bluetooth.ready ? Color.blue : Color.secondary.opacity(0.55)).frame(width:6,height:6)
                    Text(bluetooth.status).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("连接…") { model.showDevice=true }.disabled(model.isRunning || model.manualBusy || model.isStopping)
                Spacer(minLength:12)
                Picker("模式",selection:$model.mode) { Text("模拟").tag("simulation");Text("实机").tag("hardware") }
                    .pickerStyle(.segmented).labelsHidden().frame(width:132)
                    .disabled(model.isRunning || model.manualBusy || model.isStopping || bluetooth.busy)
                Button("复位") { model.resetDevice() }.disabled(!model.canReset)
                Button(role:.destructive) { model.stop() } label: { Label("停止",systemImage:"stop.fill") }
                    .disabled(model.isStopping || (!model.isRunning && !model.manualBusy && !bluetooth.ready))
            }.controlSize(.regular).padding(.horizontal,22).padding(.vertical,14)
            Divider()
            TabView(selection:$tab) {
                ProgramView(model:model).disabled((model.manualBusy || model.isStopping) && !model.isResetting && !model.isRunningSingleStep).tabItem { Text("程序 / 单步") }.tag(0)
                ManualControlView(model:model,bluetooth:bluetooth).tabItem { Text("手动操作") }.tag(5)
                PositionSettingsView(model:model,bluetooth:bluetooth).tabItem { Text("位置 / 底板") }.tag(1)
                SpeedSettingsView(model:model).disabled(model.manualBusy || model.isStopping).tabItem { Text("速度 / 设备参数") }.tag(2)
                LibrarySettingsView(model:model).disabled(model.manualBusy || model.isStopping).tabItem { Text("液体 / 耗材") }.tag(3)
                CommunicationView(model:model,bluetooth:bluetooth).tabItem { Text("通信记录") }.tag(4)
            }.padding(0)
            Divider()
            HStack {
                HStack(spacing:7) {
                    if model.manualBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName:model.isRunning ? "play.circle.fill" : "circle.inset.filled").foregroundStyle(model.isRunning ? Color.blue : Color.secondary) }
                    Text(model.manualBusy ? (model.manualStatus.isEmpty ? "手动操作中…" : model.manualStatus) : model.phase).fontWeight(.medium)
                }
                if model.isRunning { ProgressView(value:model.progress).frame(width:160);Text("\(max(0,model.currentIndex+1)) / \(model.runningStepCount)") }
                Spacer();Text(model.notice).foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size:11)).padding(.horizontal,18).padding(.vertical,9)
        }.frame(minWidth:1120,minHeight:700).preferredColorScheme(.light).groupBoxStyle(StudioGroupBoxStyle())
        .modifier(ResetCompletionOverlay(model:model))
        .sheet(isPresented:$model.showDevice) { DeviceSheet(model:model,bluetooth:bluetooth) }
        .sheet(isPresented:$model.showTemplate) { TemplateSheet(model:model) }
        .sheet(isPresented:$model.showNewProgram) { NewProgramSheet(model:model) }
        .sheet(isPresented:$model.showLoopEditor) { LoopEditorSheet(model:model) }
        .sheet(isPresented:$model.showLoop) { LoopSheet(model:model) }
        .sheet(isPresented:$model.showRaw) {
            JSONEditor(title:"步骤完整参数",initial:model.rawText,onSave:{ model.rawText=$0;model.applyRaw() },onCancel:{ model.showRaw=false })
        }
        .alert("操作未完成",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error=nil } })) { Button("知道了",role:.cancel) { model.error=nil } } message:{ Text(model.error ?? "") }
    }
}

private struct ResetCompletionOverlay:ViewModifier {
    @ObservedObject var model:AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content:Content)->some View {
        content.overlay(alignment:.top) {
            Group {
                if let id=model.resetCompletionID {
                    HStack(spacing:8) {
                        Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                        Text("复位完毕").foregroundStyle(Style.ink)
                    }
                    .font(.system(size:13,weight:.medium))
                    .padding(.horizontal,18).padding(.vertical,11)
                    .background(Style.surface,in:RoundedRectangle(cornerRadius:10))
                    .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Style.line,lineWidth:1))
                    .shadow(color:.black.opacity(0.12),radius:10,y:3)
                    .padding(.top,10).id(id).transition(.opacity)
                    .accessibilityElement(children:.combine)
                }
            }
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:model.resetCompletionID)
        }
    }
}

struct CommunicationView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var bluetooth:BluetoothController
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(bluetooth.linkDetails.isEmpty ? "连接后显示写入方式与分包上限" : bluetooth.linkDetails).foregroundStyle(.secondary);Spacer();Button("打开记录文件夹") { model.openRecords() };Button("清空显示") { model.console=[] } }
            Text(bluetooth.lastTransfer).font(StudioTypography.caption)
            List(model.console) { line in HStack(alignment:.top,spacing:10) { Text(line.time,style:.time).frame(width:72,alignment:.leading);Text(line.kind).frame(width:60,alignment:.leading);Text(line.message).textSelection(.enabled) }.font(.system(size:11,design:.monospaced)).padding(.vertical,4) }.listStyle(.inset)
            Text("通信原文自动写入 communication 文件夹；超时不会自动重发动作。").font(StudioTypography.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
struct JSONEditor:View {
    let title:String
    let initial:String
    let onSave:(String)->Void
    let onCancel:()->Void
    @State private var text=""
    var body:some View { VStack(alignment:.leading,spacing:12) { Text(title).font(.headline);TextEditor(text:$text).font(.system(size:12,design:.monospaced)).border(Style.line);HStack { Button("取消",action:onCancel);Spacer();Button("应用") { onSave(text) }.buttonStyle(.borderedProminent) } }.padding(20).frame(width:700,height:590).onAppear { text=initial } }
}
extension Dictionary where Key==String,Value==Any { var selfID: Int { integer("id") } }

struct DeviceSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothController
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:6) { Text("连接工作站").font(StudioTypography.pageTitle);Text("Mac 直接通过蓝牙连接。连接前在平板中断开工作站。").font(.system(size:12)).foregroundStyle(Style.muted) };Spacer();Button("完成") { model.showDevice=false } }
            HStack {
                Toggle("打开软件自动连接",isOn:Binding(get:{ bluetooth.autoConnectEnabled },set:{ bluetooth.setAutoConnectEnabled($0) })).toggleStyle(.checkbox).disabled(model.manualControlsLocked)
                Spacer()
                Text("默认：\(bluetooth.preferredDeviceName)").font(.callout)
                Button("连接默认设备") { bluetooth.connectDefaultDevice() }.disabled(bluetooth.ready || bluetooth.connecting || model.manualControlsLocked)
            }
            Text("更换设备后，成功连接的新设备会成为下次打开时的默认设备。").font(StudioTypography.caption).foregroundStyle(.secondary)
            HStack { Circle().fill(bluetooth.ready ? Style.blue : Style.muted).frame(width:7,height:7);Text(bluetooth.status).font(.system(size:12));Spacer();Button(bluetooth.scanning ? "扫描中…" : "查找设备") { bluetooth.scan() }.disabled(bluetooth.scanning || bluetooth.ready || bluetooth.connecting) }
            List(bluetooth.devices,selection:$selected) { d in HStack { VStack(alignment:.leading,spacing:4) { HStack { Text(d.name).font(.headline);if d.id==bluetooth.preferredDeviceID { Text("默认").font(StudioTypography.caption).foregroundStyle(.secondary) } };Text(d.id.uuidString).font(.system(size:10,design:.monospaced)).foregroundStyle(Style.muted) };Spacer();Text(d.rssi==0 ? "已记住" : "\(d.rssi) dBm").font(.system(size:11,design:.monospaced)) }.padding(.vertical,6).tag(d.id) }.frame(height:240).border(Style.line)
            HStack {
                Button(bluetooth.connecting ? "取消连接" : "断开连接") { bluetooth.disconnect() }.disabled(!bluetooth.ready && !bluetooth.connecting)
                Button("更换设备") { selected=nil;bluetooth.chooseAnotherDevice() }.disabled(model.manualControlsLocked)
                Spacer();Button(bluetooth.connecting ? "正在连接…" : "连接所选设备") { if let id=selected { bluetooth.connect(id) } }.buttonStyle(.borderedProminent).disabled(selected==nil || bluetooth.ready || bluetooth.connecting)
            }
            if let error=bluetooth.preferencesError { Text(error).font(StudioTypography.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("读取设备信息") { model.query(false) }.disabled(!bluetooth.ready || model.manualControlsLocked)
                Button("读取位置") { model.query(true) }.disabled(!bluetooth.ready || model.manualControlsLocked)
                Spacer()
                Button(model.mode=="simulation" ? "模拟复位" : "工作站复位") { model.resetDevice() }.disabled(!model.canReset)
            }
            if !bluetooth.positions.isEmpty { Text("位置步数  X \(bluetooth.positions[0])   Y \(bluetooth.positions[1])   Z \(bluetooth.positions[2])   柱塞 \(bluetooth.positions[3])").font(.system(size:11,design:.monospaced)).textSelection(.enabled) }
            Text(bluetooth.linkDetails).font(StudioTypography.caption).foregroundStyle(.secondary)
            HStack {
                Picker("写入方式（重新连接生效）",selection:$bluetooth.writePreference) { Text("自动 · 与安卓一致").tag("auto");Text("有响应").tag("response");Text("无响应").tag("noResponse") }
                Picker("分包上限",selection:$bluetooth.packetLimit) { Text("197 字节").tag(197);Text("20 字节（兼容）").tag(20) }
            }.disabled(bluetooth.ready || bluetooth.busy || bluetooth.connecting)
        }.padding(26).frame(width:700)
        .modifier(ResetCompletionOverlay(model:model))
        .onAppear { selectPreferredDevice() }
        .onChange(of:bluetooth.devices.map(\.id)) { selectPreferredDevice() }
        .onChange(of:bluetooth.scanning) { if bluetooth.scanning { selected=nil } else { selectPreferredDevice() } }
    }
    private func selectPreferredDevice() {
        guard !bluetooth.scanning else { return }
        if let selected=selected,bluetooth.devices.contains(where:{ $0.id==selected }) { return }
        selected=bluetooth.connectionPreferences.candidate(in:bluetooth.devices.map { BluetoothCandidate(id:$0.id,name:$0.name) })
    }
}
struct TemplateSheet: View {
    @ObservedObject var model: AppModel
    @State private var kind="split"
    @State private var columns=4
    @State private var volume="13"
    private var templateRange:Int {
        let name=kind == "split" ? (columns == 2 ? "RT-split-4" : "lig-split-13") : (columns == 2 ? "RT-pool-15" : "lig-pool-14")
        return model.workspace.programs.first { $0.raw.text("name")==name && $0.origin=="平板导出" }?.range ?? 20
    }
    private var volumeRule:NumericRule { .decimal(min:Double.leastNonzeroMagnitude,max:Double(templateRange)) }
    private var parsedVolume:Double? {
        guard let value=volumeRule.value(volume),value>0 else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            Text("新建 Split / Pool").font(StudioTypography.pageTitle)
            Text("沿用已有方案的台面、取头顺序、混匀和辅助段，单独生成一份 Mac 方案。").font(.system(size:12)).foregroundStyle(Style.muted)
            Picker("方向",selection:$kind) { Text("Split · PCR → 96 孔板").tag("split");Text("Pool · 96 孔板 → PCR").tag("pool") }.pickerStyle(.segmented)
            Picker("列数",selection:$columns) { Text("两列 · 6 轮").tag(2);Text("四列 · 3 轮").tag(4) }.pickerStyle(.segmented)
            HStack { Text("每孔转移量");ValidatedNumericField("µL",text:$volume,rule:volumeRule).frame(width:100).accessibilityLabel("每孔转移量");Text("µL");Spacer(minLength:0) }.studioParameterRow()
            if let amount=parsedVolume {
                Text(kind=="pool" ? "每个 PCR 管增加 \(formatNumber(amount*Double(12/columns))) µL，另计初始量和辅助段。" : "每个源孔累计转出 \(formatNumber(amount*Double(12/columns))) µL，另计损耗和源液余量。").font(.system(size:12)).foregroundStyle(Style.blue)
            } else {
                Text("每孔转移量应大于 0 且不超过 \(templateRange) µL，可输入小数。").font(.system(size:12)).foregroundStyle(.red)
            }
            HStack { Button("取消") { model.showTemplate=false };Spacer();Button("创建方案") { if let amount=parsedVolume { model.createTemplate(kind:kind,columns:columns,volume:amount) } }.buttonStyle(.borderedProminent).disabled(parsedVolume==nil) }
        }.padding(28).frame(width:570)
    }
}
struct LoopSheet: View {
    @ObservedObject var model: AppModel
    @State private var from="1"
    @State private var to="5"
    @State private var count="3"
    private var stepRule:NumericRule { .integer(min:1,max:model.program?.steps.count ?? 0) }
    private var parameters:(from:Int,to:Int,count:Int)? {
        guard let program=model.program,
              let first=stepRule.intValue(from),let last=stepRule.intValue(to),first<=last,
              let repeats=NumericRule.integer(min:1,max:1000).intValue(count),
              last-first+1 <= 10000/repeats,
              !program.steps[(first-1)..<last].contains(where:{ $0.event==8 }) else { return nil }
        return (first,last,repeats)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) { Text("创建循环").font(StudioTypography.pageTitle);Text("把一段连续步骤收进循环，运行前展开为独立动作。").foregroundStyle(Style.muted)
            HStack { Text("从第");ValidatedNumericField("起点",text:$from,rule:stepRule).frame(width:55).accessibilityLabel("循环起始步骤");Text("步到第");ValidatedNumericField("终点",text:$to,rule:stepRule).frame(width:55).accessibilityLabel("循环结束步骤");Text("步");Spacer(minLength:0) }.studioParameterRow()
            HStack { Text("执行次数");ValidatedNumericField("次数",text:$count,rule:.integer(min:1,max:1000)).frame(width:80).accessibilityLabel("循环执行次数");Spacer(minLength:0) }.studioParameterRow()
            HStack { Button("取消") { model.showLoop=false };Spacer();Button("创建循环") { if let values=parameters { model.createLoop(from:values.from,to:values.to,count:values.count) } }.buttonStyle(.borderedProminent).disabled(parameters==nil) }
        }.padding(28).frame(width:510)
        .onAppear { let index=model.program?.steps.firstIndex { $0.id == model.selectedStep } ?? 0;let first=index+1;from=String(first);to=String(min(first+1,model.program?.steps.count ?? first)) }
    }
}
