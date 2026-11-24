import Foundation

struct ProgramSpeed:Equatable {
    var gear:Int
    var acceleration:Int
    var speed:Int
    var saved:JSONObject { ["gear":gear,"acceleration":acceleration,"speed":speed] }
    static func restore(_ raw:JSONObject)->ProgramSpeed {
        ProgramSpeed(gear:(try? SpeedTable.integer(raw,"gear",within:1...10)) ?? -1,
                     acceleration:(try? SpeedTable.integer(raw,"acceleration",within:0...255)) ?? -1,
                     speed:(try? SpeedTable.integer(raw,"speed",within:0...255)) ?? -1)
    }
    static let types=["XSpeed","YSpeed","ZSpeed","BlowSpeed","LoadSecondSpeed","UnLoadSpeed"]
    static let labels=["XSpeed":"X 轴","YSpeed":"Y 轴","ZSpeed":"Z 轴","BlowSpeed":"吹样","LoadSecondSpeed":"装头第二段","UnLoadSpeed":"卸头"]
    static let configKeys=["XSpeed":"xGear","YSpeed":"yGear","ZSpeed":"zGear","BlowSpeed":"blowGear","LoadSecondSpeed":"zLoadSecondGear","UnLoadSpeed":"zUnLoadGear"]
}

enum SpeedTable {
    static func integer(_ raw:JSONObject,_ key:String,within bounds:ClosedRange<Int>) throws -> Int {
        guard let value=exactIntegerValue(raw.text(key)),bounds.contains(value) else {
            throw ControlError.invalid("\(key) 应为 \(bounds.lowerBound)–\(bounds.upperBound) 的整数")
        }
        return value
    }
    static func setting(_ tables:JSONObject,type:String,gear:Int) throws -> ProgramSpeed {
        guard (1...10).contains(gear) else { throw ControlError.invalid("\(type) 速度档应为1–10") }
        let groups=(tables["SpeedConfig"] as? [JSONObject] ?? []).filter { $0.text("SpeedType")==type }
        guard groups.count==1 else { throw ControlError.invalid("速度表 \(type) 缺失或重复，请保留一组有效配置") }
        var seen=Set<Int>(),selected:JSONObject?
        for row in groups[0].array("SpeedList") {
            let g=try integer(row,"gear",within:1...10)
            guard seen.insert(g).inserted else { throw ControlError.invalid("速度表 \(type) 的第 \(g) 档重复") }
            if g==gear { selected=row }
        }
        guard let row=selected else { throw ControlError.invalid("速度表 \(type) 缺少第 \(gear) 档") }
        return ProgramSpeed(gear:gear,acceleration:try integer(row,"accSpeed",within:0...255),speed:try integer(row,"speed",within:0...255))
    }
    static let manualPositionKeys=["xAccSpeed","xSpeed","yAccSpeed","ySpeed","zAccSpeed","zSpeed"]
    static let defaultGearKeys=ProgramSpeed.types.compactMap { ProgramSpeed.configKeys[$0] }
    // Preserved for Android round trips. No current Mac command reads these values.
    static let legacyKeys=["xJogSpeed","yJogSpeed","zJogSpeed","imbibingJogSpeed",
        "imbibingAccSpeed","imbibingSpeed","imbibingGear","trapAccSpeed","trapSpeed","trapGear",
        "mixAspAccSpeed","mixAspSpeed","mixAspGear","mixTrapAccSpeed","mixTrapSpeed","mixTrapGear",
        "blowAccSpeed","blowSpeed","zLoadSecondAccSpeed","zLoadSecondSpeed","zUnLoadAccSpeed","zUnLoadSpeed"]
}
struct ProgramFolder:Identifiable,Equatable {
    let id:String
    var name:String
    var saved:JSONObject { ["id":id,"name":name] }
    static func cleanName(_ value:String)->String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
    }
}

extension Workspace {
    var saved:JSONObject {
        var result:JSONObject=["format":"9210-mac-workspace-v1","tables":tables,"programs":programs.map(\.saved),"deletedPrograms":deletedPrograms.map(\.saved),"source":source]
        if let settings=manualControls { result["manualControls"]=settings.saved }
        if !programFolders.isEmpty { result["programFolders"]=programFolders.map(\.saved) }
        if !programFolderAssignments.isEmpty { result["programFolderAssignments"]=programFolderAssignments }
        return result
    }
    static func restore(_ raw:JSONObject) throws -> Workspace {
        guard let tables=raw["tables"] as? JSONObject,let programs=raw["programs"] as? [JSONObject] else { throw ControlError.invalid("工作区需包含参数表和程序列表") }
        var manualControls:ManualControlSettings?
        if let value=raw["manualControls"] {
            guard let settings=value as? JSONObject else { throw ControlError.invalid("手动操作设置格式错误") }
            manualControls=ManualControlSettings.restore(settings)
        }
        var workspace=Workspace(tables:tables,programs:programs.map(Program.restore),source:raw.text("source"),deletedPrograms:raw.array("deletedPrograms").map(Program.restore),manualControls:manualControls)
        var folderIDs=Set<String>()
        for entry in raw.array("programFolders") {
            let id=entry.text("id"),name=ProgramFolder.cleanName(entry.text("name"))
            if !id.isEmpty,!name.isEmpty,folderIDs.insert(id).inserted { workspace.programFolders.append(ProgramFolder(id:id,name:name)) }
        }
        let programIDs=Set(workspace.programs.map(\.id))
        if let assignments=raw["programFolderAssignments"] as? [String:String] {
            workspace.programFolderAssignments=assignments.filter { programIDs.contains($0.key) && folderIDs.contains($0.value) }
        }
        workspace.seedTableHeadRanges()
        return workspace
    }
    func speedSetting(_ type:String,gear:Int)->ProgramSpeed {
        // Invalid legacy data remains visible as invalid and cannot silently become a different speed.
        (try? checkedSpeedSetting(type,gear:gear)) ?? ProgramSpeed(gear:gear,acceleration:-1,speed:-1)
    }
    func checkedSpeedSetting(_ type:String,gear:Int) throws -> ProgramSpeed { try SpeedTable.setting(tables,type:type,gear:gear) }
    func checkedDefaultMotionSpeeds() throws -> [String:ProgramSpeed] {
        try Dictionary(uniqueKeysWithValues:ProgramSpeed.types.map { type in
            (type,try checkedSpeedSetting(type,gear:SpeedTable.integer(config,ProgramSpeed.configKeys[type]!,within:1...10)))
        })
    }
    var defaultMotionSpeeds:[String:ProgramSpeed] { Dictionary(uniqueKeysWithValues:ProgramSpeed.types.map { type in
        let gear=(try? SpeedTable.integer(config,ProgramSpeed.configKeys[type]!,within:1...10)) ?? -1
        return (type,speedSetting(type,gear:gear))
    }) }
    mutating func seedProgramSpeeds() {
        let defaults=defaultMotionSpeeds
        for i in programs.indices { for (key,value) in defaults where programs[i].motionSpeeds[key]==nil { programs[i].motionSpeeds[key]=value } }
        for i in deletedPrograms.indices { for (key,value) in defaults where deletedPrograms[i].motionSpeeds[key]==nil { deletedPrograms[i].motionSpeeds[key]=value } }
    }
    private func checkedFolderName(_ value:String,excluding id:String?=nil) throws -> String {
        let name=ProgramFolder.cleanName(value)
        guard !name.isEmpty,name.count<=80 else { throw ControlError.invalid("请输入 1–80 个字符的文件夹名称") }
        guard !programFolders.contains(where:{ $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ControlError.invalid("已有同名文件夹")
        }
        return name
    }
    @discardableResult mutating func createProgramFolder(_ value:String) throws -> String {
        let name=try checkedFolderName(value),id=UUID().uuidString
        programFolders.append(ProgramFolder(id:id,name:name));return id
    }
    mutating func renameProgramFolder(_ id:String,to value:String) throws {
        guard let index=programFolders.firstIndex(where:{ $0.id==id }) else { throw ControlError.invalid("找不到文件夹") }
        let name=try checkedFolderName(value,excluding:id)
        programFolders[index].name=name
    }
    @discardableResult mutating func moveProgram(_ programID:String,toFolder folderID:String?) -> Bool {
        guard programs.contains(where:{ $0.id==programID }),programFolderAssignments[programID] != folderID else { return false }
        if let folderID=folderID,!programFolders.contains(where:{ $0.id==folderID }) { return false }
        programFolderAssignments[programID]=folderID;return true
    }
    /// Moves the displayed selection as one block, without modifying any program body.
    @discardableResult mutating func arrangePrograms(_ orderedIDs:[String],at destination:ProgramLibraryDestination) -> Bool {
        let movingIDs=Set(orderedIDs)
        guard !movingIDs.isEmpty,movingIDs.count==orderedIDs.count else { return false }
        let moving=Dictionary(programs.filter { movingIDs.contains($0.id) }.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        guard moving.count==orderedIDs.count else { return false }

        let folderID:String?,anchor:String?,insertAfter:Bool
        switch destination {
        case .end(let folder):
            if let folder=folder,!programFolders.contains(where:{ $0.id==folder }) { return false }
            folderID=folder;anchor=nil;insertAfter=false
        case .before(let id),.after(let id):
            guard !movingIDs.contains(id),programs.contains(where:{ $0.id==id }) else { return false }
            folderID=programFolderAssignments[id];anchor=id
            if case .after=destination { insertAfter=true } else { insertAfter=false }
        }
        var remaining=programs.filter { !movingIDs.contains($0.id) }
        let index:Int
        if let anchor=anchor,let target=remaining.firstIndex(where:{ $0.id==anchor }) {
            index=target+(insertAfter ? 1 : 0)
        } else {
            index=remaining.lastIndex(where:{ programFolderAssignments[$0.id]==folderID }).map { $0+1 } ?? remaining.count
        }
        remaining.insert(contentsOf:orderedIDs.compactMap { moving[$0] },at:index)
        if orderedIDs.allSatisfy({ programFolderAssignments[$0]==folderID }) {
            // Changes in interleaving between folders do not change the visible order.
            let original=programs.filter { programFolderAssignments[$0.id]==folderID }.map(\.id)
            let reordered=remaining.filter { programFolderAssignments[$0.id]==folderID }.map(\.id)
            guard original != reordered else { return false }
        }
        for id in orderedIDs { programFolderAssignments[id]=folderID }
        programs=remaining
        return true
    }
    @discardableResult mutating func reorderProgramFolder(_ id:String,relativeTo anchor:String,after:Bool) -> Bool {
        guard id != anchor,let source=programFolders.firstIndex(where:{ $0.id==id }),
              let target=programFolders.firstIndex(where:{ $0.id==anchor }) else { return false }
        let insertion=target+(after ? 1 : 0)-(source<target ? 1 : 0)
        guard insertion != source else { return false }
        let folder=programFolders.remove(at:source)
        programFolders.insert(folder,at:insertion)
        return true
    }
    @discardableResult mutating func removeProgramFolder(_ id:String) -> Bool {
        guard let index=programFolders.firstIndex(where:{ $0.id==id }) else { return false }
        programFolders.remove(at:index)
        programFolderAssignments=programFolderAssignments.filter { $0.value != id }
        return true
    }
    mutating func removeProgram(_ id:String,archive:Bool=true) -> Program? {
        guard let i=programs.firstIndex(where:{ $0.id==id }) else { return nil }
        let removed=programs.remove(at:i);programFolderAssignments.removeValue(forKey:id)
        if archive { deletedPrograms.append(removed) };return removed
    }
    mutating func restoreProgram(_ id:String)->String? {
        guard let i=deletedPrograms.firstIndex(where:{ $0.id==id }) else { return nil }
        var restored=deletedPrograms.remove(at:i)
        if programs.contains(where:{ $0.id==restored.id }) { restored.id=UUID().uuidString }
        programs.append(restored);return restored.id
    }
}

extension Program {
    @discardableResult mutating func copySteps(ids:Set<String>,copies:Int,afterIndex:Int) throws -> [String] {
        let originals=steps.filter { ids.contains($0.id) }
        guard !originals.isEmpty,(1...100).contains(copies),(0...steps.count).contains(afterIndex) else { throw ControlError.invalid("请选择步骤，副本组数为 1–100") }
        guard steps.count<=10000,originals.count<=(10000-steps.count)/copies else { throw ControlError.invalid("复制后步骤节点不能超过 10,000 个") }
        let added=(0..<copies).flatMap { _ in originals.map { $0.copied() } }
        steps.insert(contentsOf:added,at:afterIndex);orderConfirmed=false;return added.map(\.id)
    }
    mutating func moveSteps(ids:Set<String>,delta:Int) {
        if delta == -1 {
            for i in steps.indices.dropFirst() where ids.contains(steps[i].id) && !ids.contains(steps[i-1].id) { steps.swapAt(i,i-1) }
        } else if delta == 1,steps.count>1 {
            for i in stride(from:steps.count-2,through:0,by:-1) where ids.contains(steps[i].id) && !ids.contains(steps[i+1].id) { steps.swapAt(i,i+1) }
        }
        orderConfirmed=false
    }
    mutating func changePositions(ids:Set<String>,workspace:Workspace,row:Int,column:Int,relative:Bool) throws {
        guard (-10000...10000).contains(row),(-10000...10000).contains(column) else { throw ControlError.invalid("行列调整值超出范围") }
        let plates=workspace.worktable(worktableID).array("WorkTablets")
        func changed(_ raw:JSONObject) throws -> JSONObject {
            var result=raw
            if raw.integer("event_type")==8 { result["loop_steps"]=try raw.array("loop_steps").map(changed);return result }
            guard (1...5).contains(raw.integer("event_type")) || raw.integer("event_type")==9 else { return result }
            guard let plate=plates.first(where:{ $0.integer("Number")==raw.integer("plate_number") }) else { throw ControlError.invalid("找不到 T\(raw.integer("plate_number"))") }
            let material=plate.object("Material"),rows=material.integer("HoleRow"),columns=material.integer("HoleColum")
            guard let oldRow=Double(raw.text("x_axis")),let oldCol=Double(raw.text("y_axis")),oldRow.isFinite,oldCol.isFinite,oldRow.rounded()==oldRow,oldCol.rounded()==oldCol,abs(oldRow)<10000,abs(oldCol)<10000 else { throw ControlError.invalid("原行列索引无效") }
            let newRow=relative ? Int(oldRow)+row : row,newCol=relative ? Int(oldCol)+column : column
            guard newRow>=0,newCol>=0,newRow<rows,newCol<columns else { throw ControlError.invalid("T\(raw.integer("plate_number")) 的目标孔位超出 \(rows) 行 × \(columns) 列；未修改任何步骤") }
            return WellAddress.set(result,row:newRow,column:newCol,rows:rows,columns:columns)
        }
        // Build a complete replacement before mutating, so one invalid target rolls back the whole batch.
        let updated=try steps.map { step -> Step in var copy=step;if ids.contains(step.id) { copy.raw=try changed(step.raw) };return copy }
        steps=updated;orderConfirmed=false
    }
}

enum WellAddress {
    static func rowLabel(_ index:Int)->String {
        guard (0..<1000).contains(index) else { return "?" }
        var value=index+1,result=""
        while value>0 { value-=1;result=String(UnicodeScalar(65+value%26)!)+result;value/=26 }
        return result
    }
    static func label(row:Int,column:Int)->String {
        guard (0..<1000).contains(row),column>=0,column<Int.max else { return "无效孔位" }
        return rowLabel(row)+String(column+1)
    }
    static func selectedIDs(row:Int,column:Int,rows:Int,columns:Int)->[Int] {
        guard (1...48).contains(rows),(1...48).contains(columns),(0..<rows).contains(row),(0..<columns).contains(column) else { return [] }
        return (row..<rows).flatMap { r in (column..<columns).map { r*columns+$0 } }
    }
    static func set(_ raw:JSONObject,row:Int,column:Int,rows:Int,columns:Int)->JSONObject {
        var value=raw;value["x_axis"]=row;value["y_axis"]=column
        let product=row.multipliedReportingOverflow(by:columns)
        let sum=product.partialValue.addingReportingOverflow(column)
        value["holeId"]=product.overflow || sum.overflow ? -1 : sum.partialValue
        value["hole_id_list"]=selectedIDs(row:row,column:column,rows:rows,columns:columns);return value
    }
}

/// Stable IDs keep a drop independent of changing row indices. A nil folder means the root.
enum ProgramLibraryDestination:Equatable {
    case before(String),after(String),end(String?)
}
