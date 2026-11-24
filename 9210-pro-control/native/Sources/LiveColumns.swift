import SwiftUI
import AppKit

// The native container moves/resizes only the affected panes, without changing
// any SwiftUI bindings during tracking. Each host keeps its existing view state.
struct LiveProgramColumns<Left:View,Center:View,Right:View>:View {
    @Binding var leftWidth:Double
    @Binding var rightWidth:Double
    let left:Left,center:Center,right:Right
    var body:some View {
        LiveColumns(leftWidth:$leftWidth,rightWidth:$rightWidth,leftMinimum:224,centerMinimum:380,rightMinimum:320,
                    leftLabel:"调整程序列表宽度",left:left,center:center,right:right)
    }
}

struct LiveTwoColumns<Left:View,Right:View>:View {
    @Binding var leftWidth:Double
    let minimum:Double,rightMinimum:Double
    let label:String
    let left:Left,right:Right
    var body:some View {
        LiveColumns(leftWidth:$leftWidth,rightWidth:nil,leftMinimum:minimum,centerMinimum:rightMinimum,rightMinimum:0,
                    leftLabel:label,left:left,center:right,right:EmptyView())
    }
}

private struct LiveColumns<Left:View,Center:View,Right:View>:NSViewRepresentable {
    @Binding var leftWidth:Double
    let rightWidth:Binding<Double>?
    let leftMinimum:Double,centerMinimum:Double,rightMinimum:Double,leftLabel:String
    let left:Left,center:Center,right:Right
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    // Reinject environment values read by our controls below the hosting boundary.
    private func content<V:View>(_ v:V)->AnyView {
        AnyView(v.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .disabled(!enabled).environment(\.colorScheme,colorScheme)
            .groupBoxStyle(StudioGroupBoxStyle()))
    }
    private func host<V:View>(_ content:V)->NSHostingView<AnyView> {
        let view=NSHostingView(rootView:self.content(content));view.sizingOptions=[];view.clipsToBounds=true
        return view
    }
    func makeNSView(context:Context)->PaneLayoutView {
        PaneLayoutView(leading:host(left),middle:host(center),trailing:rightWidth==nil ? nil : host(right),
                       leftMinimum:leftMinimum,centerMinimum:centerMinimum,rightMinimum:rightMinimum,leftLabel:leftLabel)
    }
    func updateNSView(_ view:PaneLayoutView,context:Context) {
        view.leading.rootView=content(left);view.middle.rootView=content(center)
        view.trailing?.rootView=content(right)
        view.onLeftCommit={ width in if leftWidth != width { leftWidth=width } }
        view.onRightCommit={ width in if let value=rightWidth,value.wrappedValue != width { value.wrappedValue=width } }
        view.configure(left:leftWidth,right:rightWidth?.wrappedValue ?? 0,enabled:enabled)
    }
}

final class PaneLayoutView:NSView {
    let leading:NSHostingView<AnyView>,middle:NSHostingView<AnyView>,trailing:NSHostingView<AnyView>?
    private let leftMinimum:Double,centerMinimum:Double,rightMinimum:Double
    private let leftDivider=PaneDivider(),rightDivider=PaneDivider()
    private var savedLeft=0.0,savedRight=0.0
    private var liveLeft:Double?,liveRight:Double?
    var onLeftCommit:((Double)->Void)?,onRightCommit:((Double)->Void)?
    init(leading:NSHostingView<AnyView>,middle:NSHostingView<AnyView>,trailing:NSHostingView<AnyView>?,leftMinimum:Double,centerMinimum:Double,rightMinimum:Double,leftLabel:String) {
        self.leading=leading;self.middle=middle;self.trailing=trailing
        self.leftMinimum=leftMinimum;self.centerMinimum=centerMinimum;self.rightMinimum=rightMinimum
        super.init(frame:.zero)
        clipsToBounds=true
        addSubview(leading);addSubview(middle);if let trailing=trailing { addSubview(trailing) }
        addSubview(leftDivider);if trailing != nil { addSubview(rightDivider) }
        leftDivider.setAccessibilityLabel(leftLabel);rightDivider.setAccessibilityLabel("调整参数栏宽度")
        leftDivider.toolTip="左右拖动调整栏宽；宽度会自动记住";rightDivider.toolTip=leftDivider.toolTip
        rightDivider.reversed=true
        leftDivider.onResize={ [weak self] in self?.liveLeft=$0;self?.placePanes() }
        rightDivider.onResize={ [weak self] in self?.liveRight=$0;self?.placePanes() }
        leftDivider.onFinish={ [weak self] width in
            guard let self=self else { return };self.liveLeft=nil
            if let width=width { self.savedLeft=width;self.onLeftCommit?(width) };self.placePanes()
        }
        rightDivider.onFinish={ [weak self] width in
            guard let self=self else { return };self.liveRight=nil
            if let width=width { self.savedRight=width;self.onRightCommit?(width) };self.placePanes()
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(left:Double,right:Double,enabled:Bool) {
        savedLeft=left;savedRight=right;leftDivider.enabled=enabled;rightDivider.enabled=enabled
        needsLayout=true
    }
    override func layout() { super.layout();placePanes() }
    private func placePanes() {
        let handle=8.0, three=trailing != nil, gaps=three ? handle*2 : handle
        let w=bounds.width,h=bounds.height
        let l=min(max(liveLeft ?? savedLeft,leftMinimum),max(leftMinimum,w-gaps-centerMinimum-rightMinimum))
        let r=three ? min(max(liveRight ?? savedRight,rightMinimum),max(rightMinimum,w-l-gaps-centerMinimum)) : 0
        let c=max(0,w-l-r-gaps)
        func place(_ view:NSView,_ x:Double,_ width:Double) {
            let rect=NSRect(x:x,y:0,width:width,height:h)
            if view.frame != rect { view.frame=rect }
        }
        place(leading,0,l);place(leftDivider,l,handle);place(middle,l+handle,c)
        leftDivider.actual=l;leftDivider.minimum=leftMinimum;leftDivider.maximum=max(leftMinimum,w-r-gaps-centerMinimum)
        if let trailing=trailing {
            place(rightDivider,l+handle+c,handle);place(trailing,l+handle+c+handle,r)
            rightDivider.actual=r;rightDivider.minimum=rightMinimum;rightDivider.maximum=max(rightMinimum,w-l-gaps-centerMinimum)
        }
    }
}

final class PaneDivider:NSView {
    var actual=210.0,minimum=170.0,maximum=1000.0
    var reversed=false,enabled=true
    var onResize:((Double)->Void)?
    var onFinish:((Double?)->Void)?
    private var resignObserver:NSObjectProtocol?
    private var drag:(origin:CGFloat,start:Double)?
    override var intrinsicContentSize:NSSize { NSSize(width:8,height:NSView.noIntrinsicMetric) }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.resizeLeftRight) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.windowBackgroundColor.setFill();bounds.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.38).setFill();NSRect(x:bounds.midX-0.5,y:0,width:1,height:bounds.height).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill();NSBezierPath(roundedRect:NSRect(x:bounds.midX-1,y:bounds.midY-10,width:2,height:20),xRadius:1,yRadius:1).fill()
    }
    override func mouseDown(with event:NSEvent) {
        guard enabled else { return }
        endTracking()
        drag=(event.locationInWindow.x,actual)
        if let window=window {
            resignObserver=NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelTracking() }
            }
        }
    }
    private func width(at event:NSEvent)->Double? {
        guard let drag=drag else { return nil }
        return min(max(drag.start+Double(event.locationInWindow.x-drag.origin)*(reversed ? -1 : 1),minimum),maximum)
    }
    override func mouseDragged(with event:NSEvent) {
        if let width=width(at:event) { onResize?(width) }
    }
    override func mouseUp(with event:NSEvent) {
        guard let width=width(at:event),let drag=drag else { return }
        endTracking();onFinish?(width != drag.start ? width : nil)
    }
    private func cancelTracking() {
        guard drag != nil else { return }
        endTracking();onFinish?(nil)
    }
    private func endTracking() {
        drag=nil
        if let token=resignObserver { NotificationCenter.default.removeObserver(token);resignObserver=nil }
    }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
        if newWindow !== window,drag != nil {
            endTracking()
            // Detaching can happen during a SwiftUI update; don't mutate its state in that pass.
            let finish=onFinish
            DispatchQueue.main.async { finish?(nil) }
        }
        super.viewWillMove(toWindow:newWindow)
    }
}
