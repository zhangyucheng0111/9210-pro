import Foundation

extension SegmentedAspirationRequest {
    static func parse(_ raw:JSONObject,range:Int,compiler:Compiler) throws -> Self {
        Self(startZMM:try compiler.finite(raw.text("start_z"),label:"起始 Z"),
             endZMM:try compiler.finite(raw.text("end_z"),label:"结束 Z"),
             volumeUL:try compiler.finite(raw.text("dose"),label:"吸液量"),range:range,
             liquidID:try compiler.whole(raw,"liquid_id",within:1...Int(Int32.max)),
             liquidType:raw["type"] == nil ? 0 : try compiler.whole(raw,"type",within:Int(Int32.min)...Int(Int32.max)),
             segments:try compiler.whole(raw,"segments",within:1...1000),
             zSpeed:try compiler.whole(raw,"z_speed",within:1...255),
             zAcceleration:try compiler.whole(raw,"z_acc",within:1...255),
             pSpeed:try compiler.whole(raw,"p_speed",within:1...255),
             pAcceleration:try compiler.whole(raw,"p_acc",within:1...255),
             pauseMS:try compiler.whole(raw,"pause_ms",within:0...60000))
    }
    var stepParameters:JSONObject {
        ["start_z":startZMM,"end_z":endZMM,"dose":volumeUL,"liquid_id":liquidID,"type":liquidType,
         "segments":segments,"z_speed":zSpeed,"z_acc":zAcceleration,"p_speed":pSpeed,"p_acc":pAcceleration,"pause_ms":pauseMS]
    }
}

extension Compiler {
    func compileSegmentedAspiration(_ step:Step,program:Program) throws -> CompiledStep {
        if let value=step.raw["auxiliary_functions"],!(value is [JSONObject]) { throw ControlError.invalid("辅助段清单格式错误") }
        guard step.raw.array("auxiliary_functions").isEmpty else { throw ControlError.invalid("分段下降吸液不支持辅助段") }
        let request=try SegmentedAspirationRequest.parse(step.raw,range:program.range,compiler:self)
        // Reuse the original table/well algorithm and its validation, while the
        // program stores a host-side action rather than an invented device code.
        var coordinateStep=step
        coordinateStep.raw["event_type"]=3;coordinateStep.raw["speed"]=1
        coordinateStep.raw["raise_height"]=0;coordinateStep.raw["z_customized_pos"]=request.startZMM
        coordinateStep.raw["auxiliary_functions"]=[]
        let coordinate=try compile(coordinateStep,program:program)
        let x=coordinate.fields["xPos"]!,y=coordinate.fields["yPos"]!
        let plan=try ManualCommands(compiler:self).segmentedAspiration(request,positions:[Int32(x),Int32(y),0,0])
        var fields=coordinate.fields
        fields["startZSteps"]=Int(plan.start[2]);fields["endZSteps"]=Int(plan.target[2])
        fields["segmentCount"]=request.segments;fields["zDownSpeed"]=request.zSpeed
        fields["imbibingSpeed"]=request.pSpeed;fields["imbibingDosage"]=plan.pDelta
        return CompiledStep(id:step.id,step:step,bytes:nil,fields:fields,positionMM:[coordinate.positionMM[0],coordinate.positionMM[1],request.startZMM,request.endZMM])
    }
}
