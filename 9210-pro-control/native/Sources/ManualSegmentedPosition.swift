import Foundation

extension Compiler {
    /// Manual aspiration uses the same table/well coordinates and head range as
    /// a persisted program step. The live plunger origin is resolved at runtime.
    func compileManualSegmentedAspiration(_ request:SegmentedAspirationRequest,settings:ManualControlSettings) throws -> CompiledStep {
        let range=try workspace.resolvedTableHeadRange(settings.tableID)
        guard request.range==range else { throw ControlError.invalid("所选板位组合使用 \(range) µL 移液头，请按组合量程设置吸液参数") }
        let table=workspace.worktable(settings.tableID)
        guard let plate=table.array("WorkTablets").first(where:{ $0.integer("Number")==settings.segmentedPlate }) else {
            throw ControlError.invalid("请选择分段吸液板位")
        }
        let material=plate.object("Material")
        let rows=try whole(material,"HoleRow",within:1...48),columns=try whole(material,"HoleColum",within:1...48)
        guard (0..<rows).contains(settings.segmentedRow),(0..<columns).contains(settings.segmentedColumn) else {
            throw ControlError.invalid("分段吸液起始孔位超出所选板位，请重新选择")
        }
        var step=Step.blank(9,plate:settings.segmentedPlate)
        for (key,value) in request.stepParameters { step.raw[key]=value }
        step.raw=WellAddress.set(step.raw,row:settings.segmentedRow,column:settings.segmentedColumn,rows:rows,columns:columns)
        return try compile(step,program:Program.blank(name:"手动分段吸液",range:range,table:settings.tableID))
    }
}
