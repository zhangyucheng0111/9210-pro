import SwiftUI

/// Text bindings preserve `1.`, `-` and an empty field while editing. Invalid
/// text stays visible; callers validate the same rule before saving or running.
struct ValidatedNumericField:View {
    let title:String
    @Binding var text:String
    let rule:NumericRule
    init(_ title:String,text:Binding<String>,rule:NumericRule) {
        self.title=title;self._text=text;self.rule=rule
    }
    var body:some View {
        TextField(title,text:$text)
            .studioInput()
            .overlay(RoundedRectangle(cornerRadius:5).stroke(rule.isValid(text) ? Color.clear : Color.red.opacity(0.8),lineWidth:1))
            .frame(idealWidth:112,maxWidth:160)
            .help(rule.hint)
            .accessibilityLabel(title)
            .accessibilityValue(text)
            .accessibilityHint(rule.isValid(text) ? rule.hint : "输入无效："+rule.hint)
    }
}
