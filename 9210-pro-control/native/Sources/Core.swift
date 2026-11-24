import Foundation
import CryptoKit

typealias JSONObject = [String: Any]
enum ControlError: LocalizedError {
    case invalid(String)
    case stopped
    var errorDescription: String? { if case .invalid(let s) = self { return s };return "运行已停止" }
}
/// Parse whole numbers without truncating decimals or rounding through Double.
func exactIntegerValue(_ text:String)->Int? {
    let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
    var bytes=Array(text.utf8),negative=false
    if bytes.first==43 || bytes.first==45 { negative=bytes.removeFirst()==45 }
    guard !bytes.isEmpty else { return nil }
    let exponentIndex=bytes.firstIndex { $0==69 || $0==101 }
    let mantissa=Array(bytes[..<(exponentIndex ?? bytes.count)])
    var exponent=0
    if let index=exponentIndex {
        guard let value=Int(String(decoding:bytes[(index+1)...],as:UTF8.self)),(-10000...10000).contains(value) else { return nil }
        exponent=value
    }
    var digits:[UInt8]=[],fractionalDigits=0,hasPoint=false
    for byte in mantissa {
        if byte==46,!hasPoint { hasPoint=true;continue }
        guard (48...57).contains(byte) else { return nil }
        digits.append(byte);if hasPoint { fractionalDigits+=1 }
    }
    guard !digits.isEmpty else { return nil }
    guard let firstNonzero=digits.firstIndex(where:{ $0 != 48 }) else { return 0 }
    digits=Array(digits[firstNonzero...])
    let scale=exponent-fractionalDigits
    if scale<0 {
        guard -scale<digits.count,digits.suffix(-scale).allSatisfy({ $0==48 }) else { return nil }
        digits.removeLast(-scale)
    } else {
        guard digits.count<=19,scale<=19-digits.count else { return nil }
        digits += repeatElement(UInt8(48),count:scale)
    }
    return Int((negative ? "-" : "")+String(decoding:digits,as:UTF8.self))
}
extension Dictionary where Key == String, Value == Any {
    func text(_ key: String, _ fallback: String = "") -> String {
        guard let x = self[key], !(x is NSNull) else { return fallback }
        return x as? String ?? String(describing: x)
    }
    func number(_ key: String, _ fallback: Double = 0) -> Double { Double(text(key)) ?? fallback }
    func integer(_ key: String, _ fallback: Int = 0) -> Int {
        guard let n=exactIntegerValue(text(key)),n>=Int(Int32.min),n<=Int(Int32.max) else { return fallback }
        return n
    }
    func array(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
    func object(_ key: String) -> JSONObject { self[key] as? JSONObject ?? [:] }
}
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) }
func jsonObject(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
func fingerprint(_ value: Any) throws -> String { SHA256.hash(data: try jsonData(value)).map { String(format: "%02x", $0) }.joined() }
func pretty(_ value: Any) -> String { (try? String(data: jsonData(value), encoding: .utf8)) ?? "{}" }
func formatNumber(_ n: Double) -> String { String(format: "%g", n) }

/// The editor keeps the original text (including unfinished decimals) and only
/// produces a value after the complete input passes its field's numeric rule.
enum NumericRule {
    case integer(min:Int? = nil,max:Int? = nil,allowEmpty:Bool = false)
    case decimal(min:Double? = nil,max:Double? = nil,allowEmpty:Bool = false)

    func value(_ text:String)->Double? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch self {
        case let .integer(minimum,maximum,_):
            guard let exact=exactIntegerValue(text),minimum.map({ exact >= $0 }) ?? true,
                  maximum.map({ exact <= $0 }) ?? true else { return nil }
            return Double(exact)
        case let .decimal(minimum,maximum,_):
            guard let number=Double(text),number.isFinite,
                  minimum.map({ number >= $0 }) ?? true,maximum.map({ number <= $0 }) ?? true else { return nil }
            return number
        }
    }
    func intValue(_ text:String)->Int? {
        guard isValid(text) else { return nil }
        return exactIntegerValue(text)
    }
    func isValid(_ text:String)->Bool {
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            switch self { case let .integer(_,_,allowEmpty),let .decimal(_,_,allowEmpty):return allowEmpty }
        }
        return value(text) != nil
    }
    var hint:String {
        let kind:String,lower:String?,upper:String?,optional:Bool
        switch self {
        case let .integer(minimum,maximum,allowEmpty):
            kind="整数";lower=minimum.map(String.init);upper=maximum.map(String.init);optional=allowEmpty
        case let .decimal(minimum,maximum,allowEmpty):
            kind=minimum==Double.leastNonzeroMagnitude ? "大于 0 的数字，可填小数" : "数字，可填小数"
            lower=minimum==Double.leastNonzeroMagnitude ? nil : minimum.map(formatNumber);upper=maximum.map(formatNumber);optional=allowEmpty
        }
        var result=kind
        if let lower=lower,let upper=upper { result += "（\(lower)–\(upper)）" }
        else if let lower=lower { result += "（≥ \(lower)）" }
        else if let upper=upper { result += "（≤ \(upper)）" }
        if optional { result += "；可留空" }
        return result
    }
}

enum NumericRules {
    static func step(key:String)->NumericRule {
        switch key {
        case "mix_times":return .integer(min:1,max:255)
        case "segments":return .integer(min:1,max:1000)
        case "z_speed","z_acc","p_speed","p_acc":return .integer(min:1,max:255)
        case "pause_ms":return .integer(min:0,max:60000)
        case "module_number":return .integer(min:0,max:255)
        case "oscillation_time","oscillation_frequency":return .integer(min:0,max:65535)
        case "wait_time":return .decimal(min:0,max:86400)
        case "dose":return .decimal(min:Double.leastNonzeroMagnitude)
        case "z_customized_pos":return .decimal(min:0,allowEmpty:true)
        case "compensate":return .decimal()
        default:return .decimal(min:0)
        }
    }
    static func parameter(key:String)->NumericRule? {
        if ["HoleRow","HoleColum"].contains(key) { return .integer(min:1,max:48) }
        if key=="ChannelNum" { return .integer(min:1,max:Int(Int32.max)) }
        if ["id","curve_id","liquid_id","liquid_compensation_id","consumable_id","range","module","SupplyType"].contains(key) { return .integer(min:1,max:Int(Int32.max)) }
        if key=="nature" { return .integer(min:0,max:1) }
        if ["type","trapping_type"].contains(key) { return .integer(min:Int(Int32.min),max:Int(Int32.max)) }
        if ["shockPlate","trapPlate","unLoadPlate"].contains(key) { return .integer(min:0,max:48) }
        if key=="shockModuleNumber" { return .integer(min:0,max:255) }
        if key.hasSuffix("Gear") { return .integer(min:1,max:10) }
        if key.hasSuffix("Speed") || key=="accSpeed" || key=="speed" { return .integer(min:0,max:255) }
        if key.hasSuffix("Coefficient") || key.hasSuffix("ScrewPitch") || key=="imbProportion" { return .decimal(min:Double.leastNonzeroMagnitude) }
        if ["parameter1","parameter2","XOffset","YOffset"].contains(key) { return .decimal() }
        if key.hasSuffix("FixedStep") { return .decimal(min:Double.leastNonzeroMagnitude) }
        if ["XPos","YPos","ZPos","ZGradientPos","ImbPos","AgainstZ","AgainstXLeft","AgainstXRight","AdherentZ","AdherentXLeft","AdherentXRight","Volume","XSpacing","YSpacing","HoleDiameter","WellDiameter","LengthNum","WidthNum","HeightNum","DepthNum","StandardHeight","start_imbibing","end_imbibing","compensation","loadSecondSpacing","unLoadSpacing","imbZero"].contains(key) || key.hasSuffix("LimitPos") { return .decimal(min:0) }
        return nil
    }
}

extension Data {
    init(hex: String) throws {
        let s = hex.filter { !$0.isWhitespace }
        guard s.count % 2 == 0 else { throw ControlError.invalid("十六进制字节长度错误") }
        var data = Data(); var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<end], radix: 16) else { throw ControlError.invalid("无效的十六进制字节") }
            data.append(byte); index = end
        }
        self = data
    }
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct WireFrame {
    let data: Data
    let code: UInt16
    let payload: [UInt8]
    let step: UInt32
    let incoming: Bool
    var status: UInt8? { Wire.statusCodes.contains(code) ? payload.first : nil }
    var positions: [Int32]? {
        guard code == 0x8103, payload.count == 17 else { return nil }
        return stride(from: 1, to: 17, by: 4).map { i in Int32(bitPattern: Wire.u32(payload, i)) }
    }
}
enum Wire {
    static let statusCodes: Set<UInt16> = [0x8001,0x8002,0x8003,0x8004,0x8005,0x8009,0x8010,0x8100,0x8101,0x8102]
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i+1]) }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3]) }
    static func integer(_ n: Int, width: Int) throws -> [UInt8] {
        let min = width == 4 ? Int(Int32.min) : 0
        let max = width == 4 ? Int(UInt32.max) : (1 << (width * 8)) - 1
        guard n >= min, n <= max else { throw ControlError.invalid("字段值 \(n) 超出 \(width) 字节范围") }
        let v = UInt32(truncatingIfNeeded: n)
        return (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }
    }
    static func frame(payload: [UInt8], module: UInt8 = 1) throws -> Data {
        guard payload.count >= 2, payload.count < 4000 else { throw ControlError.invalid("命令载荷长度错误") }
        let body: [UInt8] = [0,0xA2,0,0,0,1,module,0,0,0,1] + payload
        var b: [UInt8] = [0x5A,0x58] + (try integer(body.count + 3, width: 2)) + body
        b.append(0 &- b.reduce(UInt8(0), &+)); b += [13,10]
        return Data(b)
    }
    static func query(_ position: Bool) -> Data { try! frame(payload: position ? [1,3,1] : [1,5]) }
    static func decode(_ data: Data) throws -> WireFrame {
        let b = Array(data)
        guard b.count >= 20, Array(b.prefix(2)) == [0x5A,0x58], Array(b.suffix(2)) == [13,10] else { throw ControlError.invalid("帧头／帧尾错误") }
        let code = u16(b,15); let incoming = code & 0x8000 != 0
        guard code != 0x810D, code != 0x810E else { throw ControlError.invalid("升级维护流量独立保留，不进入动作解析") }
        let declared = Int(u16(b,2))
        guard declared == b.count - (incoming ? 19 : 4) else { throw ControlError.invalid("帧长度字段错误") }
        guard b.dropLast(2).reduce(UInt8(0), &+) == 0 else { throw ControlError.invalid("帧校验错误") }
        let payload = Array(b[17..<(b.count-3)])
        if statusCodes.contains(code), payload.count != 1 { throw ControlError.invalid("状态回包长度错误") }
        if code == 0x8103, payload.count != 17 { throw ControlError.invalid("位置回包长度错误") }
        if code == 0x8105, payload.count != 10 { throw ControlError.invalid("设备信息回包长度错误") }
        return WireFrame(data: data, code: code, payload: payload, step: u32(b,11), incoming: incoming)
    }
}

final class WireStream {
    private(set) var buffer: [UInt8] = []
    private(set) var rejected = 0
    func reset() { buffer.removeAll(); rejected = 0 }
    func feed(_ data: Data) -> [WireFrame] {
        buffer += data; var frames: [WireFrame] = []
        while buffer.count >= 2 {
            if buffer[0] != 0x5A || buffer[1] != 0x58 { buffer.removeFirst(); continue }
            if buffer.count < 17 { break }
            let declared = Int(Wire.u16(buffer,2)); let code = Wire.u16(buffer,15)
            let incoming = code & 0x8000 != 0
            let length = declared + (incoming ? 19 : 4)
            let badKnown = incoming && ((Wire.statusCodes.contains(code) && declared != 2) || (code == 0x8103 && declared != 18) || (code == 0x8105 && declared != 11))
            if length < 20 || length > 4096 || badKnown || code == 0x810D || code == 0x810E {
                rejected += 1; buffer.removeFirst(); continue
            }
            if buffer.count < length { break }
            do {
                frames.append(try Wire.decode(Data(buffer.prefix(length)))); buffer.removeFirst(length)
            } catch { rejected += 1; buffer.removeFirst() }
        }
        return frames
    }
}

struct Step: Identifiable {
    var id: String
    var raw: JSONObject
    var sourceIndex: Int
    var event: Int { raw.integer("event_type") }
    var name: String { [1:"装头",2:"卸头",3:"吸液",4:"排液",5:"混匀",6:"震荡",7:"等待",8:"循环",9:"分段下降吸液"][event] ?? "未知动作" }
    var dose: Double { raw.number("dose") }
    var plate: Int { raw.integer("plate_number") }
    var mixTimes: Int { raw.integer("mix_times") }
    var holes: [Int] { raw["hole_id_list"] as? [Int] ?? [] }
    var detail: String {
        if event == 7 { return "等待 \(formatNumber(raw.number("wait_time"))) 秒" }
        if event == 8 { return "\(raw.integer("loop_count")) 次 · \(raw.array("loop_steps").count) 步" }
        return "T\(plate) · \(WellAddress.label(row:raw.integer("x_axis"),column:raw.integer("y_axis")))"
    }
    var displayDose: String { [3,4,5,9].contains(event) ? "\(formatNumber(dose)) µL" : "—" }
    var saved: JSONObject { ["id":id,"raw":raw,"sourceIndex":sourceIndex] }
}
struct Program: Identifiable {
    var id: String
    var name: String
    var range: Int
    var worktableID: Int
    // In-memory display token: copies share it until a step (including nested raw fields) changes.
    // Undo/redo restores the token with the corresponding value; it never enters saved JSON.
    private(set) var stepsRevision=UUID()
    var steps: [Step] { didSet { stepsRevision=UUID() } }
    var raw: JSONObject
    var orderConfirmed: Bool = false
    var origin: String = "平板导出"
    var motionSpeeds: [String:ProgramSpeed] = [:]
    var width: Int {
        guard let load = steps.first(where: { $0.event == 1 }) else { return 0 }
        return Set(load.holes.map { $0 % 12 }).count
    }
    var saved: JSONObject { ["id":id,"name":name,"range":range,"worktableID":worktableID,"steps":steps.map(\.saved),"raw":raw,"orderConfirmed":orderConfirmed,"origin":origin,"motionSpeeds":motionSpeeds.mapValues(\.saved)] }
    static func restore(_ d: JSONObject) -> Program {
        Program(id:d.text("id"),name:d.text("name"),range:d.integer("range"),worktableID:d.integer("worktableID"),steps:d.array("steps").map { Step(id:$0.text("id"),raw:$0.object("raw"),sourceIndex:$0.integer("sourceIndex")) },raw:d.object("raw"),orderConfirmed:d["orderConfirmed"] as? Bool ?? false,origin:d.text("origin","Mac 保存"),motionSpeeds:d.object("motionSpeeds").compactMapValues { ($0 as? JSONObject).map(ProgramSpeed.restore) })
    }
    /// A board combination owns its head range. Selecting it updates both
    /// representations without changing any step's requested liquid volume.
    mutating func selectTable(_ id:Int,workspace:Workspace) throws {
        let headRange=try workspace.resolvedTableHeadRange(id)
        worktableID=id;range=headRange
        raw["worktable_id"]=id;raw["range"]=headRange
    }
    func expanded() throws -> [Step] {
        var result: [Step] = []
        func integer(_ raw:JSONObject,_ key:String,within bounds:ClosedRange<Int>) throws -> Int {
            guard let n=exactIntegerValue(raw.text(key)),bounds.contains(n) else { throw ControlError.invalid("\(key) 应为 \(bounds.lowerBound)–\(bounds.upperBound) 的整数") }
            return n
        }
        for step in steps {
            let event=try integer(step.raw,"event_type",within:1...9)
            if event != 8 { result.append(step); continue }
            let count = try integer(step.raw,"loop_count",within:1...1000)
            let children = step.raw.array("loop_steps")
            guard !children.isEmpty else { throw ControlError.invalid("循环内没有步骤，请编辑循环或解组") }
            guard result.count<=10000,children.count<=10000,count <= 1000,
                  !children.contains(where: { $0.integer("event_type") == 8 }),
                  children.count <= (10000-result.count)/count else { throw ControlError.invalid("循环超过 10,000 步或含嵌套循环；请展开后编辑") }
            for cycle in 0..<count {
                for (i,raw) in children.enumerated() { result.append(Step(id:"\(step.id)-\(cycle)-\(i)",raw:raw,sourceIndex:step.sourceIndex)) }
            }
        }
        guard !result.isEmpty, result.count <= 10000 else { throw ControlError.invalid("方案为空或超过 10,000 步") }
        return result
    }
}

struct Workspace {
    var tables: [String:Any]
    var programs: [Program]
    var source: String
    var deletedPrograms:[Program] = []
    var manualControls:ManualControlSettings? = nil
    var programFolders:[ProgramFolder] = []
    var programFolderAssignments:[String:String] = [:]
    static func load(directory: URL) throws -> Workspace {
        var tables: [String:Any] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension.lowercased() == "json" {
            tables[url.deletingPathExtension().lastPathComponent] = try jsonObject(Data(contentsOf:url))
        }
        guard let library = tables["SolutionLibrary"] as? [JSONObject], let details = tables["SolutionLibraryDetails"] as? [JSONObject] else { throw ControlError.invalid("选择含 SolutionLibrary.json 与 SolutionLibraryDetails.json 的 dataJson 文件夹") }
        var seen = Set<String>()
        let programs = try library.map { raw -> Program in
            let id = raw.text("solutionId")
            guard !id.isEmpty, !seen.contains(id) else { throw ControlError.invalid("方案 ID 缺失或重复") }; seen.insert(id)
            let steps = details.enumerated().filter { $0.element.text("solution_id") == id }.map { Step(id:"\(id)-\($0.offset)",raw:$0.element,sourceIndex:$0.offset) }
            return Program(id:id,name:raw.text("name"),range:raw.integer("range"),worktableID:raw.integer("worktable_id"),steps:steps,raw:raw)
        }
        var workspace=Workspace(tables:tables,programs:programs,source:directory.path)
        workspace.seedTableHeadRanges()
        return workspace
    }
    func worktable(_ id: Int) -> JSONObject { (tables["WorkTable"] as? [JSONObject] ?? []).first { $0.integer("id") == id } ?? [:] }
    var config: JSONObject { tables["ZWorkConfig"] as? JSONObject ?? [:] }
    /// Vendor Dosage often contains 300 even for the 20 µL configurations.
    /// Infer only legacy combinations with one unanimous, valid program range.
    /// An explicit but invalid/unspecified marker must never fall back to a guess.
    func resolvedTableHeadRange(_ id:Int) throws -> Int {
        let matches=(tables["WorkTable"] as? [JSONObject] ?? []).filter { exactIntegerValue($0.text("id"))==id }
        guard id>0,matches.count==1,let table=matches.first,table.integer("Model")==1 else {
            throw ControlError.invalid("请选择有效的 9210 板位组合")
        }
        if table["_macHeadRange"] != nil {
            guard let range=exactIntegerValue(table.text("_macHeadRange")),[20,1000].contains(range) else {
                throw ControlError.invalid("板位组合尚未指定有效移液头量程，请在位置／底板中选择20或1000 µL")
            }
            return range
        }
        let references=(programs+deletedPrograms).filter { $0.worktableID==id }
        let ranges=Set(references.map(\.range))
        guard ranges.count==1,let range=ranges.first,[20,1000].contains(range) else {
            throw ControlError.invalid(references.isEmpty
                ? "板位组合尚未指定移液头量程，请在位置／底板中选择20或1000 µL"
                : "此板位组合被不同量程或无效量程的程序引用，请在位置／底板中明确设置移液头量程")
        }
        return range
    }
    mutating func seedTableHeadRanges() {
        var rows=tables["WorkTable"] as? [JSONObject] ?? []
        for i in rows.indices where rows[i]["_macHeadRange"]==nil && rows[i].integer("Model")==1 {
            if let range=try? resolvedTableHeadRange(rows[i].integer("id")) { rows[i]["_macHeadRange"]=range }
        }
        tables["WorkTable"]=rows
    }
    func preflight(_ p: Program) -> [String] {
        var issues: [String] = []
        if worktable(p.worktableID).isEmpty { issues.append("缺少所选台面配置") }
        if config.isEmpty { issues.append("缺少运动轴配置") }
        do { if try resolvedTableHeadRange(p.worktableID) != p.range { issues.append("程序量程与板位组合移液头不一致，请重新选择板位组合") } }
        catch { issues.append(error.localizedDescription) }
        if !(tables["Curve"] as? [JSONObject] ?? []).contains(where: { $0.integer("range") == p.range }) { issues.append("缺少 \(p.range) µL 曲线") }
        return issues
    }
}
