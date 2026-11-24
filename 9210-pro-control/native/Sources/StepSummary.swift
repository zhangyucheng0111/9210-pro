import Foundation

// A read-only projection for the sequence list. These are configured amounts,
// not calibrated strokes or a prediction of the physical liquid volume.
enum StepSupplement {
    static func text(event:Int,raw:[String:Any])->String {
        var parts:[String]=[]
        if event==5 {
            if let count=number(raw["mix_times"]),(1...255).contains(count),count.rounded(.towardZero)==count { parts.append("\(format(count)) 次") }
            else { parts.append("次数待完善") }
            let after=number(raw["dose_after_mix"] ?? "0")
            let compensation=number(raw["compensate"] ?? "0")
            if let after=after,after>=0,let compensation=compensation {
                if after>0 || compensation != 0 {
                    parts.append("混后吸液 \(format(after)) µL")
                    if compensation != 0 { parts.append("混后补偿 \(compensation>0 ? "+" : "")\(format(compensation)) µL") }
                }
            } else { parts.append("混后吸待完善") }
        }
        let supported:[Int:Set<Int>]=[1:[5],2:[5],3:[1,2,3,5],4:[1,3,4,5,6,7,8,9],5:[1,2,3,4,5]]
        let assists=raw["auxiliary_functions"] as? [[String:Any]] ?? []
        // Mixing keeps its repetitions and post-mix liquid dose first. Air,
        // blowout and positioning aids follow in decreasing review priority.
        for id in [2,3,4,1,5,6,7,8,9] where supported[event]?.contains(id)==true {
            for assist in assists where number(assist["id"])==Double(id) {
                let label=[1:"悬停",2:"前吸",3:"后吸",4:"吹样",5:"完成后抬升",6:"靠左壁",7:"靠右壁",8:"贴左壁",9:"贴右壁"][id]!
                if id>=5 { parts.append(label);continue }
                guard let amount=number(assist["mDose"] ?? "0"),amount>=0 else { parts.append(label+"待完善");continue }
                if amount>0 { parts.append("\(label) \(format(amount)) \(id==1 ? "秒" : "µL")") }
            }
        }
        if event==4 {
            if let compensation=number(raw["compensate"] ?? "0") {
                if compensation != 0 { parts.append("补偿 \(compensation>0 ? "+" : "")\(format(compensation)) µL") }
            } else { parts.append("补偿待完善") }
        }
        return parts.joined(separator:" · ")
    }
    private static func number(_ value:Any?)->Double? {
        guard let value=value,!(value is NSNull),let result=Double(value as? String ?? String(describing:value)),result.isFinite else { return nil }
        return result
    }
    private static func format(_ value:Double)->String { String(format:"%g",value) }
}
