import Foundation

/// Edits remain outside Workspace until the user explicitly saves this plate.
/// Only fields changed in this draft are merged, preserving later material edits.
struct PlateCalibrationDraft {
    let tableID:Int
    let original:JSONObject
    private(set) var edited:JSONObject
    private var changedKeys:Set<String>=[]

    init(plate:JSONObject,tableID:Int) { self.tableID=tableID;original=plate;edited=plate }

    var hasChanges:Bool { !changedKeys.isEmpty }
    mutating func set(_ key:String,value:Any?) {
        if let value=value { edited[key]=value } else { edited.removeValue(forKey:key) }
        let before=original[key].flatMap { try? fingerprint($0) }
        let after=edited[key].flatMap { try? fingerprint($0) }
        if before==after { changedKeys.remove(key) } else { changedKeys.insert(key) }
    }
    mutating func replace(with plate:JSONObject) {
        edited=plate
        changedKeys=Set(original.keys).union(edited.keys).filter { key in
            original[key].flatMap { try? fingerprint($0) } != edited[key].flatMap { try? fingerprint($0) }
        }
    }
    func merging(into current:JSONObject)->JSONObject {
        var result=current
        for key in changedKeys {
            if let value=edited[key] { result[key]=value } else { result.removeValue(forKey:key) }
        }
        return result
    }
}

struct PositionSettingsSelection:Equatable {
    var tableID:Int
    var plateNumber:Int
}

extension Workspace {
    /// Last position-page selection is independent of the selected program.
    /// Keep each combination's last plate when switching between combinations.
    func positionSettingsSelection(tableID requested:Int?=nil)->PositionSettingsSelection {
        let remembered=tables["_macPositionSelection"] as? JSONObject ?? [:]
        let available=(tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 }
        let preferred=requested ?? Int(remembered.text("tableID")) ?? manualControls?.tableID
        let table=available.first { $0.integer("id")==preferred } ?? available.first ?? [:]
        let id=table.integer("id"),plates=table.array("WorkTablets")
        let byTable=remembered.object("plateByTable")
        let wanted=Int(byTable.text(String(id))) ?? (id==Int(remembered.text("tableID")) ? Int(remembered.text("plateNumber")) : nil)
        let number=plates.first { $0.integer("Number")==wanted }?.integer("Number") ?? plates.first?.integer("Number") ?? 0
        return PositionSettingsSelection(tableID:id,plateNumber:number)
    }

    mutating func rememberPositionSettingsSelection(_ selection:PositionSettingsSelection) {
        let table=worktable(selection.tableID)
        guard table.integer("Model")==1,table.array("WorkTablets").contains(where:{ $0.integer("Number")==selection.plateNumber }) else { return }
        var remembered=tables["_macPositionSelection"] as? JSONObject ?? [:]
        var byTable=remembered.object("plateByTable")
        byTable[String(selection.tableID)]=selection.plateNumber
        remembered["tableID"]=selection.tableID;remembered["plateNumber"]=selection.plateNumber;remembered["plateByTable"]=byTable
        tables["_macPositionSelection"]=remembered
    }

    /// Validate the merged plate before mutating any formal coordinate.
    mutating func savePlateCalibration(_ draft:PlateCalibrationDraft,tableID:Int,number:Int) throws {
        guard draft.tableID==tableID,draft.original.integer("Number")==number else { throw ControlError.invalid("位置草稿与所选板位不一致，未保存") }
        let candidates=(tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("id")==tableID && $0.integer("Model")==1 }
        guard candidates.count==1,let table=candidates.first else { throw ControlError.invalid("找不到所选板位组合，位置草稿未保存") }
        let plates=table.array("WorkTablets").filter { $0.integer("Number")==number }
        guard plates.count==1,let current=plates.first else { throw ControlError.invalid("找不到所选板位，位置草稿未保存") }
        let merged=draft.merging(into:current)
        guard merged.integer("Number")==number,Int(merged.text("Number"))==number else { throw ControlError.invalid("板位编号不能通过位置草稿更改") }
        let axes:[String:String]=["XPos":"x","YPos":"y","ZPos":"z","ZGradientPos":"z",
            "AgainstZ":"z","AgainstXLeft":"x","AgainstXRight":"x","AdherentZ":"z","AdherentXLeft":"x","AdherentXRight":"x"]
        for (key,axis) in axes {
            guard merged[key] != nil,!merged.text(key).isEmpty else {
                if ["XPos","YPos","ZPos"].contains(key) { throw ControlError.invalid("请填写 \(key) 后保存位置") }
                continue
            }
            try validateCalibrationCoordinate(merged.text(key),axis:axis,label:key)
        }
        if let raw=merged["zMorePosBean"] {
            guard let heights=raw as? [JSONObject] else { throw ControlError.invalid("更多Z高度必须为列表，位置草稿未保存") }
            for height in heights { try validateCalibrationCoordinate(height.text("pos"),axis:"z",label:"更多Z高度") }
        }
        updatePlate(tableID:tableID,number:number) { $0=merged }
    }

    private func validateCalibrationCoordinate(_ text:String,axis:String,label:String) throws {
        guard let value=Double(text),value.isFinite,value>=0 else { throw ControlError.invalid("\(label) 应为大于等于0的有限数字，位置草稿未保存") }
        let coefficient=config.number(axis+"Coefficient"),pitch=config.number(axis+"ScrewPitch")
        guard coefficient.isFinite,pitch.isFinite,coefficient>0,pitch>0 else { throw ControlError.invalid("\(axis.uppercased())轴系数和导程无效，位置草稿未保存") }
        // Match the original APP / Compiler.axis Float multiplication before
        // the integer conversion, including overflow at the encoding boundary.
        let steps=floor(Double(Float(value)*Float(coefficient))/pitch*10.0*0.1)
        guard steps.isFinite,steps<=Double(Int32.max) else { throw ControlError.invalid("\(label) 超出设备坐标编码范围，位置草稿未保存") }
    }
}
