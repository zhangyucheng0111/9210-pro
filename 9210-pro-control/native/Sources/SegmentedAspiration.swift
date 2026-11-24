import Foundation

/// Software-paced descent followed by aspiration at each small height step.
/// The existing 0003 firmware path is sequential; this is not concurrent motion.
struct SegmentedAspirationRequest {
    /// The large-head speed conversion would put VMAX below the firmware's
    /// fixed VSTART for parameters 1...6. This bound is in device units.
    static func minimumPSpeed(range:Int)->Int { range==1000 ? 7 : 1 }
    var startZMM:Double
    var endZMM:Double
    var volumeUL:Double
    var range:Int
    var liquidID:Int=1
    var liquidType:Int=0
    var segments:Int=20
    var zSpeed:Int=1
    var zAcceleration:Int=1
    var pSpeed:Int=1
    var pAcceleration:Int=1
    var pauseMS:Int=200
}

struct SegmentedAspirationSegment {
    let index:Int
    let bytes:Data
    let fields:[String:Int]
    let start:[Int32]
    let target:[Int32]
    let zDelta:Int
    let pDelta:Int
    func matches(_ positions:[Int32])->Bool { segmentedPositionMatches(positions,target) }
    var saved:JSONObject {
        ["index":index,"hex":bytes.hex,"fields":fields,"start":start.map(Int.init),
         "target":target.map(Int.init),"zDelta":zDelta,"pDelta":pDelta]
    }
}

struct SegmentedAspirationPlan {
    let request:SegmentedAspirationRequest
    let initial:[Int32]
    let start:[Int32]
    /// End of aspiration at the deepest Z; retained separately from the
    /// completed action's raised endpoint so preview depths remain meaningful.
    let target:[Int32]
    let seek:ManualMotionPlan
    let returnToZero:ManualMotionPlan
    let segments:[SegmentedAspirationSegment]
    let zDelta:Int
    let pDelta:Int
    let calibratedVolumeUL:Double
    var summary:String {
        "分段下降吸液 · Z \(formatNumber(request.startZMM)) → \(formatNumber(request.endZMM)) mm · \(formatNumber(request.volumeUL)) µL · \(segments.count) 段 · 每段先下降再吸液，完成后回到 Z 0"
    }
    var finalTarget:[Int32] { returnToZero.target }
    func matchesStart(_ positions:[Int32])->Bool { segmentedPositionMatches(positions,start) }
    func matches(_ positions:[Int32])->Bool { segmentedPositionMatches(positions,target) }
    func matchesFinal(_ positions:[Int32])->Bool { segmentedPositionMatches(positions,finalTarget) }
    var saved:JSONObject {
        ["kind":"segmented-aspiration","executionMeaning":"sequential Z descent then aspiration per segment; not concurrent",
         "startZMM":request.startZMM,"endZMM":request.endZMM,"volumeUL":request.volumeUL,
         "range":request.range,"liquidID":request.liquidID,"liquidType":request.liquidType,
         "segmentCount":request.segments,"zSpeed":request.zSpeed,"zAcceleration":request.zAcceleration,
         "pSpeed":request.pSpeed,"pAcceleration":request.pAcceleration,"pauseMS":request.pauseMS,
         "calibratedVolumeUL":calibratedVolumeUL,"zDelta":zDelta,"pDelta":pDelta,
         "initial":initial.map(Int.init),"start":start.map(Int.init),"target":target.map(Int.init),
         "aspirationTarget":target.map(Int.init),"finalTarget":finalTarget.map(Int.init),
         "seekHex":seek.bytes.hex,"seekZSpeed":48,"seekZAcceleration":16,
         "returnToZeroHex":returnToZero.bytes.hex,"returnZSpeed":48,"returnZAcceleration":16,
         "segments":segments.map(\.saved)]
    }
}

private func segmentedPositionMatches(_ actual:[Int32],_ expected:[Int32])->Bool {
    actual.count==4 && actual.allSatisfy { $0>=0 }
        && (0..<4).allSatisfy { abs(Int64(actual[$0])-Int64(expected[$0]))<=2 }
}

extension ManualCommands {
    /// 0102 acknowledges its final Z leg before the motor is done, and 0103
    /// returns its prefilled target cache. Use the ordinary 0003 state machine
    /// with no liquid/air dose so completion really waits for the motor.
    /// Preserve the vendor's normal positioning speed word (0x1030), separate
    /// from the slow segment settings. XY changes require a prior Z0 movement.
    func segmentedPositioning(_ xyz:[Int],positions:[Int32]) throws -> ManualMotionPlan {
        guard xyz.count==3,positions.count==4,positions.allSatisfy({ $0>=0 }) else {
            throw ControlError.invalid("分段吸液定位需要有效的 X / Y / Z 目标及四轴起点")
        }
        for axis in 0..<3 { try validate(xyz[axis],axis:axis,useConfiguredLimit:false) }
        let z=xyz[2]
        let fields:[String:Int]=[
            "axisType":1,"xPos":xyz[0],"xAccelerationSpeed":16,"xSpeed":48,
            "yPos":xyz[1],"yAccelerationSpeed":16,"ySpeed":48,
            "zImbibingPos":z,"zBottomPos":z,"zBottomOffsetHeight":0,
            "zAccelerationDownSpeed":16,"zDownSpeed":48,
            "frontAirPos":z,"frontAirDosage":0,"imbibingType":0,"imbibingDosage":0,
            "imbibingAccelerationSpeed":16,"imbibingSpeed":48,"imbibingHover":0,
            "imbibingEmptyPos":z,"emptyPosAccSpeed":16,"emptyPosSpeed":48,
            "emptyPosHover":0,"rearEmptyDosage":0,"completedImbibingPos":z,
            "completedImbibingAccelerationSpeed":16,"completedImbibingSpeed":48]
        return ManualMotionPlan(bytes:try compiler.schema.encode("ImbibingBean",fields),
            target:xyz.map(Int32.init)+[positions[3]],axes:[0,1,2,3],waitsForReply:true,
            summary:"分段吸液快速定位 · Z \(formatNumber(positionMM(xyz.map(Int32.init)+[positions[3]])[2])) mm")
    }

    func segmentedAspiration(_ request:SegmentedAspirationRequest,positions:[Int32]) throws -> SegmentedAspirationPlan {
        guard positions.count==4,positions.allSatisfy({ $0>=0 }) else {
            throw ControlError.invalid("请先读取有效的四轴位置，再执行分段下降吸液")
        }
        guard [20,1000].contains(request.range),request.liquidID>0 else {
            throw ControlError.invalid("请选择 20 或 1000 µL 量程及有效液体")
        }
        guard request.startZMM.isFinite,request.endZMM.isFinite,request.startZMM>=0,request.endZMM>request.startZMM else {
            throw ControlError.invalid("结束 Z 必须大于起始 Z，且两者均为非负有限数字")
        }
        guard request.volumeUL.isFinite,request.volumeUL>0,request.volumeUL<=Double(request.range) else {
            throw ControlError.invalid("吸液量必须大于 0 且不超过 \(request.range) µL")
        }
        guard (1...1000).contains(request.segments) else { throw ControlError.invalid("分段数应为 1–1000") }
        guard (0...60000).contains(request.pauseMS) else { throw ControlError.invalid("段间停留应为 0–60000 ms") }
        for (label,value) in [("下降速度",request.zSpeed),("下降加速度",request.zAcceleration),
                              ("吸液速度",request.pSpeed),("吸液加速度",request.pAcceleration)] {
            guard (1...255).contains(value) else { throw ControlError.invalid("\(label)应为 1–255 的设备参数") }
        }
        let minimumPSpeed=SegmentedAspirationRequest.minimumPSpeed(range:request.range)
        guard request.pSpeed>=minimumPSpeed else {
            throw ControlError.invalid("\(request.range) µL 移液头的吸液速度参数最小为 \(minimumPSpeed)：更低值会低于固件固定起速。可增加段间停留来降低平均速度")
        }
        let zStart=try compiler.axis(request.startZMM,"z"),zEnd=try compiler.axis(request.endZMM,"z")
        try validate(zStart,axis:2);try validate(zEnd,axis:2)
        let totalZ=zEnd-zStart
        guard totalZ>0 else { throw ControlError.invalid("下降距离小于一个可编码步数") }
        // Compensation and the affine calibration intercept belong to the
        // complete dose. Divide integer totals, never recalibrate tiny doses.
        let compensated=try compiler.compensated(request.volumeUL,
            raw:["type":request.liquidType,"liquid_id":request.liquidID],range:request.range)
        let totalP=try compiler.volume(compensated,range:request.range,liquid:request.liquidID)
        guard totalP>0 else { throw ControlError.invalid("吸液量换算不足一个柱塞步数") }
        let maximumSegments=min(1000,totalZ,totalP)
        guard request.segments<=maximumSegments else {
            throw ControlError.invalid("分段过多：按当前距离与体积最多可分 \(maximumSegments) 段，每段下降和吸液均须至少一步")
        }
        let pTarget64=Int64(positions[3])+Int64(totalP)
        guard pTarget64<=Int64(Int32.max) else { throw ControlError.invalid("吸液后柱塞目标超出设备坐标编码范围") }
        try validate(Int(pTarget64),axis:3)
        guard pTarget64<Int64(try limitSteps(3)) else {
            throw ControlError.invalid("吸液后柱塞目标到达行程上限，请减小体积或先调整柱塞位置")
        }
        var start=positions;start[2]=Int32(zStart)
        var target=start;target[2]=Int32(zEnd);target[3]=Int32(pTarget64)
        // Always establish a motor-completed starting point, even when the
        // cached Z already equals it after an earlier 0102 command.
        let seek=try segmentedPositioning(start.prefix(3).map(Int.init),positions:positions)
        let returnToZero=try segmentedPositioning([Int(target[0]),Int(target[1]),0],positions:target)
        let xAcc=try compiler.whole(compiler.config,"xAccSpeed",within:0...255)
        let xSpeed=try compiler.whole(compiler.config,"xSpeed",within:1...255)
        let yAcc=try compiler.whole(compiler.config,"yAccSpeed",within:0...255)
        let ySpeed=try compiler.whole(compiler.config,"ySpeed",within:1...255)
        var segments:[SegmentedAspirationSegment]=[],previous=start
        var previousZ=0,previousP=0
        for index in 1...request.segments {
            let cumulativeZ=Int(Int64(totalZ)*Int64(index)/Int64(request.segments))
            let cumulativeP=Int(Int64(totalP)*Int64(index)/Int64(request.segments))
            let z=zStart+cumulativeZ,p=Int(positions[3])+cumulativeP
            let zIncrement=cumulativeZ-previousZ,pIncrement=cumulativeP-previousP
            guard zIncrement>0,pIncrement>0 else { throw ControlError.invalid("分段后出现零行程，未生成动作") }
            var next=start;next[2]=Int32(z);next[3]=Int32(p)
            // completedImbibingPos=0 does not disable firmware retraction.
            // Keep all optional Z destinations at this segment's depth.
            let fields:[String:Int]=[
                "axisType":1,"xPos":Int(start[0]),"xAccelerationSpeed":xAcc,"xSpeed":xSpeed,
                "yPos":Int(start[1]),"yAccelerationSpeed":yAcc,"ySpeed":ySpeed,
                "zImbibingPos":z,"zBottomPos":z,"zBottomOffsetHeight":0,
                "zAccelerationDownSpeed":request.zAcceleration,"zDownSpeed":request.zSpeed,
                "frontAirPos":z,"frontAirDosage":0,"imbibingType":0,"imbibingDosage":pIncrement,
                "imbibingAccelerationSpeed":request.pAcceleration,"imbibingSpeed":request.pSpeed,
                "imbibingHover":0,"imbibingEmptyPos":z,"emptyPosAccSpeed":request.zAcceleration,
                "emptyPosSpeed":request.zSpeed,"emptyPosHover":0,"rearEmptyDosage":0,
                "completedImbibingPos":z,"completedImbibingAccelerationSpeed":request.zAcceleration,
                "completedImbibingSpeed":request.zSpeed]
            segments.append(SegmentedAspirationSegment(index:index,bytes:try compiler.schema.encode("ImbibingBean",fields),
                fields:fields,start:previous,target:next,zDelta:zIncrement,pDelta:pIncrement))
            previous=next;previousZ=cumulativeZ;previousP=cumulativeP
        }
        return SegmentedAspirationPlan(request:request,initial:positions,start:start,target:target,seek:seek,returnToZero:returnToZero,
            segments:segments,zDelta:totalZ,pDelta:totalP,calibratedVolumeUL:compensated)
    }
}

/// Acknowledgement plus four-axis readback owns each segment. A failure or
/// cancellation escapes immediately, without resending or advancing a segment.
@MainActor struct SegmentedAspirationExecutor {
    var requestCompletion:(Data) async throws -> Void
    var readPositions:() async throws -> [Int32]
    var pause:(Int) async throws -> Void = { milliseconds in
        try await Task.sleep(nanoseconds:UInt64(milliseconds)*1_000_000)
    }
    var onProgress:(Int,Int,[Int32])->Void = { _,_,_ in }
    var onReturnToZero:()->Void = {}

    func execute(_ plan:SegmentedAspirationPlan) async throws -> [Int32] {
        try Task.checkCancellation()
        try await requestCompletion(plan.seek.bytes)
        try Task.checkCancellation()
        let start=try await readPositions()
        try Task.checkCancellation()
        guard plan.matchesStart(start) else {
            throw ControlError.invalid("分段吸液起点不符：目标 \(plan.start)，回报 \(start)。未发送吸液")
        }
        var latest=start
        for segment in plan.segments {
            try Task.checkCancellation()
            try await requestCompletion(segment.bytes)
            try Task.checkCancellation()
            latest=try await readPositions()
            try Task.checkCancellation()
            guard segment.matches(latest) else {
                throw ControlError.invalid("分段吸液第 \(segment.index) 段终点不符：目标 \(segment.target)，回报 \(latest)。未继续后续段")
            }
            onProgress(segment.index,plan.segments.count,latest)
            try Task.checkCancellation()
            if segment.index<plan.segments.count,plan.request.pauseMS>0 {
                try await pause(plan.request.pauseMS)
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        onReturnToZero()
        try Task.checkCancellation()
        try await requestCompletion(plan.returnToZero.bytes)
        try Task.checkCancellation()
        latest=try await readPositions()
        try Task.checkCancellation()
        guard plan.matchesFinal(latest) else {
            throw ControlError.invalid("分段吸液完成后回到 Z 0 的位置不符：目标 \(plan.finalTarget)，回报 \(latest)。未报告操作完成")
        }
        return latest
    }
}
