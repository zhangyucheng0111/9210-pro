import Foundation

extension CompiledStep {
    /// Allow the configured device dwell/shake time in addition to motion and communication overhead.
    /// Speed bytes are vendor units, so this is not an estimate of exact mechanical duration.
    var timeoutSeconds:Double {
        let hover=Double(fields[step.event==3 ? "imbibingHover" : step.event==4 ? "trappingHoverTime" : "mixWellEmptyTime"] ?? 0)/1000
        switch step.event {
        case 5: return 90+Double(step.mixTimes)*(12+hover)
        case 6: return 90+(fields["oscillationSwitch"]==1 ? Double(fields["time"] ?? 0) : 0)
        case 3,4: return 90+hover
        default: return 90
        }
    }
}
