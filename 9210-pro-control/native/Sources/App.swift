import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let model=model else { return .terminateNow }
        if !model.isRunning && !model.manualBusy && !model.isStopping { do { try model.flush();return .terminateNow } catch { let alert=NSAlert();alert.messageText="保存失败";alert.informativeText=error.localizedDescription;alert.runModal();return .terminateCancel } }
        let alert=NSAlert();alert.messageText="工作站操作仍在进行";alert.informativeText="先停止操作，再退出。";alert.addButton(withTitle:"返回操作");alert.addButton(withTitle:"停止操作")
        if alert.runModal() == .alertSecondButtonReturn { model.stop() }
        return .terminateCancel
    }
}
@main struct PipetterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model=AppModel()
    var body: some Scene {
        WindowGroup("9210 Pro · 移液工作站") { MainView(model:model).onAppear { delegate.model=model;model.startBluetoothOnLaunch();NSApp.activate(ignoringOtherApps:true) } }
            .defaultSize(width:1380,height:880)
            .commands {
                CommandGroup(replacing:.newItem) { Button("新建程序…") { model.showNewProgram=true }.keyboardShortcut("n").disabled(model.programEditingLocked);Button("从 Split / Pool 示例创建…") { model.showTemplate=true }.disabled(model.programEditingLocked);Button("导入工作区…") { model.importData() }.keyboardShortcut("o").disabled(model.manualControlsLocked);Button("保存到 Mac") { model.save() }.keyboardShortcut("s");Button("导出工作区…") { model.exportData() }.keyboardShortcut("e") }
                CommandGroup(replacing:.undoRedo) { Button("撤销程序修改") { model.undoEdit() }.keyboardShortcut("z").disabled(!model.canUndo);Button("重做程序修改") { model.redoEdit() }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!model.canRedo) }
                CommandMenu("工作站") { Button("连接设备…") { model.showDevice=true }.disabled(model.manualControlsLocked);Button("模拟／运行方案") { model.start() }.disabled(model.manualControlsLocked);Button("暂停／继续") { model.togglePause() }.disabled(!model.isRunning || model.isRunningSingleStep || model.isStopping);Button("停止") { model.stop() }.disabled(model.isStopping || (!model.isRunning && !model.manualBusy && !model.bluetooth.ready)) }
            }
    }
}
