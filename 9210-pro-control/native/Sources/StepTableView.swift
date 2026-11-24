import SwiftUI
import AppKit

/// AppKit owns table selection and local drag events; the program remains in AppModel.
struct StepTableView:NSViewRepresentable {
    @ObservedObject var model:AppModel
    func makeCoordinator()->Coordinator { Coordinator(model:model) }
    func makeNSView(context:Context)->NSScrollView {
        let table=StepDragTableView()
        table.style = .inset
        table.rowHeight=42
        table.intercellSpacing=NSSize(width:8,height:0)
        table.usesAlternatingRowBackgroundColors=true
        table.allowsMultipleSelection=true
        table.allowsEmptySelection=true
        table.allowsColumnSelection=false
        table.allowsColumnReordering=false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.setAccessibilityLabel("程序步骤")
        for definition in [("order","顺序",32.0,32.0,32.0),("action","动作与位置",148.0,116.0,240.0),("dose","体积",80.0,70.0,120.0),("supplement","补充参数",260.0,40.0,10000.0)] {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(definition.0))
            column.title=definition.1;column.width=definition.2;column.minWidth=definition.3;column.maxWidth=definition.4
            column.resizingMask=definition.0=="order" ? [] : definition.0=="supplement" ? [.userResizingMask,.autoresizingMask] : [.userResizingMask]
            if definition.0=="dose" || definition.0=="order" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.delegate=context.coordinator;table.dataSource=context.coordinator
        table.canReorder={ [weak coordinator=context.coordinator] in coordinator?.model.programEditingLocked == false }
        table.doubleClickRow={ [weak coordinator=context.coordinator] row in coordinator?.runStep(at:row) }
        table.beginReorder={ [weak coordinator=context.coordinator,weak table] indexes in
            guard let coordinator=coordinator,let table=table else { return nil }
            return coordinator.reorderCommit(for:indexes,table:table)
        }
        let scroll=NSScrollView()
        scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        scroll.autohidesScrollers=true;scroll.borderType = .noBorder;scroll.drawsBackground=false
        context.coordinator.refresh(table,model:model)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let table=scroll.documentView as? NSTableView else { return }
        context.coordinator.refresh(table,model:model)
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        if let table=scroll.documentView as? StepDragTableView { table.delegate=nil;table.dataSource=nil;table.canReorder=nil;table.beginReorder=nil;table.doubleClickRow=nil }
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDelegate,NSTableViewDataSource {
        private struct Row:Equatable {
            let id:String,number:String,name:String,detail:String,dose:String,supplement:String,symbol:String
        }
        private var rows:[Row]=[]
        private var revision:UUID?
        private var activeID:String?
        private var selectedIDs:Set<String>?
        private var leadID:String?
        private static let symbols=[1:"arrow.down.to.line",2:"arrow.up.from.line",3:"arrow.up",4:"arrow.down",5:"arrow.up.arrow.down",6:"waveform",7:"clock",8:"repeat",9:"arrow.down.right"]
        private func isActive(_ rowID:String,_ active:String?)->Bool { active==rowID || active?.hasPrefix(rowID+"-")==true }
        private var syncingSelection=false
        private var programID:String?
        var model:AppModel
        init(model:AppModel) { self.model=model }
        func refresh(_ table:NSTableView,model:AppModel) {
            self.model=model
            let program=model.program, active=model.isRunning ? model.activeCompiled?.step.id : nil
            let contentChanged=revision != program?.stepsRevision || programID != program?.id
            let selectionChanged=selectedIDs != model.selectedSteps || leadID != model.selectedStep
            guard contentChanged || active != activeID || selectionChanged else { return }
            syncingSelection=true
            defer { syncingSelection=false }
            let previousActive=activeID;activeID=active
            var fullReload=false, changed=IndexSet()
            if contentChanged {
                let next=(program?.steps ?? []).enumerated().map { index,step in
                    Row(id:step.id,number:String(index+1),name:step.name,detail:step.detail,dose:step.displayDose,supplement:StepSupplement.text(event:step.event,raw:step.raw),symbol:Self.symbols[step.event] ?? "circle")
                }
                fullReload=programID != program?.id || rows.count != next.count || !zip(rows,next).allSatisfy { $0.id==$1.id }
                if !fullReload { changed=IndexSet(next.indices.filter { rows[$0] != next[$0] }) }
                rows=next;programID=program?.id;revision=program?.stepsRevision
            }
            if fullReload { table.reloadData() }
            else {
                if previousActive != active {
                    for i in rows.indices where isActive(rows[i].id,previousActive) != isActive(rows[i].id,active) { changed.insert(i) }
                }
                if !changed.isEmpty { table.reloadData(forRowIndexes:changed,columnIndexes:IndexSet(integersIn:0..<table.numberOfColumns)) }
            }
            if contentChanged || selectionChanged {
                let ids=model.chosenStepIDs
                let selected=IndexSet(rows.indices.filter { ids.contains(rows[$0].id) })
                if table.selectedRowIndexes != selected { table.selectRowIndexes(selected,byExtendingSelection:false) }
                selectedIDs=model.selectedSteps;leadID=model.selectedStep
            }
        }
        func numberOfRows(in tableView:NSTableView)->Int { rows.count }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard rows.indices.contains(row),let column=tableColumn else { return nil }
            let value=rows[row]
            if column.identifier.rawValue=="action" {
                let cell=(tableView.makeView(withIdentifier:column.identifier,owner:self) as? StepActionCell) ?? StepActionCell(identifier:column.identifier)
                cell.configure(name:value.name,detail:value.detail,symbol:isActive(value.id,activeID) ? "play.fill" : value.symbol)
                return cell
            }
            let cell=(tableView.makeView(withIdentifier:column.identifier,owner:self) as? StepTextCell) ?? StepTextCell(identifier:column.identifier)
            switch column.identifier.rawValue {
            case "order":cell.configure(value.number,font:.monospacedDigitSystemFont(ofSize:12,weight:.regular),secondary:true,alignment:.right)
            case "dose":cell.configure(value.dose,font:.monospacedDigitSystemFont(ofSize:13,weight:.semibold),secondary:false,alignment:.right)
            default:cell.configure(value.supplement,font:.monospacedDigitSystemFont(ofSize:12,weight:.regular),secondary:true,alignment:.left)
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !syncingSelection,!model.programEditingLocked,let table=notification.object as? NSTableView else { return }
            model.selectSteps(Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
        }
        func selectionShouldChange(in tableView:NSTableView)->Bool { !model.programEditingLocked }
        func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool { !model.programEditingLocked }
        func runStep(at row:Int) {
            guard !model.manualControlsLocked,rows.indices.contains(row),let program=model.program,
                  program.id==programID,program.steps.contains(where:{ $0.id==rows[row].id }) else { return }
            model.runStep(rows[row].id)
        }
        func reorderCommit(for indexes:IndexSet,table:NSTableView)->((Int)->Void)? {
            guard !model.programEditingLocked,let program=model.program,program.id==programID else { return nil }
            let orderedIDs=program.steps.map(\.id)
            guard indexes.allSatisfy({ orderedIDs.indices.contains($0) }),!indexes.isEmpty else { return nil }
            let movingIDs=Set(indexes.map { orderedIDs[$0] }),sourceProgramID=program.id
            return { [weak self,weak table] boundary in
                guard let self=self,let table=table,!self.model.programEditingLocked,
                      self.model.program?.id==sourceProgramID,self.model.program?.steps.map(\.id)==orderedIDs else { return }
                self.model.reorderSteps(ids:movingIDs,to:boundary)
                self.refresh(table,model:self.model)
            }
        }
    }
}

/// Local tracking keeps reordering inside this table instead of exporting a system drag session.
@MainActor private final class StepDragTableView:NSTableView {
    var canReorder:(()->Bool)?
    var beginReorder:((IndexSet)->((Int)->Void)?)?
    var doubleClickRow:((Int)->Void)?
    private var insertionBoundary:Int?
    private func insertionY(_ boundary:Int)->CGFloat {
        boundary<numberOfRows ? rect(ofRow:boundary).minY : rect(ofRow:numberOfRows-1).maxY
    }
    private func showInsertion(_ boundary:Int?) {
        guard boundary != insertionBoundary else { return }
        let previous=insertionBoundary;insertionBoundary=boundary
        for row in [previous,boundary].compactMap({ $0 }) where numberOfRows>0 {
            let y=insertionY(row),rect=visibleRect
            setNeedsDisplay(NSRect(x:rect.minX,y:y-2,width:rect.width,height:4))
        }
        setDropRow(boundary ?? -1,dropOperation:boundary == nil ? .on : .above)
    }
    override func mouseDown(with event:NSEvent) {
        let modifiers=event.modifierFlags.intersection([.command,.shift,.control,.option])
        guard modifiers.isEmpty,let window=window else { super.mouseDown(with:event);return }
        let source=row(at:convert(event.locationInWindow,from:nil))
        guard source>=0,source<numberOfRows else { super.mouseDown(with:event);return }
        guard canReorder?()==true else { return }
        window.makeFirstResponder(self)
        // This view consumes mouse tracking itself, so NSTableView.doubleAction
        // would never reliably receive the second click. Resolve its actual row
        // before starting drag tracking, then let the model guard execution.
        if event.clickCount==2 {
            selectRowIndexes(IndexSet(integer:source),byExtendingSelection:false)
            doubleClickRow?(source)
            return
        }
        let wasSelected=selectedRowIndexes.contains(source)
        if !wasSelected { selectRowIndexes(IndexSet(integer:source),byExtendingSelection:false) }
        guard let commit=beginReorder?(selectedRowIndexes) else { return }
        let origin=event.locationInWindow
        var dragging=false
        defer { showInsertion(nil) }
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown]) {
            if next.type == .keyDown {
                if next.keyCode==53 { return }
                continue
            }
            let displacement=next.locationInWindow
            if hypot(displacement.x-origin.x,displacement.y-origin.y)>=4 { dragging=true }
            if dragging {
                _=autoscroll(with:next)
                let point=convert(next.locationInWindow,from:nil)
                let inside:Bool
                if let clip=enclosingScrollView?.contentView { inside=clip.bounds.contains(clip.convert(next.locationInWindow,from:nil)) }
                else { inside=visibleRect.contains(point) }
                if inside {
                    let target=row(at:point)
                    let boundary:Int
                    if target>=0 { boundary=target+(point.y>=rect(ofRow:target).midY ? 1 : 0) }
                    else { boundary=point.y<rect(ofRow:0).minY ? 0 : numberOfRows }
                    showInsertion(min(max(boundary,0),numberOfRows))
                } else { showInsertion(nil) }
            }
            if next.type == .leftMouseUp {
                if dragging { if let boundary=insertionBoundary { commit(boundary) } }
                else if wasSelected { selectRowIndexes(IndexSet(integer:source),byExtendingSelection:false) }
                return
            }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard let boundary=insertionBoundary,numberOfRows>0 else { return }
        let y=insertionY(boundary)
        let line=NSBezierPath();line.move(to:NSPoint(x:visibleRect.minX+6,y:y));line.line(to:NSPoint(x:visibleRect.maxX-6,y:y))
        NSColor.controlAccentColor.setStroke();line.lineWidth=2;line.stroke()
    }
}

@MainActor private final class StepTextCell:NSTableCellView {
    private let label=NSTextField(labelWithString:"")
    init(identifier:NSUserInterfaceItemIdentifier) {
        super.init(frame:.zero);self.identifier=identifier
        label.translatesAutoresizingMaskIntoConstraints=false;label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines=1;addSubview(label);textField=label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:leadingAnchor),label.trailingAnchor.constraint(equalTo:trailingAnchor),label.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value:String,font:NSFont,secondary:Bool,alignment:NSTextAlignment) {
        label.stringValue=value;label.font=font;label.textColor=secondary ? .secondaryLabelColor : .labelColor;label.alignment=alignment;toolTip=value.isEmpty ? nil : value
    }
}

@MainActor private final class StepActionCell:NSTableCellView {
    private let symbol=NSImageView()
    private let action=NSTextField(labelWithString:"")
    private let detail=NSTextField(labelWithString:"")
    init(identifier:NSUserInterfaceItemIdentifier) {
        super.init(frame:.zero);self.identifier=identifier
        action.font = .systemFont(ofSize:13,weight:.medium);action.textColor = .labelColor
        detail.font = .systemFont(ofSize:12);detail.textColor = .secondaryLabelColor
        action.lineBreakMode = .byTruncatingTail;detail.lineBreakMode = .byTruncatingTail
        action.maximumNumberOfLines=1;detail.maximumNumberOfLines=1
        action.setContentCompressionResistancePriority(.defaultHigh,for:.horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let views:[NSView]=[symbol,action,detail]
        for view in views { view.translatesAutoresizingMaskIntoConstraints=false;addSubview(view) }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo:leadingAnchor),symbol.centerYAnchor.constraint(equalTo:centerYAnchor),symbol.widthAnchor.constraint(equalToConstant:16),symbol.heightAnchor.constraint(equalToConstant:16),
            action.leadingAnchor.constraint(equalTo:symbol.trailingAnchor,constant:8),action.centerYAnchor.constraint(equalTo:centerYAnchor),
            detail.leadingAnchor.constraint(equalTo:action.trailingAnchor,constant:6),detail.centerYAnchor.constraint(equalTo:centerYAnchor),detail.trailingAnchor.constraint(equalTo:trailingAnchor)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var backgroundStyle:NSView.BackgroundStyle { didSet { symbol.contentTintColor=backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor } }
    func configure(name:String,detail:String,symbol nameOfSymbol:String) {
        action.stringValue=name;self.detail.stringValue=detail
        symbol.image=NSImage(systemSymbolName:nameOfSymbol,accessibilityDescription:nil)
        symbol.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:12,weight:.medium)
        symbol.contentTintColor=backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        toolTip=name+" · "+detail
        setAccessibilityLabel(name+" · "+detail)
    }
}
