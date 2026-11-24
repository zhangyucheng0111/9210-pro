import SwiftUI
import AppKit

/// The entire plate is one drawing surface. Button semantics are exposed through
/// virtual accessibility children, so resizing doesn't lay out a view per well.
struct WellGrid:NSViewRepresentable {
    let rows:Int,columns:Int,row:Int,column:Int
    let cellSize:Double
    let select:(Int,Int)->Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context:Context)->WellGridView { WellGridView() }
    func updateNSView(_ view:WellGridView,context:Context) {
        view.select=select
        view.update(rows:rows,columns:columns,row:row,column:column,size:cellSize,enabled:enabled)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:WellGridView,context:Context)->CGSize? {
        CGSize(width:24+Double(columns)*(cellSize+4),height:24+Double(rows)*(cellSize+4))
    }
}

@MainActor final class WellGridView:NSView {
    private(set) var rows=0,columns=0,row=0,column=0
    private var size=18.0,enabled=true
    private var pressed:Int?
    private var keyboardFocus:Int?
    private var elements:[WellButton]=[]
    var select:((Int,Int)->Void)?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { enabled && rows*columns>0 }
    override func becomeFirstResponder()->Bool { needsDisplay=true;return super.becomeFirstResponder() }
    override func resignFirstResponder()->Bool { pressed=nil;needsDisplay=true;return super.resignFirstResponder() }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("孔位图")
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(rows:Int,columns:Int,row:Int,column:Int,size:Double,enabled:Bool) {
        let shapeChanged=self.rows != rows || self.columns != columns
        let selectionChanged=self.row != row || self.column != column
        guard shapeChanged || selectionChanged || self.size != size || self.enabled != enabled else { return }
        self.rows=rows;self.columns=columns;self.row=row;self.column=column;self.size=size;self.enabled=enabled
        if shapeChanged { elements=[];keyboardFocus=nil;pressed=nil }
        if selectionChanged || !enabled { keyboardFocus=nil;pressed=nil }
        if shapeChanged || selectionChanged,window != nil { NSAccessibility.post(element:self,notification:.selectedChildrenChanged) }
        needsDisplay=true
    }
    private var pitch:Double { size+4 }
    private var start:Int? { (0..<rows).contains(row) && (0..<columns).contains(column) ? row*columns+column : nil }
    fileprivate func enabledAt(_ index:Int)->Bool { enabled && (0..<rows*columns).contains(index) }
    fileprivate func value(at index:Int)->String {
        guard (0..<rows*columns).contains(index) else { return "未选" }
        if start==index { return "已选，起点" }
        return start != nil && index/columns>=row && index%columns>=column ? "已选" : "未选"
    }
    fileprivate func rect(at index:Int)->NSRect {
        guard columns>0 else { return .zero }
        return NSRect(x:28+Double(index%columns)*pitch,y:24+Double(index/columns)*pitch,width:size,height:size)
    }
    private func index(at point:NSPoint)->Int? {
        guard point.x>=28,point.y>=24,point.x<28+Double(columns)*pitch,point.y<24+Double(rows)*pitch else { return nil }
        let index=Int((point.y-24)/pitch)*columns+Int((point.x-28)/pitch)
        return rect(at:index).contains(point) ? index : nil
    }
    @discardableResult fileprivate func activate(_ index:Int)->Bool {
        guard enabledAt(index),let select=select else { return false }
        select(index/columns,index%columns);return true
    }
    override func mouseDown(with event:NSEvent) {
        pressed=enabled ? index(at:convert(event.locationInWindow,from:nil)) : nil
        if let pressed=pressed { keyboardFocus=pressed;window?.makeFirstResponder(self) }
    }
    override func mouseUp(with event:NSEvent) {
        let original=pressed;pressed=nil
        if let original=original,index(at:convert(event.locationInWindow,from:nil))==original { activate(original) }
    }
    override func keyDown(with event:NSEvent) {
        guard enabled,rows*columns>0,event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { super.keyDown(with:event);return }
        let index=keyboardFocus ?? start ?? 0
        var r=index/columns,c=index%columns
        switch event.keyCode {
        case 123: c=max(0,c-1)
        case 124: c=min(columns-1,c+1)
        case 125: r=min(rows-1,r+1)
        case 126: r=max(0,r-1)
        case 36,49,76: activate(index);return
        default: super.keyDown(with:event);return
        }
        keyboardFocus=r*columns+c;scrollToVisible(rect(at:r*columns+c));needsDisplay=true
    }
    override func accessibilityChildren()->[Any]? {
        if elements.isEmpty && rows*columns>0 { elements=(0..<rows*columns).map { WellButton(grid:self,index:$0) } }
        return elements
    }
    override func accessibilityHitTest(_ point:NSPoint)->Any? {
        guard let window=window,let i=index(at:convert(window.convertPoint(fromScreen:point),from:nil)),let children=accessibilityChildren() else { return self }
        return children[i]
    }
    override func draw(_ dirtyRect:NSRect) {
        guard rows*columns>0 else { return }
        let header:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]
        func label(_ text:String,_ rect:NSRect) {
            guard dirtyRect.intersects(rect) else { return }
            let s=text as NSString, extent=s.size(withAttributes:header)
            s.draw(at:NSPoint(x:rect.midX-extent.width/2,y:rect.midY-extent.height/2),withAttributes:header)
        }
        for c in 0..<columns { label(String(c+1),NSRect(x:28+Double(c)*pitch,y:0,width:size,height:20)) }
        let empty=NSBezierPath(),selected=NSBezierPath()
        empty.lineWidth=0.65;selected.lineWidth=0.65
        let firstRow=max(0,min(rows,Int(floor((dirtyRect.minY-24)/pitch))))
        let endRow=max(firstRow,min(rows,Int(ceil((dirtyRect.maxY-24)/pitch))))
        let firstColumn=max(0,min(columns,Int(floor((dirtyRect.minX-28)/pitch))))
        let endColumn=max(firstColumn,min(columns,Int(ceil((dirtyRect.maxX-28)/pitch))))
        let origin=start
        for r in firstRow..<endRow {
            label(WellAddress.rowLabel(r),NSRect(x:0,y:24+Double(r)*pitch,width:24,height:size))
            for c in firstColumn..<endColumn {
                let i=r*columns+c
                if i != origin { (origin != nil && r>=row && c>=column ? selected : empty).appendOval(in:rect(at:i).insetBy(dx:0.35,dy:0.35)) }
            }
        }
        NSColor.controlBackgroundColor.setFill();empty.fill()
        NSColor.separatorColor.setStroke();empty.stroke()
        let accent=NSColor.controlAccentColor
        accent.withAlphaComponent(0.16).setFill();selected.fill()
        accent.withAlphaComponent(0.4).setStroke();selected.stroke()
        if let origin=origin {
            let rect=rect(at:origin)
            if dirtyRect.intersects(rect) {
                accent.setFill();NSBezierPath(ovalIn:rect).fill()
                let mark=NSBezierPath();mark.lineWidth=max(1.4,size*0.07);mark.lineCapStyle = .round;mark.lineJoinStyle = .round
                mark.move(to:NSPoint(x:rect.minX+size*0.31,y:rect.minY+size*0.51))
                mark.line(to:NSPoint(x:rect.minX+size*0.45,y:rect.minY+size*0.65))
                mark.line(to:NSPoint(x:rect.minX+size*0.70,y:rect.minY+size*0.37))
                NSColor.white.setStroke();mark.stroke()
            }
        }
        if enabled,window?.firstResponder===self,let index=keyboardFocus ?? origin {
            let focus=NSBezierPath(ovalIn:rect(at:index).insetBy(dx:-1,dy:-1));focus.lineWidth=1.5
            NSColor.keyboardFocusIndicatorColor.setStroke();focus.stroke()
        }
    }
}

@MainActor private final class WellButton:NSAccessibilityElement {
    private weak var grid:WellGridView?
    private let index:Int
    init(grid:WellGridView,index:Int) {
        self.grid=grid;self.index=index;super.init()
        let name=WellAddress.label(row:index/grid.columns,column:index%grid.columns)
        setAccessibilityParent(grid);setAccessibilityRole(.button);setAccessibilityLabel("孔位 "+name);setAccessibilityHelp(name)
    }
    override func isAccessibilityElement()->Bool { true }
    override func accessibilityFrame()->NSRect {
        guard let grid=grid,let window=grid.window else { return .zero }
        return window.convertToScreen(grid.convert(grid.rect(at:index).intersection(grid.visibleRect),to:nil))
    }
    override func isAccessibilityEnabled()->Bool { grid?.enabledAt(index)==true }
    override func accessibilityValue()->Any? { grid?.value(at:index) }
    override func accessibilityPerformPress()->Bool { grid?.activate(index)==true }
}
