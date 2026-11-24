import Foundation

extension Compiler {
    /// Compile exactly one normal liquid step with the manual page's table and
    /// motion-speed snapshot. Liquid speeds, compensation and auxiliaries use
    /// the ordinary program compiler and its existing validation unchanged.
    func compileManualLiquid(event:Int,raw:JSONObject,settings:ManualControlSettings) throws -> CompiledStep {
        guard [3,4,5].contains(event) else { throw ControlError.invalid("手动液体操作仅支持吸液、放液或混匀") }
        guard try whole(raw,"event_type",within:3...5)==event else {
            throw ControlError.invalid("手动液体参数与当前动作类型不一致")
        }
        let range=try workspace.resolvedTableHeadRange(settings.tableID)
        var program=Program.blank(name:"手动"+(Step.actionNames[event] ?? "液体操作"),range:range,table:settings.tableID)
        var types=["XSpeed","YSpeed","ZSpeed"]
        if raw.array("auxiliary_functions").contains(where:{ exactIntegerValue($0.text("id"))==4 && $0.number("mDose",.nan)>0 }) {
            types.append("BlowSpeed")
        }
        program.motionSpeeds=try settings.resolvedMotionSpeeds(workspace:workspace,types:types)
        let step=Step(id:UUID().uuidString,raw:raw,sourceIndex:0)
        let compiled=try compile(step,program:program)
        if event==5,(compiled.fields["blowSampleDosage"] ?? 0)>0,(compiled.fields["afterMixImbibingDosage"] ?? 0)>0 {
            throw ControlError.invalid("混匀后吸液与吹样不能同时执行，请关闭吹样或将其拆为独立放液步骤。")
        }
        return compiled
    }
}
