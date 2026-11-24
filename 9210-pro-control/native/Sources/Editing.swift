import Foundation

extension Step {
    static let actionNames = [1:"装头",2:"卸头",3:"吸液",4:"排液",5:"混匀",6:"震荡",7:"等待",9:"分段下降吸液"]
    static func blank(_ event: Int, plate: Int = 2) -> Step {
        Step(id:UUID().uuidString,raw:[
            "event_type":event,"wait_time":10,"plate_number":event == 1 ? 1 : event == 2 ? 8 : plate,
            "liquid_id":1,"liquid_type":"水","dose":"1","compensate":"0","raise_height":0,
            "auxiliary_functions":[],"x_axis":0,"y_axis":0,"holeId":0,"hole_id_list":[],
            "mix_times":3,"mix_imb_speed":3,"mix_trap_speed":3,"speed":3,"dose_after_mix":0,
            "z_customized_pos":"","type":0,"module_number":1,"oscillation_switch":1,
            "oscillation_time":10,"oscillation_frequency":300,"status":0,"solution_detail_id":0,
            "start_z":"","end_z":"","segments":20,"z_speed":1,"z_acc":1,"p_speed":1,"p_acc":1,"pause_ms":200
        ],sourceIndex:-1)
    }
    func copied() -> Step { Step(id:UUID().uuidString,raw:raw,sourceIndex:sourceIndex) }
}

extension Program {
    static func blank(name: String = "新程序", range: Int = 20, table: Int = 8) -> Program {
        let id=UUID().uuidString
        return Program(id:id,name:name,range:range,worktableID:table,steps:[],
                       raw:["solutionId":id,"name":name,"range":range,"worktable_id":table],origin:"Mac 自由程序")
    }
    mutating func insert(_ step: Step, after id: String?) {
        let index=id.flatMap { id in steps.firstIndex { $0.id == id } }.map { $0+1 } ?? steps.count
        steps.insert(step,at:index);orderConfirmed=false
    }
    mutating func group(from: Int, to: Int, count: Int) throws -> String {
        guard from >= 1, to >= from, to <= steps.count, (1...1000).contains(count) else { throw ControlError.invalid("检查循环起止步骤和次数") }
        let children=Array(steps[(from-1)..<to])
        guard !children.contains(where:{ $0.event == 8 }) else { throw ControlError.invalid("当前支持单层循环；可先解组再重新组合") }
        guard children.count <= 10000/count else { throw ControlError.invalid("循环展开后不能超过 10,000 步") }
        let loop=Step(id:UUID().uuidString,raw:["event_type":8,"loop_count":count,"loop_steps":children.map(\.raw)],sourceIndex:-1)
        steps.replaceSubrange((from-1)..<to,with:[loop]);orderConfirmed=false
        return loop.id
    }
    mutating func ungroup(_ id: String) {
        guard let i=steps.firstIndex(where:{ $0.id == id }), steps[i].event == 8 else { return }
        let children=steps[i].raw.array("loop_steps").map { Step(id:UUID().uuidString,raw:$0,sourceIndex:steps[i].sourceIndex) }
        steps.replaceSubrange(i...i,with:children);orderConfirmed=false
    }
}
