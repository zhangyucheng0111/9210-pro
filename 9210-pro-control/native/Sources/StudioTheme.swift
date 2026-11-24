import SwiftUI

// Native light surfaces and semantic system colors. Data uses monospaced digits;
// labels and controls retain the macOS system font and accessibility behavior.
enum Style {
    static let ink=Color.primary
    static let blue=Color.blue
    static let canvas=Color(nsColor:.windowBackgroundColor)
    static let surface=Color(nsColor:.controlBackgroundColor)
    static let line=Color(nsColor:.separatorColor)
    static let muted=Color.secondary
    static let fieldBorder=Color.secondary.opacity(0.4)
    static let rowSurface=Color.primary.opacity(0.025)
    static let tableHeader=Color.primary.opacity(0.06)
    static func title(_ size:CGFloat)->Font { .system(size:size,weight:.semibold) }
}

enum StudioTypography {
    static let pageTitle=Font.system(size:20,weight:.semibold)
    static let paneTitle=Font.system(size:17,weight:.semibold)
    static let section=Font.system(size:12,weight:.semibold)
    static let body=Font.system(size:13)
    static let row=Font.system(size:13,weight:.medium)
    static let metadata=Font.system(size:12)
    static let caption=Font.system(size:11)
}

struct StudioGroupBoxStyle:GroupBoxStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:12) {
            configuration.label.font(.system(size:13,weight:.semibold))
            configuration.content.frame(maxWidth:.infinity,alignment:.leading)
        }
        .padding(16)
        .background(Style.surface,in:RoundedRectangle(cornerRadius:12))
    }
}

struct StudioSectionTitle:View {
    let title:String
    var body:some View { Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(Style.ink).frame(maxWidth:.infinity,alignment:.leading).padding(.top,8) }
}

struct StudioActionSymbol:View {
    let event:Int
    var name:String {
        [1:"arrow.down.to.line",2:"arrow.up.from.line",3:"arrow.up",4:"arrow.down",5:"arrow.up.arrow.down",6:"waveform",7:"clock",8:"repeat",9:"arrow.down.right"][event] ?? "circle"
    }
    var body:some View { Image(systemName:name).font(.system(size:12,weight:.medium)).frame(width:20).accessibilityHidden(true) }
}

struct ContextSaveControls:View {
    @ObservedObject var model:AppModel
    let title:String
    var programScoped=false
    var body:some View {
        VStack(alignment:.trailing,spacing:4) {
            Button(title) { model.save() }.disabled(programScoped ? model.programEditingLocked : model.manualControlsLocked)
            Text(model.saveStatus).font(StudioTypography.caption).foregroundStyle(.secondary)
                .lineLimit(1).accessibilityLabel("保存状态："+model.saveStatus)
        }.fixedSize()
    }
}

extension View {
    func studioInput(width:CGFloat?=nil)->some View {
        modifier(StudioInputModifier(width:width))
    }
    func studioParameterRow()->some View {
        self.padding(.horizontal,10).padding(.vertical,6)
            .frame(minHeight:40)
            .background(Style.rowSurface,in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(Style.line.opacity(0.7),lineWidth:1))
    }
    @ViewBuilder func studioMetadata(selected:Bool)->some View {
        if selected { self } else { self.foregroundStyle(.secondary) }
    }
}

private struct StudioInputModifier:ViewModifier {
    let width:CGFloat?
    @FocusState private var focused:Bool
    func body(content:Content)->some View {
        content.textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal,8).padding(.vertical,5)
            .frame(minHeight:28)
            .background(Style.surface,in:RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).strokeBorder(focused ? Style.blue : Style.fieldBorder,lineWidth:focused ? 2 : 1))
            .frame(width:width)
    }
}
