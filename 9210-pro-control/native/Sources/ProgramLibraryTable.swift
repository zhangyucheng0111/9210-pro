import SwiftUI
import AppKit

/// Only the sidebar rows use AppKit, for native modifier-key selection and local block dragging.
struct ProgramLibraryTable:NSViewRepresentable {
    struct Row:Equatable {
        enum Kind:Equatable { case folder(expanded:Bool),program(range:Int,indented:Bool),emptyRoot }
        let id:String,name:String,kind:Kind
        var showSeparator:Bool=false
        var programID:String? { if case .program=kind { return id };return nil }
        var folderID:String? { if case .folder=kind { return id };return nil }
    }
    struct Action {
        let title:String
        let run:()->Void
    }
    let model:AppModel
    let rows:[Row]
    let searching:Bool
    @Binding var selectedFolder:String?
    let toggleFolder:(String)->Void
    let actions:(Row)->[Action]
    let expandFolder:(String)->Void

    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSScrollView {
        let table=LibraryTableView()
        table.style = .sourceList
        table.rowHeight=32
        table.intercellSpacing=NSSize(width:0,height:0)
        table.headerView=nil
        table.allowsMultipleSelection=true;table.allowsEmptySelection=true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.setAccessibilityLabel("程序列表")
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("program"))
        column.minWidth=48;column.resizingMask=[.autoresizingMask];table.addTableColumn(column)
        let coordinator=context.coordinator
        table.delegate=coordinator;table.dataSource=coordinator
        table.rowMenu={ [weak coordinator] in coordinator?.menu(at:$0) }
        table.canSelect={ [weak coordinator] in coordinator?.canSelect ?? false }
        table.beginDrag={ [weak coordinator,weak table] index,indexes in
            guard let coordinator=coordinator,let table=table else { return nil }
            return coordinator.localDrag(from:index,selected:indexes,in:table)
        }
        let scroll=NSScrollView()
        scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        scroll.borderType = .noBorder;scroll.drawsBackground=false
        coordinator.refresh(table,owner:self)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        if let table=scroll.documentView as? NSTableView { context.coordinator.refresh(table,owner:self) }
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        if let table=scroll.documentView as? LibraryTableView {
            table.delegate=nil;table.dataSource=nil;table.rowMenu=nil;table.canSelect=nil;table.beginDrag=nil
        }
    }

    @MainActor final class Coordinator:NSObject,NSTableViewDelegate,NSTableViewDataSource {
        private var owner:ProgramLibraryTable
        private var rows:[Row]=[]
        private var rowsRevision=0
        private var leadID:String?
        private var folderID:String?
        private var identity:UUID?
        private var syncing=false
        var canSelect:Bool { !owner.model.programEditingLocked }
        init(_ owner:ProgramLibraryTable) { self.owner=owner }

        func refresh(_ table:NSTableView,owner:ProgramLibraryTable) {
            self.owner=owner
            let active=owner.model.selection,workspace=owner.model.workspaceIdentity
            let activeChanged=leadID != active || identity != workspace
            let folder=activeChanged ? nil : owner.selectedFolder
            guard rows != owner.rows || activeChanged || folderID != folder else { return }
            var programs=activeChanged ? Set<String>() : Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].programID : nil })
            if let active=active { programs.insert(active) }
            syncing=true;defer { syncing=false }
            identity=workspace;leadID=active;folderID=folder
            if rows != owner.rows { rows=owner.rows;rowsRevision+=1;table.reloadData() }
            let indexes:IndexSet
            if let folder=folder { indexes=IndexSet(rows.indices.filter { rows[$0].folderID==folder }) }
            else { indexes=IndexSet(rows.indices.filter { rows[$0].programID.map(programs.contains) ?? false }) }
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes,byExtendingSelection:false) }
        }
        func numberOfRows(in tableView:NSTableView)->Int { rows.count }
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
            guard rows.indices.contains(row),let id=column?.identifier else { return nil }
            let cell=(tableView.makeView(withIdentifier:id,owner:self) as? ProgramLibraryCell) ?? ProgramLibraryCell(identifier:id)
            let value=rows[row]
            cell.configure(value) { [weak self] in
                guard let self=self,!self.owner.searching,!self.owner.model.programEditingLocked else { return }
                self.owner.toggleFolder(value.id)
            }
            return cell
        }
        func selectionShouldChange(in tableView:NSTableView)->Bool { !owner.model.programEditingLocked }
        func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool {
            canSelect && rows.indices.contains(row) && rows[row].kind != .emptyRoot
        }
        func tableView(_ tableView:NSTableView,selectionIndexesForProposedSelection proposed:IndexSet)->IndexSet {
            guard proposed.count>1 else { return proposed }
            // Modifier-key batches contain programs only; folders select one at a time.
            let programs=IndexSet(proposed.filter { rows.indices.contains($0) && rows[$0].programID != nil })
            if !programs.isEmpty { return programs }
            return proposed.first.map { IndexSet(integer:$0) } ?? []
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !syncing,canSelect,let table=notification.object as? NSTableView else { return }
            let indices=table.selectedRowIndexes
            let nextFolder=indices.count==1 ? indices.first.flatMap { rows.indices.contains($0) ? rows[$0].folderID : nil } : nil
            folderID=nextFolder
            if owner.selectedFolder != nextFolder { owner.selectedFolder=nextFolder }
            // A folder in the sidebar does not replace the program open in the editor.
            guard nextFolder==nil,!indices.isEmpty else { return }
            let clicked=table.clickedRow
            let index=indices.contains(clicked) ? clicked : table.selectedRow
            // If a modifier deselected a different program, keep the editor on its current program.
            if clicked>=0,!indices.contains(clicked),let leadID=leadID,
               indices.contains(where:{ rows.indices.contains($0) && rows[$0].programID==leadID }) { return }
            guard rows.indices.contains(index),let id=rows[index].programID,id != leadID else { return }
            leadID=id;owner.model.select(id)
        }
        func menu(at index:Int)->NSMenu? {
            guard !owner.model.programEditingLocked,rows.indices.contains(index) else { return nil }
            let menu=NSMenu()
            for action in owner.actions(rows[index]) {
                let item=NSMenuItem(title:action.title,action:#selector(runMenuAction(_:)),keyEquivalent:"")
                item.target=self;item.representedObject=action.run;menu.addItem(item)
            }
            return menu.items.isEmpty ? nil : menu
        }
        @objc private func runMenuAction(_ item:NSMenuItem) { (item.representedObject as? ()->Void)?() }

        fileprivate func localDrag(from index:Int,selected indexes:IndexSet,in table:NSTableView)->LibraryDrag? {
            guard canSelect,rows.indices.contains(index) else { return nil }
            let workspace=owner.model.workspaceIdentity
            if let folder=rows[index].folderID { return folderDrag(folder,workspace:workspace) }
            guard !owner.searching,rows[index].programID != nil else { return nil }
            let ids=indexes.compactMap { rows.indices.contains($0) ? rows[$0].programID : nil }
            guard !ids.isEmpty else { return nil }
            let moving=Set(ids)
            return LibraryDrag(target:{ [weak self,weak table] index,after in
                guard let self=self,let table=table,self.canDrag(in:workspace) else { return nil }
                let destination:ProgramLibraryDestination,marker:Int,into:Bool
                if self.rows.indices.contains(index) {
                    let row=self.rows[index]
                    switch row.kind {
                    case .folder:destination = .end(row.id);marker=index;into=true
                    case .emptyRoot:destination = .end(nil);marker=index;into=true
                    case .program:
                        guard !moving.contains(row.id) else { return nil }
                        destination = after ? .after(row.id) : .before(row.id);marker=index+(after ? 1 : 0);into=false
                    }
                } else { destination = .end(nil);marker=table.numberOfRows;into=false }
                return .init(index:marker,into:into,perform:{ [weak self] in
                    guard let self=self,self.canDrag(in:workspace) else { return }
                    self.owner.model.arrangePrograms(ids,at:destination)
                    if case .end(let folder?)=destination { self.owner.expandFolder(folder) }
                })
            })
        }
        private func canDrag(in workspace:UUID)->Bool {
            canSelect && !owner.searching && workspace==owner.model.workspaceIdentity
        }
        private func folderDrag(_ source:String,workspace:UUID)->LibraryDrag {
            // Compute section boundaries once so long lists stay cheap to drag.
            var sections:[(id:String,start:Int,end:Int)]=[]
            var open:(id:String,start:Int)?
            for (index,row) in rows.enumerated() {
                if case .program(_,true)=row.kind { continue }
                if let group=open { sections.append((group.id,group.start,index));open=nil }
                if case .folder=row.kind { open=(row.id,index) }
            }
            if let group=open { sections.append((group.id,group.start,rows.count)) }
            let revision=rowsRevision
            return LibraryDrag(target:{ [weak self] row,belowMidpoint in
                guard let self=self,self.canDrag(in:workspace),self.rowsRevision==revision else { return nil }
                // When hovering a child, put the insertion line after the whole folder.
                let rowIndex=self.rows.indices.contains(row) ? row : self.rows.count
                guard let group=sections.last(where:{ $0.start<=rowIndex }),group.id != source else { return nil }
                let after = rowIndex==group.start ? belowMidpoint : true
                return .init(index:after ? group.end : group.start,into:false,perform:{ [weak self] in
                    guard let self=self,self.canDrag(in:workspace),self.rowsRevision==revision else { return }
                    self.owner.model.reorderProgramFolder(source,relativeTo:group.id,after:after)
                })
            },toggleFolder:{ [weak self] in
                guard let self=self,self.canDrag(in:workspace) else { return }
                self.owner.toggleFolder(source)
            })
        }
    }
}

private struct LibraryDropTarget {
    let index:Int,into:Bool
    let perform:()->Void
}
private struct LibraryDrag {
    let target:(Int,Bool)->LibraryDropTarget?
    var toggleFolder:(()->Void)?=nil
}

@MainActor private final class LibraryTableView:NSTableView {
    var rowMenu:((Int)->NSMenu?)?
    var canSelect:(()->Bool)?
    var beginDrag:((Int,IndexSet)->LibraryDrag?)?
    private let marker=LibraryDropMarker()
    private var tracking:(origin:NSPoint,drag:LibraryDrag,moved:Bool,doubleClick:Bool)?
    override func mouseDown(with event:NSEvent) {
        let index=row(at:convert(event.locationInWindow,from:nil))
        let modifiers=event.modifierFlags.intersection([.command,.shift,.control,.option])
        guard modifiers.isEmpty else { super.mouseDown(with:event);return }
        guard canSelect?()==true,index>=0 else { super.mouseDown(with:event);return }
        let indexes=selectedRowIndexes.contains(index) ? selectedRowIndexes : IndexSet(integer:index)
        guard let drag=beginDrag?(index,indexes) else { super.mouseDown(with:event);return }
        // Native modifier and keyboard navigation stay with NSTableView; only plain
        // mouse drags are tracked locally, including drops in the scroll view's blank area.
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(index) { selectRowIndexes(indexes,byExtendingSelection:false) }
        tracking=(event.locationInWindow,drag,false,event.clickCount==2)
    }
    override func mouseDragged(with event:NSEvent) {
        guard var state=tracking else { super.mouseDragged(with:event);return }
        let point=event.locationInWindow
        if !state.moved && hypot(point.x-state.origin.x,point.y-state.origin.y)<4 { return }
        state.moved=true;tracking=state
        _=autoscroll(with:event)
        showMarker(target(event,state.drag))
    }
    override func mouseUp(with event:NSEvent) {
        guard let state=tracking else { super.mouseUp(with:event);return }
        tracking=nil;showMarker(nil)
        let point=event.locationInWindow
        if state.moved || hypot(point.x-state.origin.x,point.y-state.origin.y)>=4 {
            target(event,state.drag)?.perform()
        } else if let toggle=state.drag.toggleFolder {
            if state.doubleClick { toggle() }
        } else {
            let index=row(at:convert(state.origin,from:nil))
            if index>=0 { selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        }
    }
    override func cancelOperation(_ sender:Any?) {
        if tracking != nil { tracking=nil;showMarker(nil) }
        else { super.cancelOperation(sender) }
    }
    private func target(_ event:NSEvent,_ drag:LibraryDrag)->LibraryDropTarget? {
        guard let clip=enclosingScrollView?.contentView,clip.bounds.contains(clip.convert(event.locationInWindow,from:nil)),numberOfRows>0 else { return nil }
        let point=convert(event.locationInWindow,from:nil),index=row(at:point)
        // Gaps above the first row are not the root drop area.
        if index<0 && point.y<rect(ofRow:0).minY { return nil }
        return drag.target(index,index>=0 && point.y>=rect(ofRow:index).midY)
    }
    private func showMarker(_ drop:LibraryDropTarget?) {
        guard let drop=drop,numberOfRows>0 else { marker.removeFromSuperview();return }
        let lineY=drop.index<numberOfRows ? rect(ofRow:drop.index).minY : rect(ofRow:numberOfRows-1).maxY
        let x=visibleRect.minX+10,width=max(1,visibleRect.width-20)
        let rect=drop.into ? NSRect(x:x,y:lineY+2,width:width,height:rect(ofRow:drop.index).height-4) : NSRect(x:x,y:lineY-1,width:width,height:2)
        marker.into=drop.into;marker.frame=rect;marker.needsDisplay=true
        if marker.superview==nil { addSubview(marker,positioned:.above,relativeTo:nil) }
    }
    override func menu(for event:NSEvent)->NSMenu? { rowMenu?(row(at:convert(event.locationInWindow,from:nil))) }
}

@MainActor private final class LibraryDropMarker:NSView {
    var into=false
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        let color=NSColor.controlAccentColor
        if into {
            let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:5,yRadius:5)
            color.withAlphaComponent(0.14).setFill();shape.fill();color.setStroke();shape.lineWidth=2;shape.stroke()
        } else { color.setFill();bounds.fill() }
    }
}

@MainActor private final class ProgramLibraryCell:NSTableCellView {
    private let name=NSTextField(labelWithString:"")
    private let range=NSTextField(labelWithString:"")
    private let disclosure=NSButton(image:NSImage(),target:nil,action:nil)
    private let folder=NSImageView()
    private var onToggle:(()->Void)?
    private let separator=NSBox()
    private let childGuide=ProgramLibraryChildGuide()
    private var leading:NSLayoutConstraint!
    private var programTrailing:NSLayoutConstraint!
    private var folderTrailing:NSLayoutConstraint!
    init(identifier:NSUserInterfaceItemIdentifier) {
        super.init(frame:.zero);self.identifier=identifier
        name.font = .systemFont(ofSize:15,weight:.semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        range.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
        range.textColor = .secondaryLabelColor;range.alignment = .right
        disclosure.isBordered=false;disclosure.target=self;disclosure.action=#selector(toggle)
        disclosure.contentTintColor = .secondaryLabelColor
        folder.image=NSImage(systemSymbolName:"folder.fill",accessibilityDescription:nil)
        folder.contentTintColor = .controlAccentColor;folder.setAccessibilityElement(false)
        separator.boxType = .separator;separator.setAccessibilityElement(false)
        childGuide.setAccessibilityElement(false)
        for view in [childGuide,separator,name,range,disclosure,folder] { view.translatesAutoresizingMaskIntoConstraints=false;addSubview(view) }
        leading=name.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6)
        programTrailing=name.trailingAnchor.constraint(lessThanOrEqualTo:range.leadingAnchor,constant:-7)
        folderTrailing=name.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-6)
        NSLayoutConstraint.activate([
            childGuide.leadingAnchor.constraint(equalTo:leadingAnchor,constant:21),childGuide.widthAnchor.constraint(equalToConstant:1),
            childGuide.topAnchor.constraint(equalTo:topAnchor),childGuide.bottomAnchor.constraint(equalTo:bottomAnchor),
            separator.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6),separator.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),separator.topAnchor.constraint(equalTo:topAnchor),separator.heightAnchor.constraint(equalToConstant:1),
            leading,programTrailing,name.centerYAnchor.constraint(equalTo:centerYAnchor),
            range.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),range.widthAnchor.constraint(equalToConstant:63),range.centerYAnchor.constraint(equalTo:centerYAnchor),
            disclosure.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),disclosure.widthAnchor.constraint(equalToConstant:14),disclosure.heightAnchor.constraint(equalToConstant:20),disclosure.centerYAnchor.constraint(equalTo:centerYAnchor),
            folder.leadingAnchor.constraint(equalTo:disclosure.trailingAnchor,constant:3),folder.widthAnchor.constraint(equalToConstant:15),folder.heightAnchor.constraint(equalToConstant:16),folder.centerYAnchor.constraint(equalTo:centerYAnchor)
        ])
        textField=name
    }
    required init?(coder:NSCoder) { nil }
    override var backgroundStyle:NSView.BackgroundStyle {
        didSet { updateFolderControlColors() }
    }
    private func updateFolderControlColors() {
        let emphasized=backgroundStyle == .emphasized
        folder.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        disclosure.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
    func configure(_ row:ProgramLibraryTable.Row,onToggle:@escaping ()->Void) {
        name.stringValue=row.name;toolTip=row.name;separator.isHidden = !row.showSeparator
        name.textColor = row.kind == .emptyRoot ? .secondaryLabelColor : .labelColor
        name.font = .systemFont(ofSize:15,weight:.semibold)
        childGuide.isHidden=true
        switch row.kind {
        case .program(let volume,let indented):
            folderTrailing.isActive=false;programTrailing.isActive=true
            childGuide.isHidden = !indented
            leading.constant=indented ? 30 : 6;range.stringValue="\(volume.formatted()) µL"
            range.isHidden=false;folder.isHidden=true;disclosure.isHidden=true;self.onToggle=nil
        case .emptyRoot:
            programTrailing.isActive=false;folderTrailing.isActive=true;leading.constant=6
            range.isHidden=true;folder.isHidden=true;disclosure.isHidden=true;self.onToggle=nil
        case .folder(let expanded):
            name.font = .systemFont(ofSize:14,weight:.semibold)
            programTrailing.isActive=false;folderTrailing.isActive=true
            leading.constant=42
            range.isHidden=true;folder.isHidden=false;disclosure.isHidden=false;self.onToggle=onToggle
            disclosure.image=NSImage(systemSymbolName:expanded ? "chevron.down" : "chevron.right",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:9,weight:.semibold))
            disclosure.setAccessibilityLabel("\(expanded ? "折叠" : "展开")文件夹 \(row.name)")
        }
    }
    @objc private func toggle() { onToggle?() }
}

@MainActor private final class ProgramLibraryChildGuide:NSView {
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
    }
}
