import SwiftUI

/// The manual actions edit their own saved drafts while sharing the program
/// parameter editor and compiler validation. No device action is issued here.
struct ManualLiquidOperationView:View {
    @ObservedObject var model:AppModel
    let event:Int
    private var table:JSONObject { model.workspace.worktable(model.manualControls.tableID) }
    private var plates:[JSONObject] { table.array("WorkTablets") }
    private var range:Int? { try? model.workspace.resolvedTableHeadRange(model.manualControls.tableID) }
    private var raw:Binding<JSONObject> {
        Binding(get:{ model.manualLiquidRaw(event) },set:{ model.setManualLiquidRaw(event,raw:$0) })
    }
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            preview
            Divider()
            StepFields(raw:raw,plates:plates,liquids:model.workspace.tables["LiquidParameters"] as? [JSONObject] ?? [],range:range ?? 20,motionContext:"手动",wellGridMaxWidth:460)
                .disabled(model.manualControlsLocked)
        }.frame(maxWidth:640,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
    }
    private var preview:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("目标与参数检查").font(.system(size:13,weight:.semibold))
            switch model.manualLiquidPreview(event) {
            case .success(let command):
                let plate=plates.first { $0.integer("Number")==command.step.plate } ?? [:]
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text("\(command.step.detail) · \(plate.object("Material").text("Name","未设置耗材"))")
                        .font(StudioTypography.row)
                    Spacer(minLength:8)
                    Text(command.step.displayDose).font(StudioTypography.row).monospacedDigit()
                }
                if command.positionMM.count>=3 {
                    Text("目标 X \(formatNumber(command.positionMM[0]))   Y \(formatNumber(command.positionMM[1]))   Z \(formatNumber(command.positionMM[2])) mm")
                        .font(StudioTypography.metadata).monospacedDigit().foregroundStyle(.secondary)
                }
                let supplement=StepSupplement.text(event:event,raw:command.step.raw)
                if !supplement.isEmpty {
                    Text(supplement).font(StudioTypography.metadata).foregroundStyle(.secondary)
                }
            case .failure(let error):
                Label(error.localizedDescription,systemImage:"exclamationmark.circle")
                    .font(StudioTypography.metadata).foregroundStyle(.red)
            }
        }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
    }
}
