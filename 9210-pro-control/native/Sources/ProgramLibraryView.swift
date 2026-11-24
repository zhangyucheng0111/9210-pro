import SwiftUI
import AppKit

struct ProgramLibraryView:View {
    @ObservedObject var model:AppModel
    let resetWidths:()->Void
    @State private var search=""
    @State private var collapsed:Set<String>=[]
    @State private var highlightedFolder:String?
    @State private var folderEdit:FolderEdit?
    @State private var moveRequest:Program?
    @State private var pendingDeletion:Deletion?

    private struct FolderEdit:Identifiable {
        var folder:ProgramFolder?=nil
        var movingProgram:String?=nil
        let id=UUID()
    }
    private enum Deletion {
        case program(Program),folder(ProgramFolder)
        var title:String {
            switch self { case .program(let program):return "删除「\(program.name)」？";case .folder(let folder):return "移除文件夹「\(folder.name)」？" }
        }
        var message:String {
            switch self { case .program:return "此程序及其步骤将被移除。";case .folder:return "里面的程序会移回根目录。" }
        }
        var action:String { if case .folder=self { return "移除文件夹" };return "删除程序" }
    }
    private var query:String { search.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var activeProgramFolder:String? { model.selection.flatMap { model.workspace.programFolderAssignments[$0] } }
    private var rows:[ProgramLibraryTable.Row] {
        let workspace=model.workspace,q=query
        let validFolders=Set(workspace.programFolders.map(\.id))
        let groups=Dictionary(grouping:workspace.programs) { program in
            workspace.programFolderAssignments[program.id].flatMap { validFolders.contains($0) ? $0 : nil }
        }
        func matches(_ p:Program)->Bool { q.isEmpty || p.name.localizedCaseInsensitiveContains(q) }
        var result:[ProgramLibraryTable.Row]=[]
        for folder in workspace.programFolders {
            let matchesFolder=q.isEmpty || folder.name.localizedCaseInsensitiveContains(q)
            let children=(groups[folder.id] ?? []).filter { matchesFolder || matches($0) }
            guard matchesFolder || !children.isEmpty else { continue }
            let expanded = !q.isEmpty || !collapsed.contains(folder.id)
            result.append(.init(id:folder.id,name:folder.name,kind:.folder(expanded:expanded)))
            if expanded { result+=children.map { .init(id:$0.id,name:$0.name,kind:.program(range:$0.range,indented:true)) } }
        }
        let root=(groups[nil] ?? []).filter(matches),hasFolders = !result.isEmpty
        result+=root.enumerated().map { index,program in
            .init(id:program.id,name:program.name,kind:.program(range:program.range,indented:false),showSeparator:hasFolders && index==0)
        }
        if q.isEmpty,hasFolders,root.isEmpty {
            result.append(.init(id:"root",name:"根目录",kind:.emptyRoot,showSeparator:true))
        }
        return result
    }
    var body:some View {
        let visible=rows
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("程序").font(StudioTypography.paneTitle)
                Spacer()
                Button { folderEdit=FolderEdit() } label:{ Image(systemName:"folder.badge.plus") }
                    .buttonStyle(.borderless).help("新建文件夹").accessibilityLabel("新建文件夹")
            }.padding(.horizontal,16).padding(.top,17).padding(.bottom,11)
            HStack(spacing:7) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("查找程序",text:$search).textFieldStyle(.plain)
            }.font(StudioTypography.metadata).padding(7).background(Style.surface,in:RoundedRectangle(cornerRadius:6)).padding(.horizontal,12).padding(.bottom,8)
            ProgramLibraryTable(model:model,rows:visible,searching:!query.isEmpty,selectedFolder:$highlightedFolder,toggleFolder:{ id in
                if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
            },actions:rowActions,expandFolder:{ collapsed.remove($0) })
                .overlay { if visible.isEmpty { Text(query.isEmpty ? "还没有程序" : "没有匹配的程序或文件夹").font(StudioTypography.caption).foregroundStyle(.secondary).allowsHitTesting(false) } }
            if query.isEmpty,!visible.isEmpty {
                Text("拖动文件夹或程序 · ⌘ 多选 · ⇧ 连选").font(StudioTypography.caption).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.horizontal,14).padding(.vertical,7)
            }
            Divider()
            HStack {
                Button { model.showNewProgram=true } label:{ Label("新建程序…",systemImage:"plus") }
                Spacer(minLength:8)
                Menu {
                    if let id=highlightedFolder,let folder=model.workspace.programFolders.first(where:{ $0.id==id }),
                       visible.contains(where:{ $0.folderID==id }) {
                        Button("重命名文件夹…") { folderEdit=FolderEdit(folder:folder) }
                        Button("移除文件夹…",role:.destructive) { pendingDeletion = .folder(folder) }
                        Divider()
                    } else if highlightedFolder==nil,let program=model.program {
                        Button("复制程序") { model.duplicate() }
                        Button("移动到文件夹…") { moveRequest=program }
                        Button("删除程序…",role:.destructive) { pendingDeletion = .program(program) }
                        Divider()
                    }
                    Button("导入工作区…") { model.importData() }.disabled(model.manualControlsLocked)
                    Button("导出工作区…") { model.exportData() }
                    Button("Split / Pool 示例…") { model.showTemplate=true }
                    Divider()
                    Button("恢复默认栏宽",action:resetWidths)
                } label:{ Image(systemName:"ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("程序更多操作")
            }.controlSize(.small).padding(12)
        }
        .disabled(model.programEditingLocked)
        .onChange(of:activeProgramFolder) { _, id in if let id=id { collapsed.remove(id) } }
        .onChange(of:model.selection) { _,_ in highlightedFolder=nil }
        .onChange(of:model.workspaceIdentity) { _,_ in collapsed=[];search="";highlightedFolder=nil;folderEdit=nil;moveRequest=nil;pendingDeletion=nil }
        .sheet(item:$folderEdit) { edit in
            FolderNameSheet(original:edit.folder?.name ?? "",title:edit.folder==nil ? "新建文件夹" : "重命名文件夹") { name in
                if let folder=edit.folder { return model.renameProgramFolder(folder.id,to:name) }
                guard let id=model.createProgramFolder(name) else { return false }
                if let program=edit.movingProgram { model.moveProgram(program,toFolder:id) }
                collapsed.remove(id);return true
            }
        }
        .sheet(item:$moveRequest) { program in
            ProgramMoveSheet(program:program,folders:model.workspace.programFolders,current:model.workspace.programFolderAssignments[program.id]) { target in
                guard model.moveProgram(program.id,toFolder:target) else { return false }
                if let target=target { collapsed.remove(target) };return true
            } onNew:{
                // Let the first sheet finish before presenting the name form.
                moveRequest=nil
                DispatchQueue.main.async { folderEdit=FolderEdit(movingProgram:program.id) }
            }
        }
        .alert(pendingDeletion?.title ?? "确认删除",isPresented:Binding(get:{ pendingDeletion != nil },set:{ if !$0 { pendingDeletion=nil } }),presenting:pendingDeletion) { request in
            Button("取消",role:.cancel) {}
            Button(request.action,role:.destructive) {
                switch request {
                case .program(let program): model.deleteProgram(program.id,archive:false)
                case .folder(let folder):
                    model.removeProgramFolder(folder.id);collapsed.remove(folder.id)
                    if highlightedFolder==folder.id { highlightedFolder=nil }
                }
            }
        } message:{ request in Text(request.message) }
    }
    private func rowActions(_ row:ProgramLibraryTable.Row)->[ProgramLibraryTable.Action] {
        switch row.kind {
        case .emptyRoot:return []
        case .folder:
            guard let folder=model.workspace.programFolders.first(where:{ $0.id==row.id }) else { return [] }
            return [.init(title:"重命名…",run:{ folderEdit=FolderEdit(folder:folder) }),
                    .init(title:"移除文件夹…",run:{ pendingDeletion = .folder(folder) })]
        case .program:
            guard let program=model.workspace.programs.first(where:{ $0.id==row.id }) else { return [] }
            return [.init(title:"移动到文件夹…",run:{ moveRequest=program }),
                    .init(title:"新建文件夹并移入…",run:{ folderEdit=FolderEdit(movingProgram:program.id) }),
                    .init(title:"删除程序…",run:{ pendingDeletion = .program(program) })]
        }
    }
}

private struct ProgramMoveSheet:View {
    @Environment(\.dismiss) private var dismiss
    @State private var destination:String?
    let program:Program,folders:[ProgramFolder],current:String?
    let submit:(String?)->Bool
    let onNew:()->Void
    init(program:Program,folders:[ProgramFolder],current:String?,submit:@escaping(String?)->Bool,onNew:@escaping()->Void) {
        self.program=program;self.folders=folders;self.current=current;self.submit=submit;self.onNew=onNew
        _destination=State(initialValue:current)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("移动程序").font(StudioTypography.paneTitle)
            Text(program.name).lineLimit(2)
            Picker("移至",selection:$destination) {
                Text("根目录").tag(nil as String?)
                ForEach(folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
            }
            HStack {
                Button("新建文件夹…",action:onNew)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("移动") { if submit(destination) { dismiss() } }.keyboardShortcut(.defaultAction).disabled(destination==current)
            }
        }.padding(22).frame(width:370)
    }
}

private struct FolderNameSheet:View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor=FolderNameEditor()
    @State private var validationMessage:String?
    let original:String,title:String
    let submit:(String)->Bool

    private func save() {
        let name=ProgramFolder.cleanName(editor.draft)
        guard !name.isEmpty,name.count<=80 else {
            validationMessage="请输入 1–80 个字符的文件夹名称"
            return
        }
        if submit(name) { dismiss() }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(title).font(StudioTypography.paneTitle)
            FolderNameInput(original:original,editor:editor,onSubmit:save).frame(height:26)
            if let validationMessage=validationMessage {
                Text(validationMessage).font(StudioTypography.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存",action:save).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width:340)
    }
}

/// Keep the composing text in the native field editor. A button click must read
/// the actual visible draft, even if an input method has not sent a change yet.
@MainActor private final class FolderNameEditor {
    weak var field:NSTextField?
    var draft:String {
        guard let field=field else { return "" }
        return field.currentEditor()?.string ?? field.stringValue
    }
}

private struct FolderNameInput:NSViewRepresentable {
    let original:String
    let editor:FolderNameEditor
    let onSubmit:()->Void

    func makeCoordinator()->Coordinator { Coordinator(onSubmit:onSubmit) }
    func makeNSView(context:Context)->NSTextField {
        let field=InitialFocusFolderField(string:original)
        field.placeholderString="文件夹名称"
        field.setAccessibilityLabel("文件夹名称")
        field.font = .systemFont(ofSize:13)
        field.isBezeled=true;field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode=true
        field.target=context.coordinator;field.action=#selector(Coordinator.submit)
        editor.field=field
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        // Never set stringValue in a view refresh; doing so would reset composition and selection.
        context.coordinator.onSubmit=onSubmit
    }
    @MainActor final class Coordinator:NSObject {
        var onSubmit:()->Void
        init(onSubmit:@escaping()->Void) { self.onSubmit=onSubmit }
        @objc func submit() { onSubmit() }
    }
}

@MainActor private final class InitialFocusFolderField:NSTextField {
    private var requestedFocus=false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil,!requestedFocus else { return }
        requestedFocus=true
        DispatchQueue.main.async { [weak self] in
            guard let self=self,self.window != nil,self.currentEditor()==nil else { return }
            self.selectText(nil)
        }
    }
}
