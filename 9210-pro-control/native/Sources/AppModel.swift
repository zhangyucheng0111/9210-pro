import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let kind: String
    let message: String
}
@MainActor final class AppModel: ObservableObject {
    @Published var workspace: Workspace
    @Published private(set) var workspaceIdentity=UUID()
    @Published var selection: String?
    @Published var selectedStep: String?
    @Published var selectedSteps:Set<String> = []
    @Published var compiled: [CompiledStep] = []
    @Published var compileError: String?
    @Published var error: String?
    @Published var mode = "simulation"
    @Published var isRunning = false { didSet { if isRunning { dismissResetCompletion() } } }
    @Published private(set) var isRunningSingleStep=false
    @Published private(set) var isResetting=false
    @Published private var runningCompiled:[CompiledStep]=[]
    @Published private(set) var manualBusy=false { didSet { if manualBusy { dismissResetCompletion() } } }
    @Published private(set) var isStopping=false { didSet { if isStopping { dismissResetCompletion() } } }
    @Published private(set) var resetCompletionID:UUID?
    @Published private(set) var manualStatus=""
    @Published private(set) var manualFault:String?
    @Published private(set) var simulatedPositions:[Int32]=[0,0,0,0]
    @Published var paused = false
    @Published var phase = "准备就绪"
    @Published var currentIndex = -1
    @Published var progress = 0.0
    @Published var console: [ConsoleEntry] = []
    @Published var showDevice = false
    @Published var showTemplate = false
    @Published var showNewProgram = false
    @Published var showLoop = false
    @Published var showLoopEditor = false
    @Published var showRaw = false
    @Published var rawText = ""
    @Published var notice = ""
    @Published private(set) var saveStatus = "自动保存已开启"
    @Published private var undoHistory: [Program] = []
    @Published private var redoHistory: [Program] = []
    let bluetooth = BluetoothController()
    let schema: CommandSchema
    let dataDirectory: URL
    private let writer=FileWriter()
    private var saveTask:Task<Void,Never>?
    private var saveRevision=0
    private let communicationSession=UUID().uuidString
    private var logWriteErrorReported=false
    private var task: Task<Void,Never>?
    private var manualTask:Task<Void,Never>?
    private var resetCompletionTask:Task<Void,Never>?
    private var manualUsesHardware=false
    private var run: JSONObject?
    private var runFile: URL?
    var program: Program? { workspace.programs.first { $0.id == selection } }
    var step: Step? { program?.steps.first { $0.id == selectedStep } }
    var chosenStepIDs:Set<String> {
        let valid=Set(program?.steps.map(\.id) ?? [])
        if let lead=selectedStep,!selectedSteps.contains(lead),valid.contains(lead) { return [lead] }
        return selectedSteps.intersection(valid)
    }
    var activeCompiled: CompiledStep? {
        let steps=isRunning ? runningCompiled : compiled
        return steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }
    var runningStepCount:Int { isRunning ? runningCompiled.count : compiled.count }
    var compiler: Compiler { Compiler(workspace:workspace,schema:schema) }
    var manualControls:ManualControlSettings { workspace.manualControls ?? ManualControlSettings.defaults(workspace:workspace) }
    var manualMotionSpeeds:[String:ProgramSpeed] {
        var settings=manualControls;settings.seedMotionSpeeds(workspace:workspace)
        return settings.motionSpeeds
    }
    var manualControlTables:[JSONObject] { (workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 } }
    var manualControlsLocked:Bool { isRunning || manualBusy || isStopping || bluetooth.busy }
    // Execution stays exclusive; reset and one selected step permit program edits.
    var programEditingLocked:Bool { manualControlsLocked && !isRunningSingleStep && !isResetting }
    var canReset:Bool { !manualControlsLocked && (mode=="simulation" || bluetooth.ready) }
    var plateList: [JSONObject] { program.map { workspace.worktable($0.worktableID).array("WorkTablets") } ?? [] }
    var canUndo: Bool { !programEditingLocked && !undoHistory.isEmpty }
    var canRedo: Bool { !programEditingLocked && !redoHistory.isEmpty }
    var selectedRaw: JSONObject {
        get { step?.raw ?? [:] }
        set { guard let id=selectedStep else { return };mutate { p in if let i=p.steps.firstIndex(where:{ $0.id == id }) { p.steps[i].raw=newValue;p.orderConfirmed=false } } }
    }

    init() {
        let resources = Bundle.main.resourceURL!
        schema = try! CommandSchema(url:resources.appendingPathComponent("command_schema.json"))
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--workspace"),args.indices.contains(i+1) { dataDirectory=URL(fileURLWithPath:args[i+1],isDirectory:true) }
        else { dataDirectory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("9210 Pro Control",isDirectory:true) }
        let seeds = try! Workspace.load(directory:resources.appendingPathComponent("dataJson"))
        workspace=seeds
        var restoredSelection: String?
        var loaded=false
        let file=dataDirectory.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do {
                guard let d=try jsonObject(Data(contentsOf:file)) as? JSONObject else { throw ControlError.invalid("保存的工作区格式错误") }
                workspace=try Workspace.restore(d);loaded=true
                restoredSelection=d["selection"] as? String
            } catch { self.error="本地工作区读取失败，已展示初始方案；原保存文件保留。\n\(error.localizedDescription)" }
        }
        if let id=restoredSelection,workspace.programs.contains(where:{ $0.id == id }) { selection=id }
        else if loaded { selection=workspace.programs.first?.id }
        else if let p=workspace.programs.first(where:{ $0.origin == "Mac 自由程序" }) { selection=p.id }
        else { let p=Program.blank();workspace.programs.append(p);selection=p.id }
        workspace.seedProgramSpeeds()
        if workspace.manualControls==nil { workspace.manualControls=ManualControlSettings.defaults(workspace:workspace) }
        workspace.seedManualSpeeds()
        selectStep(program?.steps.first?.id)
        bluetooth.onLog={ [weak self] kind,message in self?.log(kind,message) }
        bluetooth.onReady={ [weak self] in guard let self=self,!self.isRunning,!self.manualBusy,!self.isStopping else { return };self.mode="hardware" }
        bluetooth.configurePreferences(at:dataDirectory.appendingPathComponent("bluetooth.json"))
    }
    func startBluetoothOnLaunch() {
        // Isolated test/UI workspaces never acquire a workstation implicitly.
        guard !CommandLine.arguments.contains("--workspace"),!CommandLine.arguments.contains("--no-auto-connect") else { return }
        bluetooth.startAutomaticConnection()
    }
    func log(_ kind:String,_ message:String) {
        console.append(ConsoleEntry(kind:kind,message:message));if console.count>500 { console.removeFirst(console.count-500) }
        writer.append(["at":ISO8601DateFormatter().string(from:Date()),"kind":kind,"message":message],to:dataDirectory.appendingPathComponent("communication/"+communicationSession+".jsonl")) { [weak self] error in
            Task { @MainActor in guard let self=self,!self.logWriteErrorReported else { return };self.logWriteErrorReported=true;self.error="通信记录保存失败："+error.localizedDescription }
        }
    }
    func compileSelected() {
        guard !manualControlsLocked,let p=program else { return }
        do { compiled=p.steps.isEmpty ? [] : try compiler.compile(p);compileError=nil }
        catch { compiled=[];compileError=error.localizedDescription }
        currentIndex = -1;progress=0
    }
    func select(_ id: String) { guard !programEditingLocked else { return };selection=id;selectStep(program?.steps.first?.id);undoHistory=[];redoHistory=[];invalidateCompilation();scheduleSave() }
    private var savedWorkspace:JSONObject { var value=workspace.saved;value["selection"]=selection ?? "";return value }
    func selectStep(_ id:String?) { guard !programEditingLocked else { return };selectedStep=id;selectedSteps=id.map { [$0] } ?? [] }
    func selectSteps(_ ids:Set<String>) {
        guard !programEditingLocked else { return }
        let valid=ids.intersection(Set(program?.steps.map(\.id) ?? []))
        let added=valid.subtracting(selectedSteps)
        selectedSteps=valid
        if let latest=program?.steps.last(where:{ added.contains($0.id) }) { selectedStep=latest.id }
        else if !valid.contains(selectedStep ?? "") { selectedStep=program?.steps.first(where:{ valid.contains($0.id) })?.id }
    }
    private func invalidateCompilation() {
        compiled=[];compileError=nil
        if !isRunning { currentIndex = -1;progress=0 }
    }
    func scheduleSave() {
        saveRevision += 1;saveStatus="等待自动保存"
        saveTask?.cancel();saveTask=Task { do { try await Task.sleep(nanoseconds:450_000_000) } catch { return };self.save() }
    }
    func save() {
        saveTask?.cancel();saveTask=nil
        saveRevision += 1;let revision=saveRevision;saveStatus="正在保存…"
        writer.write(savedWorkspace,to:dataDirectory.appendingPathComponent("workspace.json")) { [weak self] error in
            Task { @MainActor in
                guard let self=self else { return }
                if let error=error { self.error="保存失败："+error.localizedDescription }
                guard self.saveRevision==revision else { return }
                self.saveStatus=error == nil ? "已保存 · 自动保存开启" : "保存失败"
                if error == nil { self.notice="已保存到 Mac" }
            }
        }
    }
    func flush() throws { saveTask?.cancel();saveTask=nil;try writer.writeAndWait(savedWorkspace,to:dataDirectory.appendingPathComponent("workspace.json")) }
    // These edits only receive the tables dictionary: they cannot rewrite programs
    // and therefore need neither program fingerprints nor undo-history invalidation.
    func updateTables(_ change:(inout JSONObject)->Void) {
        guard !manualControlsLocked else { return }
        change(&workspace.tables);invalidateCompilation();scheduleSave()
    }
    func updateSettings(_ change:(inout Workspace)->Void) {
        guard !manualControlsLocked else { return }
        let before=try? fingerprint(workspace.programs.map(\.saved)+workspace.deletedPrograms.map(\.saved))
        change(&workspace)
        if before != (try? fingerprint(workspace.programs.map(\.saved)+workspace.deletedPrograms.map(\.saved))) { undoHistory=[];redoHistory=[] }
        invalidateCompilation();scheduleSave()
    }
    func setManualTable(_ id:Int) {
        guard !manualControlsLocked else { return }
        guard manualControlTables.contains(where:{ $0.integer("id")==id }) else { error="请选择有效的 9210 台面";return }
        guard manualControls.tableID != id else { return }
        var settings=ManualControlSettings.defaults(workspace:workspace,tableID:id)
        settings.loadGear=manualControls.loadGear;settings.unloadGear=manualControls.unloadGear
        settings.motionSpeeds=manualMotionSpeeds
        settings.liquidSteps=manualControls.liquidSteps
        workspace.manualControls=settings;scheduleSave()
    }
    func manualLiquidRaw(_ event:Int)->JSONObject {
        manualControls.liquidRaw(event:event,workspace:workspace)
    }
    func setManualLiquidRaw(_ event:Int,raw:JSONObject) {
        guard !manualControlsLocked,[3,4,5].contains(event) else { return }
        var settings=manualControls
        let key="\(settings.tableID):\(event)",draft=ManualLiquidDraft(raw:raw)
        guard settings.liquidSteps[key] != draft else { return }
        settings.liquidSteps[key]=draft;workspace.manualControls=settings;scheduleSave()
    }
    func manualLiquidPreview(_ event:Int)->Result<CompiledStep,Error> {
        Result { try compiler.compileManualLiquid(event:event,raw:manualLiquidRaw(event),settings:manualControls) }
    }
    func setManualSegmentedPosition(number:Int,row:Int=0,column:Int=0) {
        guard !manualControlsLocked else { return }
        let plates=workspace.worktable(manualControls.tableID).array("WorkTablets")
        guard let plate=plates.first(where:{ $0.integer("Number")==number }) else { error="请选择有效的分段吸液板位";return }
        let material=plate.object("Material")
        do {
            let rows=try compiler.whole(material,"HoleRow",within:1...48),columns=try compiler.whole(material,"HoleColum",within:1...48)
            guard (0..<rows).contains(row),(0..<columns).contains(column) else { throw ControlError.invalid("分段吸液起始孔位超出所选板位") }
            var settings=manualControls
            settings.segmentedPlate=number;settings.segmentedRow=row;settings.segmentedColumn=column
            guard settings != manualControls else { return }
            workspace.manualControls=settings;scheduleSave()
        } catch { self.error=error.localizedDescription }
    }
    func setProgramTable(_ id:Int) {
        guard !programEditingLocked,var next=program else { return }
        do {
            try next.selectTable(id,workspace:workspace)
            mutate { $0=next }
        } catch { self.error=error.localizedDescription }
    }
    func setManualPlate(event:Int,number:Int) {
        guard !manualControlsLocked else { return }
        guard [1,2].contains(event),workspace.worktable(manualControls.tableID).array("WorkTablets").contains(where:{ $0.integer("Number")==number }) else { error="请选择有效板位";return }
        var settings=manualControls
        if event==1 {
            guard settings.loadPlate != number else { return }
            settings.loadPlate=number;settings.loadRow=0;settings.loadColumn=0
        } else {
            guard settings.unloadPlate != number else { return }
            settings.unloadPlate=number;settings.unloadRow=0;settings.unloadColumn=0
        }
        workspace.manualControls=settings;scheduleSave()
    }
    func setManualPosition(event:Int,row:Int,column:Int) {
        guard !manualControlsLocked else { return }
        guard [1,2].contains(event) else { error="不支持此手动动作";return }
        let settings=manualControls,number=event==1 ? settings.loadPlate : settings.unloadPlate
        let material=workspace.worktable(settings.tableID).array("WorkTablets").first { $0.integer("Number")==number }?.object("Material") ?? [:]
        do {
            let rows=try compiler.whole(material,"HoleRow",within:1...48),columns=try compiler.whole(material,"HoleColum",within:1...48)
            guard (0..<rows).contains(row),(0..<columns).contains(column) else { throw ControlError.invalid("起始孔位超出所选板位") }
            var next=settings
            if event==1 { next.loadRow=row;next.loadColumn=column }
            else { next.unloadRow=row;next.unloadColumn=column }
            guard next != settings else { return }
            workspace.manualControls=next;scheduleSave()
        } catch { self.error=error.localizedDescription }
    }
    func setManualColumnCount(event:Int,count:Int) {
        guard !manualControlsLocked else { return }
        guard [1,2].contains(event) else { error="不支持此手动动作";return }
        let settings=manualControls,number=event==1 ? settings.loadPlate : settings.unloadPlate
        let material=workspace.worktable(settings.tableID).array("WorkTablets").first { $0.integer("Number")==number }?.object("Material") ?? [:]
        do {
            let columns=try compiler.whole(material,"HoleColum",within:1...48)
            guard (1...columns).contains(count) else { throw ControlError.invalid("排数应为 1–\(columns)") }
            setManualPosition(event:event,row:event==1 ? settings.loadRow : settings.unloadRow,column:columns-count)
        } catch { self.error=error.localizedDescription }
    }
    func setManualGear(event:Int,gear:Int) {
        guard !manualControlsLocked else { return }
        guard [1,2].contains(event) else { error="不支持此手动动作";return }
        do {
            let types=event==1 ? ["XSpeed","YSpeed","ZSpeed","LoadSecondSpeed"] : ["XSpeed","YSpeed","ZSpeed"]
            let updates=try Dictionary(uniqueKeysWithValues:types.map { ($0,try workspace.checkedSpeedSetting($0,gear:gear)) })
            var settings=manualControls
            settings.seedMotionSpeeds(workspace:workspace)
            for (type,value) in updates { settings.motionSpeeds[type]=value }
            if event==1 { settings.loadGear=gear } else { settings.unloadGear=gear }
            workspace.manualControls=settings;scheduleSave()
        } catch { self.error=error.localizedDescription }
    }
    @discardableResult func setManualMotionSpeeds(_ values:[String:ProgramSpeed])->Bool {
        guard !manualControlsLocked else { return false }
        for type in ProgramSpeed.types {
            guard let value=values[type],(1...10).contains(value.gear),
                  (0...255).contains(value.acceleration),(0...255).contains(value.speed) else {
                error="手动\(ProgramSpeed.labels[type] ?? type)的档位应为1–10，加速度和速度应为0–255整数"
                return false
            }
        }
        var settings=manualControls;settings.motionSpeeds=values
        workspace.manualControls=settings;scheduleSave();notice="已保存手动通用速度"
        return true
    }
    func mutate(_ change: (inout Program) -> Void) {
        guard !programEditingLocked,let i=workspace.programs.firstIndex(where: { $0.id == selection }) else { return }
        undoHistory.append(workspace.programs[i]);if undoHistory.count>100 { undoHistory.removeFirst() };redoHistory=[]
        change(&workspace.programs[i]);invalidateCompilation();scheduleSave()
    }
    func undoEdit() {
        guard canUndo,let i=workspace.programs.firstIndex(where:{ $0.id == selection }),let p=undoHistory.popLast() else { return }
        redoHistory.append(workspace.programs[i]);workspace.programs[i]=p;finishHistoryEdit()
    }
    func redoEdit() {
        guard canRedo,let i=workspace.programs.firstIndex(where:{ $0.id == selection }),let p=redoHistory.popLast() else { return }
        undoHistory.append(workspace.programs[i]);workspace.programs[i]=p;finishHistoryEdit()
    }
    private func finishHistoryEdit() {
        let valid=Set(program?.steps.map(\.id) ?? [])
        selectedSteps.formIntersection(valid)
        if !valid.contains(selectedStep ?? "") { selectStep(program?.steps.first?.id) }
        invalidateCompilation();scheduleSave()
    }
    func setField(_ key: String,_ value: Any) {
        guard let id=selectedStep else { return }
        mutate { p in guard let i=p.steps.firstIndex(where: { $0.id == id }) else { return };p.steps[i].raw[key]=value;p.orderConfirmed=false }
    }
    func moveStep(_ delta: Int) {
        let ids=chosenStepIDs;guard !ids.isEmpty else { return }
        mutate { $0.moveSteps(ids:ids,delta:delta) }
    }
    func reorderSteps(ids:Set<String>,to boundary:Int) {
        guard !programEditingLocked,var reordered=program,reordered.reorderSteps(ids:ids,to:boundary) else { return }
        mutate { $0=reordered }
        selectSteps(ids)
        notice="已调整步骤顺序"
    }
    func deleteStep() {
        let ids=chosenStepIDs;guard !ids.isEmpty else { return }
        let index=program?.steps.firstIndex { ids.contains($0.id) } ?? 0
        mutate { $0.steps.removeAll { ids.contains($0.id) };$0.orderConfirmed=false }
        let remaining=program?.steps ?? [];selectStep(remaining.isEmpty ? nil : remaining[min(index,remaining.count-1)].id)
    }
    @discardableResult func copySelectedSteps(copies:Int,afterIndex:Int)->Bool {
        guard !programEditingLocked,var p=program else { return false }
        do { let ids=try p.copySteps(ids:chosenStepIDs,copies:copies,afterIndex:afterIndex);mutate { $0=p };selectSteps(Set(ids));notice="已复制 \(ids.count) 步";return true }
        catch { self.error=error.localizedDescription;return false }
    }
    @discardableResult func changeSelectedPositions(row:Int,column:Int,relative:Bool)->Bool {
        guard !programEditingLocked,var p=program,!chosenStepIDs.isEmpty else { return false }
        do { try p.changePositions(ids:chosenStepIDs,workspace:workspace,row:row,column:column,relative:relative);mutate { $0=p };notice="已更新所选步骤孔位";return true }
        catch { self.error=error.localizedDescription;return false }
    }
    func createProgramFolder(_ name:String) -> String? {
        guard !programEditingLocked else { return nil }
        do { let id=try workspace.createProgramFolder(name);scheduleSave();return id }
        catch { self.error=error.localizedDescription;return nil }
    }
    @discardableResult func renameProgramFolder(_ id:String,to name:String) -> Bool {
        guard !programEditingLocked else { return false }
        do { try workspace.renameProgramFolder(id,to:name);scheduleSave();return true }
        catch { self.error=error.localizedDescription;return false }
    }
    @discardableResult func reorderProgramFolder(_ id:String,relativeTo anchor:String,after:Bool) -> Bool {
        guard !programEditingLocked,workspace.reorderProgramFolder(id,relativeTo:anchor,after:after) else { return false }
        scheduleSave();return true
    }
    func removeProgramFolder(_ id:String) {
        guard !programEditingLocked,workspace.removeProgramFolder(id) else { return }
        notice="已移除文件夹，程序保留在根目录";scheduleSave()
    }
    @discardableResult func moveProgram(_ id:String,toFolder folderID:String?) -> Bool {
        guard !programEditingLocked,workspace.moveProgram(id,toFolder:folderID) else { return false }
        scheduleSave();return true
    }
    @discardableResult func arrangePrograms(_ ids:[String],at destination:ProgramLibraryDestination) -> Bool {
        guard !programEditingLocked,workspace.arrangePrograms(ids,at:destination) else { return false }
        scheduleSave();return true
    }
    func deleteProgram(_ requestedID:String?=nil,archive:Bool=true) {
        guard !programEditingLocked,let id=requestedID ?? selection,let index=workspace.programs.firstIndex(where:{ $0.id==id }),let removed=workspace.removeProgram(id,archive:archive) else { return }
        if selection==id {
            undoHistory=[];redoHistory=[]
            if !workspace.programs.isEmpty { select(workspace.programs[min(index,workspace.programs.count-1)].id) }
            else { selection=nil;selectStep(nil);invalidateCompilation() }
        }
        notice="已删除「\(removed.name)」";scheduleSave()
    }
    func restoreProgram(_ id:String) {
        guard !programEditingLocked,let restored=workspace.restoreProgram(id) else { return };select(restored);notice="程序已恢复";scheduleSave()
    }
    func setProgramSpeed(_ type:String,gear:Int) {
        do { let setting=try workspace.checkedSpeedSetting(type,gear:gear);mutate { $0.motionSpeeds[type]=setting } }
        catch { self.error=error.localizedDescription }
    }
    func setProgramSpeedValue(_ type:String,value:Int,acceleration:Bool) {
        guard var setting=program?.motionSpeeds[type] else { return }
        if acceleration { setting.acceleration=value } else { setting.speed=value }
        mutate { $0.motionSpeeds[type]=setting }
    }
    func resetProgramSpeeds() {
        do { let defaults=try workspace.checkedDefaultMotionSpeeds();mutate { $0.motionSpeeds=defaults } }
        catch { self.error=error.localizedDescription }
    }
    func addStep(_ event: Int) {
        guard !programEditingLocked else { return }
        var added=Step.blank(event,plate:step?.plate ?? 2)
        if event==9,program?.range==1000 { added.raw["p_speed"]=7 }
        let after=selectedStep
        mutate { $0.insert(added,after:after) };selectStep(added.id)
    }
    func duplicateStep() {
        let last=program?.steps.lastIndex { chosenStepIDs.contains($0.id) }
        _=copySelectedSteps(copies:1,afterIndex:last.map { $0+1 } ?? 0)
    }
    func ungroupLoop() {
        guard let id=selectedStep,let index=program?.steps.firstIndex(where:{ $0.id == id }) else { return }
        mutate { $0.ungroup(id) };selectStep(program?.steps.indices.contains(index) == true ? program?.steps[index].id : nil)
    }
    func createProgram(name:String,range:Int,table:Int,folderID:String?=nil) {
        guard !programEditingLocked else { return }
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { error="请输入程序名称";return }
        var p=Program.blank(name:name.trimmingCharacters(in:.whitespacesAndNewlines),range:range,table:table)
        do { try p.selectTable(table,workspace:workspace);p.motionSpeeds=try workspace.checkedDefaultMotionSpeeds() }
        catch { self.error=error.localizedDescription;return }
        workspace.programs.append(p);workspace.moveProgram(p.id,toFolder:folderID);select(p.id);save();showNewProgram=false
    }
    func duplicate() {
        guard !programEditingLocked,var p=program else { return }
        let folder=workspace.programFolderAssignments[p.id]
        p.id=UUID().uuidString;p.name += " · 副本";p.origin="Mac 副本";p.orderConfirmed=false
        p.steps=p.steps.map { Step(id:UUID().uuidString,raw:$0.raw,sourceIndex:$0.sourceIndex) }
        workspace.programs.append(p);workspace.moveProgram(p.id,toFolder:folder);select(p.id);save()
    }
    func createTemplate(kind: String,columns: Int,volume: Double) {
        guard !programEditingLocked else { return }
        let name=kind == "split" ? (columns == 2 ? "RT-split-4" : "lig-split-13") : (columns == 2 ? "RT-pool-15" : "lig-pool-14")
        guard var p=workspace.programs.first(where: { $0.raw.text("name") == name && $0.origin == "平板导出" }) else { error="当前工作区缺少模板来源方案 \(name)";return }
        guard volume>0,volume<=Double(p.range),volume.isFinite else { error="体积应大于 0 且不超过 \(p.range) µL";return }
        p.id=UUID().uuidString;p.name="\(columns)列 \(kind == "split" ? "Split" : "Pool") · \(formatNumber(volume)) µL";p.origin="Mac 模板 · \(name)";p.orderConfirmed=false
        func updated(_ source:JSONObject)->JSONObject {
            var raw=source
            if raw.integer("event_type")==8 { raw["loop_steps"]=raw.array("loop_steps").map(updated) }
            else if [3,4].contains(raw.integer("event_type")) { raw["dose"]=formatNumber(volume) }
            raw["status"]=0;return raw
        }
        p.steps=p.steps.map { Step(id:UUID().uuidString,raw:updated($0.raw),sourceIndex:$0.sourceIndex) }
        workspace.programs.append(p);select(p.id);save();showTemplate=false
    }
    func createLoop(from: Int,to: Int,count: Int) {
        guard !programEditingLocked,var p=program else { return }
        do {
            let id=try p.group(from:from,to:to,count:count)
            mutate { $0=p };selectStep(id);showLoop=false
        } catch { self.error=error.localizedDescription }
    }
    func saveLoop(children:[Step],count:Int) {
        guard !children.isEmpty,(1...1000).contains(count),children.count*count<=10000 else { error="循环需要至少一步、1–1000 次，展开后不超过 10,000 步";return }
        var raw=selectedRaw;raw["loop_count"]=count;raw["loop_steps"]=children.map(\.raw);selectedRaw=raw;showLoopEditor=false
    }
    func editRaw() { guard let s=step else { return };rawText=pretty(s.raw);showRaw=true }
    func applyRaw() {
        do {
            guard let d=try jsonObject(Data(rawText.utf8)) as? JSONObject,let id=selectedStep else { throw ControlError.invalid("步骤参数需要 JSON 对象") }
            mutate { p in if let i=p.steps.firstIndex(where: { $0.id == id }) { p.steps[i].raw=d;p.orderConfirmed=false } };showRaw=false
        } catch { self.error=error.localizedDescription }
    }
    func importData() {
        guard !manualControlsLocked else { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=false;panel.message="选择原 APP 的 dataJson 文件夹，或本软件导出的工作区 JSON"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            var imported:Workspace
            if url.hasDirectoryPath { imported=try Workspace.load(directory:url) }
            else {
                guard let d=try jsonObject(Data(contentsOf:url)) as? JSONObject,d.text("format")=="9210-mac-workspace-v1" else { throw ControlError.invalid("请选择本软件导出的完整工作区 JSON，或 dataJson 文件夹") }
                imported=try Workspace.restore(d);imported.source=url.path
            }
            try flush()
            // Preserve the prior local workspace before replacing the editable copy.
            if FileManager.default.fileExists(atPath:dataDirectory.appendingPathComponent("workspace.json").path) {
                try FileManager.default.copyItem(at:dataDirectory.appendingPathComponent("workspace.json"),to:dataDirectory.appendingPathComponent("workspace-backup-\(UUID().uuidString).json"))
            }
            imported.seedProgramSpeeds()
            if imported.manualControls==nil { imported.manualControls=ManualControlSettings.defaults(workspace:imported) }
            imported.seedManualSpeeds()
            workspace=imported;workspaceIdentity=UUID();selection=nil;selectStep(nil);undoHistory=[];redoHistory=[];invalidateCompilation()
            if let id=imported.programs.first?.id { select(id) };save()
        } catch { self.error="导入失败：\(error.localizedDescription)" }
    }
    func exportData() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="9210-Mac-工作区.json"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try jsonData(workspace.saved).write(to:url,options:.atomic);notice="工作区已导出" }
        catch { self.error=error.localizedDescription }
    }
    private func persistRun() async throws {
        guard let run=run,let file=runFile else { return }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in writer.write(run,to:file) { error in if let error=error { c.resume(throwing:error) } else { c.resume() } } }
    }
    private func checkpoint() async throws { while paused { try await Task.sleep(nanoseconds:100_000_000) };try Task.checkCancellation() }
    func runStep(_ id:String) {
        guard !manualControlsLocked,program?.steps.contains(where:{ $0.id==id }) == true else { return }
        selectSteps([id])
        start(selectedOnly:true)
    }
    func start(selectedOnly:Bool=false) {
        guard !isRunning,!manualBusy,!isStopping,!bluetooth.busy,var p=program else { return }
        if selectedOnly { guard let step=step else { return };p.steps=[step];p.name += " · 所选步骤" }
        let executionCompiler=compiler
        do { compiled=try executionCompiler.compile(p);compileError=nil } catch { compileError=error.localizedDescription;self.error=error.localizedDescription;return }
        guard !compiled.isEmpty else { error="方案没有可执行步骤";return }
        let live=mode == "hardware"
        if live {
            guard bluetooth.ready else { showDevice=true;return }
            guard manualFault==nil,!bluetooth.uncertain else { error="设备坐标状态未同步，请先复位并读取位置";return }
        }
        let snapshot=compiled;let id=UUID().uuidString
        do {
            let dir=dataDirectory.appendingPathComponent("runs",isDirectory:true);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            runFile=dir.appendingPathComponent(id+".json")
            run=["id":id,"mode":mode,"started":ISO8601DateFormatter().string(from:Date()),"state":"running","scope":selectedOnly ? "step" : "program","program":p.saved,"tables":executionCompiler.workspace.tables,"configurationSHA256":try fingerprint(executionCompiler.workspace.tables),"compiled":snapshot.map(\.saved),"completed":0,"responses":[]]
        } catch { self.error="运行快照保存失败，未启动：\(error.localizedDescription)";return }
        runningCompiled=snapshot;isRunningSingleStep=selectedOnly;isRunning=true;paused=false;progress=0;currentIndex=0;phase=live ? "运行中" : "模拟运行";notice="";log("运行",p.name+" · "+(live ? "工作站" : "模拟 / 压缩时间"))
        task=Task {
            do {
                try await self.persistRun()
                for (i,c) in snapshot.enumerated() {
                    try await self.checkpoint();self.currentIndex=i
                    if c.step.event==9 {
                        let request=try SegmentedAspirationRequest.parse(c.step.raw,range:p.range,compiler:executionCompiler)
                        let record=try await self.runSegmentedAspiration(request,live:live,xy:[c.fields["xPos"]!,c.fields["yPos"]!],executionCompiler:executionCompiler) { done,total,_ in
                            self.phase="分段下降吸液 · \(done)/\(total) 段"
                        }
                        var responses=self.run?["responses"] as? [JSONObject] ?? []
                        responses.append(["index":i,"segmentedActionID":record.text("id"),"state":record.text("state")]);self.run?["responses"]=responses
                    } else if let bytes=c.bytes {
                        if live {
                            let reply=try await self.bluetooth.request(bytes,timeoutSeconds:c.timeoutSeconds)
                            var responses=self.run?["responses"] as? [JSONObject] ?? [];responses.append(["index":i,"hex":reply.data.hex,"at":ISO8601DateFormatter().string(from:Date())]);self.run?["responses"]=responses
                        } else {
                            self.log("模拟 TX",bytes.hex);try await Task.sleep(nanoseconds:450_000_000)
                        }
                    } else {
                        var remaining=live ? c.step.raw.number("wait_time") : min(c.step.raw.number("wait_time"),1)
                        while remaining>0 { try await self.checkpoint();try await Task.sleep(nanoseconds:100_000_000);remaining-=0.1 }
                    }
                    try Task.checkCancellation();self.progress=Double(i+1)/Double(snapshot.count);self.run?["completed"]=i+1;try await self.persistRun()
                }
                self.phase="已完成";self.run?["state"]="complete";self.log("完成",p.name)
            } catch ControlError.stopped { self.phase="已停止";self.run?["state"]="stopped" }
            catch is CancellationError { self.phase="已停止";self.run?["state"]="stopped" }
            catch { self.phase="运行失败";self.run?["state"]=live ? "uncertain" : "failed";self.run?["error"]=error.localizedDescription;self.error=error.localizedDescription;self.log("错误",error.localizedDescription) }
            self.run?["finished"]=ISO8601DateFormatter().string(from:Date())
            do { try await self.persistRun() } catch { self.error="运行记录写入失败：\(error.localizedDescription)" }
            self.isRunning=false;self.isRunningSingleStep=false;self.runningCompiled=[];self.paused=false;self.task=nil
        }
    }
    func togglePause() { guard isRunning,!isRunningSingleStep else { return };paused.toggle();phase=paused ? "暂停后续步骤" : (mode == "hardware" ? "运行中" : "模拟运行") }
    func stop() {
        guard !isStopping else { return }
        let hardware=(mode=="hardware" || manualUsesHardware) && bluetooth.ready
        isStopping=hardware
        task?.cancel();paused=false
        manualTask?.cancel()
        if hardware {
            Task {
                defer { isStopping=false }
                do { try await bluetooth.stop();notice="停止指令已完成" }
                catch ControlError.stopped {} catch { self.error=error.localizedDescription }
            }
        }
    }
    func jog(direction:Int,distance:String) {
        performManual { commands,positions in try commands.plannedJog(direction:direction,distance:distance,positions:positions) }
    }
    func moveToPlate(tableID:Int,number:Int) {
        performManual { commands,positions in try commands.plateMove(tableID:tableID,number:number,positions:positions) }
    }
    private func persistManualRecord(_ record:JSONObject,to file:URL) async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            writer.write(record,to:file) { error in if let error=error { c.resume(throwing:error) } else { c.resume() } }
        }
    }
    func executeManualLiquid(_ event:Int) {
        guard !manualControlsLocked else { return }
        let live=mode=="hardware",settings=manualControls
        if live {
            guard bluetooth.ready else { showDevice=true;return }
            guard manualFault==nil,!bluetooth.uncertain else { error="设备坐标状态未同步，请先复位并读取位置";return }
        }
        let command:CompiledStep,initialRecord:JSONObject
        do {
            command=try compiler.compileManualLiquid(event:event,raw:settings.liquidRaw(event:event,workspace:workspace),settings:settings)
            initialRecord=["id":UUID().uuidString,"mode":mode,"kind":"manual-liquid","event":event,
                           "started":ISO8601DateFormatter().string(from:Date()),"state":"running",
                           "settings":settings.saved,"tables":workspace.tables,
                           "configurationSHA256":try fingerprint(workspace.tables),"compiled":command.saved,
                           "timeoutSeconds":command.timeoutSeconds]
        } catch { self.error=error.localizedDescription;return }
        guard let bytes=command.bytes else { return }
        let title=[3:"吸液",4:"放液",5:"混匀"][event] ?? "液体操作"
        let table=workspace.worktable(settings.tableID)
        let summary="\(title) · \(table.text("NickName","台面 \(settings.tableID)")) · \(command.step.detail) · \(command.step.displayDose)"
        let file=dataDirectory.appendingPathComponent("manual-actions/"+initialRecord.text("id")+".json")
        manualBusy=true;manualUsesHardware=live;manualStatus=summary+" · 准备执行"
        manualTask=Task {
            var record=initialRecord,sent=false
            defer { manualBusy=false;manualUsesHardware=false;manualTask=nil }
            do {
                try await persistManualRecord(record,to:file)
                try Task.checkCancellation()
                log(live ? "手动操作" : "模拟手动",summary)
                manualStatus=summary+(live ? " · 等待完成" : " · 模拟中")
                if live {
                    sent=true
                    let reply=try await bluetooth.request(bytes,timeoutSeconds:command.timeoutSeconds)
                    record["response"]=["hex":reply.data.hex,"at":ISO8601DateFormatter().string(from:Date())]
                    try Task.checkCancellation()
                    let positions=try await readPositions()
                    record["positions"]=positions.map(Int.init)
                    log("手动位置","\(title)完成后步数 \(positions)")
                } else {
                    log("模拟 TX",bytes.hex)
                    try await Task.sleep(nanoseconds:450_000_000)
                    try Task.checkCancellation()
                    // This checks command flow, not liquid delivery or plunger inventory.
                    // Wall-assisted dispense paths have not been simulated here.
                    if event != 4 || (command.fields["trappingType"] ?? 0)==0 {
                        simulatedPositions[0]=Int32(command.fields["xPos"] ?? 0)
                        simulatedPositions[1]=Int32(command.fields["yPos"] ?? 0)
                        let finalZKey=event==3 ? "completedImbibingPos" : event==4 ? "zTrappingPos" : "mixWellCompletedImbibingZPos"
                        simulatedPositions[2]=Int32(command.fields[finalZKey] ?? 0)
                        record["simulatedXYZUpdated"]=true
                    } else { record["simulatedXYZUpdated"]=false }
                    record["positions"]=simulatedPositions.map(Int.init)
                    record["liquidDeliverySimulated"]=false
                }
                try Task.checkCancellation()
                record["state"]="complete";manualStatus=summary+(live ? " · 已完成" : " · 模拟完成");notice=manualStatus
            } catch {
                if live,sent {
                    manualFault="手动液体动作中断，设备状态未同步，请复位";bluetooth.uncertain=true
                    if !(error is CancellationError),bluetooth.ready,!isStopping {
                        if case ControlError.stopped=error {} else { isStopping=true;try? await bluetooth.stop();isStopping=false;bluetooth.uncertain=true }
                    }
                }
                let stopped=error is CancellationError || { if case ControlError.stopped=error { return true };return false }()
                record["state"]=live && sent ? "uncertain" : stopped ? "stopped" : "failed"
                record["error"]=error.localizedDescription;manualStatus=summary+(stopped ? " · 已停止" : " · 未完成")
                log("手动操作中止",error.localizedDescription)
                if !stopped { self.error=error.localizedDescription }
            }
            record["finished"]=ISO8601DateFormatter().string(from:Date())
            do { try await persistManualRecord(record,to:file) }
            catch { self.error="手动记录保存失败：\(error.localizedDescription)" }
        }
    }
    func executeManualTip(_ event:Int) {
        guard !manualControlsLocked else { return }
        let live=mode=="hardware",settings=manualControls
        if live {
            guard bluetooth.ready else { showDevice=true;return }
            guard manualFault==nil,!bluetooth.uncertain else { error="设备坐标状态未同步，请先复位并读取位置";return }
        }
        let command:CompiledStep,initialRecord:JSONObject
        do {
            command=try compiler.compileManualTip(event:event,settings:settings)
            initialRecord=["id":UUID().uuidString,"mode":mode,"kind":"manual-tip","started":ISO8601DateFormatter().string(from:Date()),"state":"running","settings":settings.saved,"tables":workspace.tables,"configurationSHA256":try fingerprint(workspace.tables),"compiled":command.saved]
        } catch { self.error=error.localizedDescription;return }
        guard let bytes=command.bytes else { return }
        let title=event==1 ? "插枪头" : "卸枪头"
        let table=workspace.worktable(settings.tableID),material=table.array("WorkTablets")[command.step.plate-1].object("Material")
        let row=command.step.raw.integer("x_axis"),column=command.step.raw.integer("y_axis")
        let range="\(WellAddress.label(row:row,column:column)) → \(WellAddress.label(row:material.integer("HoleRow")-1,column:material.integer("HoleColum")-1))"
        let summary="\(title) · \(table.text("NickName","台面 \(settings.tableID)")) · T\(command.step.plate) · \(range) · \(material.integer("HoleColum")-column) 排／\(command.step.holes.count) 孔 · 手动通用速度"
        let file=dataDirectory.appendingPathComponent("manual-actions/"+initialRecord.text("id")+".json")
        manualBusy=true;manualUsesHardware=live;manualStatus=summary+" · 准备执行"
        manualTask=Task {
            var record=initialRecord,sent=false
            defer { manualBusy=false;manualUsesHardware=false;manualTask=nil }
            do {
                // Keep a reproducible command/configuration snapshot before any hardware action.
                try await persistManualRecord(record,to:file)
                try Task.checkCancellation()
                log(live ? "手动操作" : "模拟手动",summary)
                manualStatus=summary+(live ? " · 等待完成" : " · 模拟中")
                if live {
                    sent=true
                    let reply=try await bluetooth.request(bytes,timeoutSeconds:90)
                    record["response"]=["hex":reply.data.hex,"at":ISO8601DateFormatter().string(from:Date())]
                    let positions=try await readPositions()
                    record["positions"]=positions.map(Int.init)
                    log("手动位置","\(title)完成后步数 \(positions)")
                } else {
                    log("模拟 TX",bytes.hex)
                    try await Task.sleep(nanoseconds:450_000_000)
                    try Task.checkCancellation()
                    // Simulated end pose only; real tip actions use their completion reply, not the working depth.
                    simulatedPositions[0]=Int32(command.fields["xPos"] ?? 0)
                    simulatedPositions[1]=Int32(command.fields["yPos"] ?? 0)
                    simulatedPositions[2]=Int32(command.fields["zUpPos"] ?? 0)
                }
                try Task.checkCancellation()
                record["state"]="complete";manualStatus=summary+(live ? " · 已完成" : " · 模拟完成");notice=manualStatus
            } catch {
                if live,sent {
                    manualFault="手动动作中断，设备状态未同步，请复位";bluetooth.uncertain=true
                    if !(error is CancellationError),bluetooth.ready,!isStopping {
                        if case ControlError.stopped=error {} else { isStopping=true;try? await bluetooth.stop();isStopping=false;bluetooth.uncertain=true }
                    }
                }
                let stopped=error is CancellationError || { if case ControlError.stopped=error { return true };return false }()
                record["state"]=live && sent ? "uncertain" : stopped ? "stopped" : "failed"
                record["error"]=error.localizedDescription;manualStatus=summary+(stopped ? " · 已停止" : " · 未完成")
                log("手动操作中止",error.localizedDescription)
                if !stopped { self.error=error.localizedDescription }
            }
            record["finished"]=ISO8601DateFormatter().string(from:Date())
            do { try await persistManualRecord(record,to:file) }
            catch { self.error="手动记录保存失败：\(error.localizedDescription)" }
        }
    }
    func addSegmentedAspirationToProgram(_ request:SegmentedAspirationRequest) {
        guard !manualControlsLocked,let program=program else { error="请先选择或创建程序";return }
        guard program.range==request.range else { error="当前程序为 \(program.range) µL，请选同量程程序再添加";return }
        guard program.worktableID==manualControls.tableID else { error="当前程序与手动操作的板位组合不同，请先为程序选择同一组合";return }
        do {
            let added=try compiler.compileManualSegmentedAspiration(request,settings:manualControls).step
            _ = try compiler.compile(added,program:program)
            mutate { $0.insert(added,after:selectedStep) };selectStep(added.id);notice="已加入当前程序，沿用所选板位与孔位"
        } catch { self.error=error.localizedDescription }
    }
    func executeSegmentedAspiration(_ request:SegmentedAspirationRequest) {
        guard !manualControlsLocked else { return }
        let live=mode=="hardware"
        if live {
            guard bluetooth.ready else { showDevice=true;return }
            guard manualFault==nil,!bluetooth.uncertain else { error="设备坐标状态未同步，请先复位";return }
        }
        let settings=manualControls,coordinate:CompiledStep
        do { coordinate=try compiler.compileManualSegmentedAspiration(request,settings:settings) }
        catch { self.error=error.localizedDescription;return }
        manualBusy=true;manualUsesHardware=live;manualStatus="分段下降吸液 · 正常速度定位到起始 Z \(formatNumber(request.startZMM)) mm…"
        manualTask=Task {
            defer { manualBusy=false;manualUsesHardware=false;manualTask=nil }
            do {
                _ = try await runSegmentedAspiration(request,live:live,xy:[coordinate.fields["xPos"]!,coordinate.fields["yPos"]!],manualSettings:settings) { done,total,_ in
                    self.manualStatus="分段下降吸液 · \(done)/\(total) 段"
                }
                manualStatus=live ? "分段下降吸液 · 已完成，Z 已回到 0" : "分段下降吸液 · 模拟完成，Z 已回到 0";notice=manualStatus
            } catch is CancellationError { manualStatus="分段下降吸液 · 已停止" }
            catch ControlError.stopped { manualStatus="分段下降吸液 · 已停止" }
            catch { manualStatus="分段下降吸液 · 未完成";self.error=error.localizedDescription }
        }
    }
    /// One executor serves manual and program actions. Positioning to a program
    /// well raises Z first; calibrated aspiration totals are split only once.
    private func runSegmentedAspiration(_ request:SegmentedAspirationRequest,live:Bool,xy:[Int]?=nil,manualSettings:ManualControlSettings?=nil,executionCompiler:Compiler?=nil,
        onProgress:@escaping (Int,Int,[Int32])->Void) async throws -> JSONObject {
        try Task.checkCancellation()
        let snapshotCompiler=executionCompiler ?? compiler
        let commands=ManualCommands(compiler:snapshotCompiler)
        let before=live ? try await readPositions() : simulatedPositions
        var positioned=before,navigation:[ManualMotionPlan]=[]
        if let xy=xy {
            guard xy.count==2,xy.allSatisfy({ $0>=0 && $0<=Int(Int32.max) }) else { throw ControlError.invalid("程序孔位坐标无效") }
            if Int(before[0]) != xy[0] || Int(before[1]) != xy[1] {
                func appendNavigation(_ coordinates:[Int]) throws {
                    var target=positioned;for axis in 0..<3 { target[axis]=Int32(coordinates[axis]) }
                    navigation.append(try commands.segmentedPositioning(coordinates,positions:positioned));positioned=target
                }
                // Cached Z0 may come from a still-running 0102. Establish a
                // completed Z0 movement before changing XY in either case.
                try appendNavigation([Int(before[0]),Int(before[1]),0])
                try appendNavigation([xy[0],xy[1],0])
            }
        }
        let plan=try commands.segmentedAspiration(request,positions:positioned)
        let id=UUID().uuidString,file=dataDirectory.appendingPathComponent("manual-actions/"+id+".json")
        var record:JSONObject=["id":id,"kind":"segmented-aspiration","mode":live ? "hardware" : "simulation","state":"running",
            "started":ISO8601DateFormatter().string(from:Date()),"tables":snapshotCompiler.workspace.tables,"configurationSHA256":try fingerprint(snapshotCompiler.workspace.tables),
            "initialPositions":before.map(Int.init),"positioning":navigation.map { ["hex":$0.bytes.hex,"target":$0.target.map(Int.init)] },"plan":plan.saved]
        if let manualSettings=manualSettings { record["manualSettings"]=manualSettings.saved }
        try await persistManualRecord(record,to:file)
        var sent=false,writes:[JSONObject]=[],samples:[JSONObject]=[],failure:Error?
        // Zero-dose positioning can reuse identical bytes with a different live
        // plunger origin (e.g. start Z0 and final Z0). Consume the ordered plan.
        let simulationFrames=navigation.map { ($0.bytes,$0.target) }+[(plan.seek.bytes,plan.seek.target)]
            + plan.segments.map { ($0.bytes,$0.target) }+[(plan.returnToZero.bytes,plan.finalTarget)]
        var simulationFrameIndex=0
        let executeFrame:(Data) async throws -> Void = { bytes in
            try Task.checkCancellation()
            writes.append(["hex":bytes.hex,"simulation":!live,"at":ISO8601DateFormatter().string(from:Date())])
            if live {
                sent=true
                let reply=try await self.bluetooth.request(bytes,timeoutSeconds:600)
                writes[writes.count-1]["replyHex"]=reply.data.hex
            } else {
                self.log("模拟 TX",bytes.hex)
                guard simulationFrames.indices.contains(simulationFrameIndex),simulationFrames[simulationFrameIndex].0==bytes else { throw ControlError.invalid("模拟动作与计划顺序不符") }
                self.simulatedPositions=simulationFrames[simulationFrameIndex].1;simulationFrameIndex+=1
                try await Task.sleep(nanoseconds:40_000_000)
            }
        }
        let positions:() async throws -> [Int32] = {
            let value=live ? try await self.readPositions() : self.simulatedPositions
            samples.append(["at":ISO8601DateFormatter().string(from:Date()),"positions":value.map(Int.init)])
            return value
        }
        do {
            try Task.checkCancellation();log("分段吸液",plan.summary)
            for movement in navigation {
                try await executeFrame(movement.bytes);try Task.checkCancellation()
                let actual=try await positions()
                guard actual.count==4,(0..<4).allSatisfy({ abs(Int64(actual[$0])-Int64(movement.target[$0]))<=2 }) else { throw ControlError.invalid("程序孔位定位回读不符，未开始分段吸液") }
            }
            let executor=SegmentedAspirationExecutor(requestCompletion:executeFrame,readPositions:positions,
                pause:{ ms in try await Task.sleep(nanoseconds:UInt64(live ? ms : min(ms,40))*1_000_000) },onProgress:onProgress,
                onReturnToZero:{
                    if self.isRunning { self.phase="分段下降吸液 · 正在回到 Z0…" }
                    else { self.manualStatus="分段下降吸液 · 正在回到 Z0…" }
                })
            let final=try await executor.execute(plan)
            record["positions"]=final.map(Int.init);record["state"]="complete"
        } catch {
            failure=error
            let cancelled=error is CancellationError || { if case ControlError.stopped=error { return true };return false }()
            record["state"]=live && sent ? "uncertain" : cancelled ? "stopped" : "failed";record["error"]=error.localizedDescription
            if !live { record["positions"]=simulatedPositions.map(Int.init) }
            if live,sent {
                manualFault="分段吸液中断，设备状态未同步，请复位";bluetooth.uncertain=true
                if !cancelled,bluetooth.ready,!isStopping {
                    isStopping=true;try? await bluetooth.stop();isStopping=false;bluetooth.uncertain=true
                }
            }
        }
        record["writes"]=writes;record["positionsReadback"]=samples;record["finished"]=ISO8601DateFormatter().string(from:Date())
        do { try await persistManualRecord(record,to:file) } catch { if failure==nil { failure=error } }
        if let failure=failure { throw failure }
        return record
    }
    private func readPositions() async throws -> [Int32] {
        try Task.checkCancellation()
        let reply=try await bluetooth.request(Wire.query(true),timeoutSeconds:8)
        try Task.checkCancellation()
        guard let values=reply.positions,values.count==4 else { throw ControlError.invalid("未收到有效位置回包") }
        return values
    }
    private func performManual(_ makePlan:@escaping (ManualCommands,[Int32]) throws -> ManualMotionPlan) {
        guard !isRunning,!manualBusy,!isStopping,!bluetooth.busy else { return }
        let live=mode=="hardware",commands=ManualCommands(compiler:compiler)
        if live {
            guard bluetooth.ready else { showDevice=true;return }
            guard manualFault==nil,!bluetooth.uncertain else { error="设备坐标状态未同步，请先复位并读取位置";return }
        }
        manualBusy=true;manualUsesHardware=live;manualStatus=live ? "正在读取移动前位置…" : "正在模拟移动…"
        manualTask=Task {
            var sent=false
            defer { manualBusy=false;manualUsesHardware=false;manualTask=nil }
            do {
                let before=live ? try await readPositions() : simulatedPositions
                let plan=try makePlan(commands,before)
                try Task.checkCancellation()
                log(live ? "手动移动" : "模拟移动",plan.summary+" · 起始步数 \(before) · 目标步数 \(plan.target)")
                manualStatus=plan.summary+" · 等待到位"
                if !live {
                    log("模拟 TX",plan.bytes.hex);simulatedPositions=plan.target
                    manualStatus=plan.summary+" · 模拟到位";notice=manualStatus;return
                }
                sent=true
                let executor=ManualMotionExecutor(requestCompletion:{ bytes in _ = try await self.bluetooth.request(bytes,timeoutSeconds:60) },sendOnly:{ bytes in try await self.bluetooth.sendOnly(bytes) },readPositions:{ try await self.readPositions() },onPosition:{ values in self.log("位置核对","目标 \(plan.target) · 回读 \(values)") })
                _ = try await executor.execute(plan)
                manualStatus=plan.summary+" · 已读回到位";notice=manualStatus
            } catch {
                if live,sent {
                    manualFault="移动后坐标未同步，请复位"
                    if !(error is CancellationError),bluetooth.ready,!isStopping {
                        if case ControlError.stopped=error {} else {
                            isStopping=true;try? await bluetooth.stop();isStopping=false
                        }
                    }
                    bluetooth.uncertain=true
                }
                manualStatus="移动未完成";log("手动移动中止",error.localizedDescription)
                if error is CancellationError {} else if case ControlError.stopped=error {} else { self.error=error.localizedDescription }
            }
        }
    }
    var positionMM:[Double] { ManualCommands(compiler:compiler).positionMM(mode=="simulation" ? simulatedPositions : bluetooth.positions) }
    func query(_ position: Bool) {
        guard !isRunning,!manualBusy,!isStopping,!bluetooth.busy,bluetooth.ready else { return }
        manualBusy=true;manualUsesHardware=true;manualStatus=position ? "正在读取当前位置…" : "正在读取设备信息…"
        manualTask=Task {
            defer { manualBusy=false;manualUsesHardware=false;manualTask=nil }
            do {
                try Task.checkCancellation()
                let frame=try await bluetooth.request(Wire.query(position),timeoutSeconds:8)
                try Task.checkCancellation()
                notice=position ? "已读取当前位置" : "设备信息：\(Data(frame.payload).hex)";manualStatus=notice
            } catch ControlError.stopped { manualStatus="查询已停止" }
            catch is CancellationError { manualStatus="查询已停止" }
            catch { manualStatus="查询未完成";self.error=error.localizedDescription }
        }
    }
    func resetDevice() {
        guard canReset else { return }
        let live=mode=="hardware"
        isResetting=true;manualBusy=true;manualUsesHardware=live
        if live { manualFault="复位尚未完成" }
        manualStatus=live ? "工作站复位中…" : "正在模拟复位…"
        manualTask=Task {
            var completed=false
            defer {
                manualBusy=false;isResetting=false;manualUsesHardware=false;manualTask=nil
                if completed { showResetCompletion() }
            }
            do {
                try Task.checkCancellation()
                if !live {
                    log("模拟 TX",try Wire.frame(payload:[1,1]).hex)
                    try await Task.sleep(nanoseconds:250_000_000)
                    try Task.checkCancellation()
                    simulatedPositions=[0,0,0,0];manualStatus="模拟复位完成";notice=manualStatus
                    completed=true
                    return
                }
                _ = try await bluetooth.request(Wire.frame(payload:[1,1]),timeoutSeconds:90)
                let positions=try await readPositions()
                guard positions.prefix(3).allSatisfy({ abs(Int64($0))<=2 }) else { throw ControlError.invalid("复位完成后 XYZ 回报未归零，请检查设备") }
                bluetooth.uncertain=false;manualFault=nil;manualStatus="工作站复位并读回零点";notice=manualStatus
                completed=true
            } catch {
                if live { bluetooth.uncertain=true;manualFault="复位未完成，请重新复位";manualStatus=manualFault! }
                else { manualStatus="模拟复位已停止" }
                if error is CancellationError {} else if case ControlError.stopped=error {} else { self.error=error.localizedDescription }
            }
        }
    }
    private func showResetCompletion() {
        dismissResetCompletion()
        let id=UUID();resetCompletionID=id
        resetCompletionTask=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
            guard let self=self,!Task.isCancelled,self.resetCompletionID==id else { return }
            self.resetCompletionID=nil;self.resetCompletionTask=nil
        }
    }
    private func dismissResetCompletion() {
        resetCompletionTask?.cancel();resetCompletionTask=nil;resetCompletionID=nil
    }
    func openRecords() { do { try FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true);NSWorkspace.shared.open(dataDirectory) } catch { self.error=error.localizedDescription } }
}
