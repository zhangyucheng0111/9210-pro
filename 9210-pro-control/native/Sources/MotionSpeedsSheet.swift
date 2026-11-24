import SwiftUI

/// Programs and manual operations share the same editor while saving their
/// values in separate scopes.
struct MotionSpeedsSheet:View {
    @ObservedObject var model:AppModel
    let title:String
    let subtitle:String
    let explanation:String
    let scopeNote:String
    let initialValues:[String:ProgramSpeed]
    let saveLabel:String
    let onSave:([String:ProgramSpeed])->Bool
    var programScoped=false
    @Environment(\.dismiss) private var dismiss
    @State private var values:[String:ProgramSpeed]=[:]
    @State private var accelerationDrafts:[String:String]=[:]
    @State private var speedDrafts:[String:String]=[:]
    private var validatedValues:[String:ProgramSpeed]? {
        var snapshot:[String:ProgramSpeed]=[:]
        for type in ProgramSpeed.types {
            guard let value=values[type],(1...10).contains(value.gear),
                  let acceleration=integer(accelerationDrafts[type] ?? ""),
                  let speed=integer(speedDrafts[type] ?? "") else { return nil }
            snapshot[type]=ProgramSpeed(gear:value.gear,acceleration:acceleration,speed:speed)
        }
        return snapshot
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.firstTextBaseline) {
                Text(title).font(StudioTypography.pageTitle)
                Spacer()
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(spacing:0) {
                HStack(spacing:12) { Text("动作").frame(width:110,alignment:.leading);Text("档位").frame(width:88);Text("加速度").frame(width:88);Text("速度").frame(width:88) }
                    .font(StudioTypography.section).foregroundStyle(.primary)
                    .padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Style.tableHeader)
                Divider()
                ForEach(ProgramSpeed.types,id:\.self) { type in
                HStack(spacing:12) {
                    Text(ProgramSpeed.labels[type] ?? type).frame(width:110,alignment:.leading)
                    Picker("档位",selection:Binding(get:{ values[type]?.gear ?? -1 },set:{ gear in
                        do { setDraft(type,setting:try model.workspace.checkedSpeedSetting(type,gear:gear)) }
                        catch { model.error=error.localizedDescription }
                    })) {
                        let gear=values[type]?.gear ?? -1
                        if !(1...10).contains(gear) { Text("请选择").tag(gear) }
                        ForEach(1...10,id:\.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width:88).accessibilityLabel((ProgramSpeed.labels[type] ?? type)+" 档位")
                    ValidatedNumericField("加速度",text:number(type,acceleration:true),rule:.integer(min:0,max:255)).multilineTextAlignment(.trailing).monospacedDigit().frame(width:88)
                        .accessibilityLabel((ProgramSpeed.labels[type] ?? type)+" 加速度")
                    ValidatedNumericField("速度",text:number(type,acceleration:false),rule:.integer(min:0,max:255)).multilineTextAlignment(.trailing).monospacedDigit().frame(width:88)
                        .accessibilityLabel((ProgramSpeed.labels[type] ?? type)+" 速度")
                }.textFieldStyle(.roundedBorder).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                if type != ProgramSpeed.types.last { Divider() }
                }
            }
            .padding(.horizontal,14).padding(.bottom,4)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
            Text("选择档位会读取速度表；数值可细调（0–255，沿用设备单位）。以后修改速度表不会改变这里保存的数值。").font(StudioTypography.caption).foregroundStyle(.secondary)
            Text(scopeNote).font(StudioTypography.caption).foregroundStyle(.secondary)
            Text("卸头参数可编码下发，退头机构的实际调速效果尚未确认；XYZ 移动速度分别设置。").font(StudioTypography.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("使用当前默认值") {
                    do { resetDrafts(try model.workspace.checkedDefaultMotionSpeeds()) }
                    catch { model.error=error.localizedDescription }
                }
                Spacer();Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveLabel) {
                    guard let snapshot=validatedValues else { return }
                    if onSave(snapshot) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(validatedValues==nil)
            }
        }.padding(28).frame(width:580).disabled(programScoped ? model.programEditingLocked : model.manualControlsLocked)
        .onAppear { resetDrafts(initialValues) }
    }
    private func integer(_ text:String)->Int? {
        NumericRule.integer(min:0,max:255).intValue(text)
    }
    private func setDraft(_ type:String,setting:ProgramSpeed) {
        values[type]=setting
        accelerationDrafts[type]=String(setting.acceleration)
        speedDrafts[type]=String(setting.speed)
    }
    private func resetDrafts(_ snapshot:[String:ProgramSpeed]) {
        values=snapshot
        accelerationDrafts=snapshot.mapValues { String($0.acceleration) }
        speedDrafts=snapshot.mapValues { String($0.speed) }
    }
    private func number(_ type:String,acceleration:Bool)->Binding<String> {
        Binding(get:{ acceleration ? accelerationDrafts[type] ?? "" : speedDrafts[type] ?? "" },set:{ text in
            if acceleration { accelerationDrafts[type]=text } else { speedDrafts[type]=text }
        })
    }
}

struct ManualSpeedsSheet:View {
    @ObservedObject var model:AppModel
    var body:some View {
        MotionSpeedsSheet(model:model,title:"手动通用速度",subtitle:"手动操作",
            explanation:"手动页独立保存这套通用速度，插枪头、卸枪头和移液操作使用对应参数，切换台面后继续沿用。",
            scopeNote:"吸液、放液与混匀使用这套 X／Y／Z 及吹样速度；液体吸排速度按各动作所选档位。分段下降吸液使用其面板的专用速度；复位沿用设备速度。",
            initialValues:model.manualMotionSpeeds,saveLabel:"保存到手动操作",
            onSave:{ model.setManualMotionSpeeds($0) })
    }
}
