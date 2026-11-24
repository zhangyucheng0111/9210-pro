import Foundation

/// The cancellation handler may run off the main actor while a delayed drain
/// is already queued there. Mark cancellation synchronously, and serialize the
/// final permission check with the brief CoreBluetooth write call itself.
final class TransferCancellationToken:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    var isCancelled:Bool {
        lock.lock();defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock();defer { lock.unlock() }
        cancelled=true
    }
    @discardableResult func performUnlessCancelled(_ operation:()->Void)->Bool {
        lock.lock();defer { lock.unlock() }
        guard !cancelled else { return false }
        operation()
        return true
    }
}

/// Android .32 uses MTU-3 (MTU=200) and a 100 ms queue interval.
/// Never split a command into arbitrary 20-byte writes when the link supports a whole frame.
struct TransferPolicy {
    static let androidPayloadLimit=197
    static let intervalNanoseconds:UInt64=100_000_000
    static let experimentalIntervalsNanoseconds:Set<UInt64>=[20_000_000,50_000_000,100_000_000]
    static func chunks(_ bytes:Data,maximum:Int,limit:Int=androidPayloadLimit) -> [Data] {
        let size=max(1,min(maximum,limit))
        return stride(from:0,to:bytes.count,by:size).map { Data(bytes[$0..<min($0+size,bytes.count)]) }
    }
    static func prefersWithoutResponse(canWrite:Bool,canWriteWithoutResponse:Bool) -> Bool { canWriteWithoutResponse }
    static func experimentFramesFit(_ frames:[Data],maximum:Int,limit:Int=androidPayloadLimit)->Bool {
        let effective=min(maximum,limit,androidPayloadLimit)
        return !frames.isEmpty && effective>0 && frames.allSatisfy { !$0.isEmpty && $0.count<=effective }
    }
}

enum ReplyDecision:Equatable { case unrelated, busy, complete, failed(UInt8) }
struct ReplyMatcher {
    let code:UInt16
    let step:UInt32
    init(sent:WireFrame) { code=sent.code|0x8000;step=sent.step }
    func evaluate(_ reply:WireFrame) -> ReplyDecision {
        guard reply.incoming,reply.code == code else { return .unrelated }
        // Historical firmware emits step=0 for position queries (453 frames) and some reset replies.
        // Action completion frames still require the transmitted step; do not broaden that match.
        let zeroSequence=reply.step==0 && [UInt16(0x8101),0x8103,0x8105].contains(code)
        guard reply.step == step || zeroSequence else { return .unrelated }
        if let status=reply.status { return status == 0 ? .complete : status == 1 ? .busy : .failed(status) }
        return .complete
    }
}

/// JSON serialization and file IO are serialized off the UI thread.
final class FileWriter {
    private let queue=DispatchQueue(label:"9210.workspace.writer",qos:.utility)
    func write(_ object:JSONObject,to url:URL,completion:((Error?)->Void)?=nil) {
        queue.async {
            do { try self.performWrite(object,to:url);completion?(nil) }
            catch { completion?(error) }
        }
    }
    func writeAndWait(_ object:JSONObject,to url:URL) throws { try queue.sync { try performWrite(object,to:url) } }
    private func performWrite(_ object:JSONObject,to url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed]).write(to:url,options:.atomic)
    }
    func append(_ object:JSONObject,to url:URL,onError:((Error)->Void)?=nil) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                var data=try JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed]);data.append(10)
                if !FileManager.default.fileExists(atPath:url.path) { guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw ControlError.invalid("无法创建通信记录") } }
                let h=try FileHandle(forWritingTo:url);defer { try? h.close() };try h.seekToEnd();try h.write(contentsOf:data)
            } catch { onError?(error) }
        }
    }
}
