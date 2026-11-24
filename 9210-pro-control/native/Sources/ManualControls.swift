import Foundation

/// Preserve the same editable JSON and unknown fields as an automatic step.
struct ManualLiquidDraft:Equatable {
    var raw:JSONObject
    static func == (lhs:ManualLiquidDraft,rhs:ManualLiquidDraft)->Bool {
        NSDictionary(dictionary:lhs.raw).isEqual(to:rhs.raw)
    }
}

struct ManualControlSettings: Equatable {
    var tableID: Int = 8
    var loadPlate: Int = 0
    var unloadPlate: Int = 0
    var loadGear: Int = 1
    var unloadGear: Int = 1
    var loadRow: Int = 0
    var loadColumn: Int = 0
    var unloadRow: Int = 0
    var unloadColumn: Int = 0
    var segmentedPlate: Int = 0
    var segmentedRow: Int = 0
    var segmentedColumn: Int = 0
    /// A manual-page snapshot, independent of every saved program and of
    /// subsequent edits to the global speed table.
    var motionSpeeds: [String:ProgramSpeed] = [:]
    /// A separate draft for each table and action, including unfinished text.
    var liquidSteps:[String:ManualLiquidDraft] = [:]

    var saved: JSONObject {
        ["tableID":tableID,"loadPlate":loadPlate,"unloadPlate":unloadPlate,"loadGear":loadGear,"unloadGear":unloadGear,
         "loadRow":loadRow,"loadColumn":loadColumn,"unloadRow":unloadRow,"unloadColumn":unloadColumn,
         "segmentedPlate":segmentedPlate,"segmentedRow":segmentedRow,"segmentedColumn":segmentedColumn,
         "motionSpeeds":motionSpeeds.mapValues(\.saved),"liquidSteps":liquidSteps.mapValues(\.raw)]
    }
    static func restore(_ raw: JSONObject) -> ManualControlSettings {
        func integer(_ key: String, default fallback: Int) -> Int {
            guard raw[key] != nil else { return fallback }
            guard let value=Double(raw.text(key)),value.isFinite,value.rounded(.towardZero)==value,
                  value>=Double(Int32.min),value<=Double(Int32.max) else { return -1 }
            return Int(value)
        }
        let speeds:[String:ProgramSpeed]
        if let value=raw["motionSpeeds"] {
            if let values=value as? JSONObject {
                speeds=values.mapValues { ($0 as? JSONObject).map(ProgramSpeed.restore) ?? invalidSpeed }
            } else {
                // Preserve explicit malformed settings as invalid rather than
                // replacing them with an apparently usable speed snapshot.
                speeds=Dictionary(uniqueKeysWithValues:ProgramSpeed.types.map { ($0,invalidSpeed) })
            }
        } else { speeds=[:] }
        let liquidSteps:[String:ManualLiquidDraft]
        if let value=raw["liquidSteps"] {
            if let values=value as? JSONObject {
                liquidSteps=values.mapValues { ManualLiquidDraft(raw:$0 as? JSONObject ?? [:]) }
            } else {
                // Explicit malformed data stays invalid for the selected table;
                // an old workspace with no field still receives fresh defaults.
                let table=integer("tableID",default:0)
                liquidSteps=Dictionary(uniqueKeysWithValues:[3,4,5].map { ("\(table):\($0)",ManualLiquidDraft(raw:[:])) })
            }
        } else { liquidSteps=[:] }
        return ManualControlSettings(tableID:integer("tableID",default:0),loadPlate:integer("loadPlate",default:0),
                                     unloadPlate:integer("unloadPlate",default:0),loadGear:integer("loadGear",default:1),
                                     unloadGear:integer("unloadGear",default:1),loadRow:integer("loadRow",default:0),
                                     loadColumn:integer("loadColumn",default:0),unloadRow:integer("unloadRow",default:0),
                                     unloadColumn:integer("unloadColumn",default:0),segmentedPlate:integer("segmentedPlate",default:0),
                                     segmentedRow:integer("segmentedRow",default:0),segmentedColumn:integer("segmentedColumn",default:0),motionSpeeds:speeds,liquidSteps:liquidSteps)
    }
    private static let invalidSpeed=ProgramSpeed(gear:-1,acceleration:-1,speed:-1)

    func liquidRaw(event:Int,workspace:Workspace)->JSONObject {
        if let draft=liquidSteps["\(tableID):\(event)"] { return draft.raw }
        let plates=workspace.worktable(tableID).array("WorkTablets")
        let liquidPlates=plates.filter { plate in
            let material=plate.object("Material"),name=material.text("Name").lowercased()
            return !material.isEmpty && !["tip","枪头","吸头","废弃","废液"].contains(where:{ name.contains($0) })
        }
        let plate=liquidPlates.first { $0.integer("Number")==segmentedPlate } ?? liquidPlates.first
        var raw=Step.blank(event,plate:plate?.integer("Number") ?? 0).raw
        let liquids=workspace.tables["LiquidParameters"] as? [JSONObject] ?? []
        if let liquid=liquids.first(where:{ $0.integer("liquid_id")==1 }) ?? liquids.first {
            raw["liquid_id"]=liquid["liquid_id"];raw["liquid_type"]=liquid.text("liquid_type")
        }
        return raw
    }

    /// Resolve only the speed kinds the caller needs. An unused future/manual
    /// action's invalid setting must not prevent an unrelated tip operation.
    func resolvedMotionSpeeds(workspace:Workspace,types:[String]=ProgramSpeed.types) throws -> [String:ProgramSpeed] {
        var result:[String:ProgramSpeed]=[:]
        for type in types {
            guard ProgramSpeed.types.contains(type) else { throw ControlError.invalid("未知的手动通用速度类型 \(type)") }
            let value:ProgramSpeed
            if let saved=motionSpeeds[type] { value=saved }
            else {
                switch type {
                case "UnLoadSpeed":
                    // Preserve the previous manual eject parameters on upgrade.
                    value=ProgramSpeed(gear:1,acceleration:20,speed:10)
                case "BlowSpeed":
                    let gear=try SpeedTable.integer(workspace.config,"blowGear",within:1...10)
                    value=try workspace.checkedSpeedSetting(type,gear:gear)
                default:
                    value=try workspace.checkedSpeedSetting(type,gear:loadGear)
                }
            }
            guard (1...10).contains(value.gear),(0...255).contains(value.acceleration),(0...255).contains(value.speed) else {
                throw ControlError.invalid("手动的 \(ProgramSpeed.labels[type] ?? type) 速度档应为1–10，速度／加速度应为0–255")
            }
            result[type]=value
        }
        return result
    }

    /// Seed absent entries once. Keep invalid imported values visible so the
    /// user can repair them; never silently replace explicit bad settings.
    mutating func seedMotionSpeeds(workspace:Workspace) {
        for type in ProgramSpeed.types where motionSpeeds[type]==nil {
            motionSpeeds[type]=(try? resolvedMotionSpeeds(workspace:workspace,types:[type])[type]) ?? Self.invalidSpeed
        }
    }
    static func defaults(workspace: Workspace, tableID: Int? = nil) -> ManualControlSettings {
        let tables=(workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("Model")==1 }
        let selected=tableID ?? (tables.contains { $0.integer("id")==8 } ? 8 : tables.first?.integer("id") ?? 0)
        let plates=tables.first { $0.integer("id")==selected }?.array("WorkTablets") ?? []
        let load=plates.first {
            let name=$0.object("Material").text("Name").lowercased()
            return name.contains("tip") || name.contains("枪头") || name.contains("吸头")
        }?.integer("Number") ?? 0
        let unload=plates.first {
            let name=$0.object("Material").text("Name")
            return name.contains("废弃") || name.contains("废液")
        }?.integer("Number") ?? 0
        let segmented=plates.first {
            let name=$0.object("Material").text("Name").lowercased()
            return !$0.object("Material").isEmpty && !name.contains("tip") && !name.contains("枪头") && !name.contains("吸头") && !name.contains("废弃") && !name.contains("废液")
        }?.integer("Number") ?? plates.first?.integer("Number") ?? 0
        var settings=ManualControlSettings(tableID:selected,loadPlate:load,unloadPlate:unload,segmentedPlate:segmented)
        settings.seedMotionSpeeds(workspace:workspace)
        return settings
    }
}

extension Workspace {
    mutating func seedManualSpeeds() {
        var settings=manualControls ?? ManualControlSettings.defaults(workspace:self)
        settings.seedMotionSpeeds(workspace:self)
        manualControls=settings
    }
}

extension Compiler {
    func compileManualTip(event: Int, settings: ManualControlSettings) throws -> CompiledStep {
        guard event==1 || event==2 else { throw ControlError.invalid("手动操作仅支持装头或卸头") }
        let tables=(workspace.tables["WorkTable"] as? [JSONObject] ?? []).filter { $0.integer("id")==settings.tableID }
        guard tables.count==1,let table=tables.first,table.integer("Model")==1 else {
            throw ControlError.invalid("请选择有效的 9210 台面配置")
        }
        let number=event==1 ? settings.loadPlate : settings.unloadPlate
        let plates=table.array("WorkTablets")
        guard number>0,plates.indices.contains(number-1),plates[number-1].integer("Number")==number,
              plates.filter({ $0.integer("Number")==number }).count==1 else {
            throw ControlError.invalid("请选择有效的\(event==1 ? "装头" : "卸头")板位")
        }
        let plate=plates[number-1],material=plate.object("Material")
        guard !material.isEmpty else { throw ControlError.invalid("所选板位尚未配置耗材") }
        let rows=try whole(material,"HoleRow",within:1...48),columns=try whole(material,"HoleColum",within:1...48)
        let row=event==1 ? settings.loadRow : settings.unloadRow,column=event==1 ? settings.loadColumn : settings.unloadColumn
        guard (0..<rows).contains(row),(0..<columns).contains(column) else {
            throw ControlError.invalid("手动\(event==1 ? "装头" : "卸头")起始孔位超出所选板位，请重新选择")
        }
        for key in ["XPos","YPos","ZPos"] {
            guard try finite(plate.text(key),label:fieldCoordinateLabel(key))>=0 else {
                throw ControlError.invalid("所选板位的 \(key) 不能为负数")
            }
        }
        let spacingKey=event==1 ? "loadSecondSpacing" : "unLoadSpacing"
        let spacing=try finite(config.text(spacingKey),label:event==1 ? "装头第二段距离" : "卸头距离")
        guard spacing>=0 else { throw ControlError.invalid("装卸头距离不能为负数") }

        let headRange=try workspace.resolvedTableHeadRange(settings.tableID)
        var program=Program.blank(name:event==1 ? "手动装头" : "手动卸头",range:headRange,table:settings.tableID)
        let types=event==1 ? ["XSpeed","YSpeed","ZSpeed","LoadSecondSpeed"] : ["XSpeed","YSpeed","ZSpeed","UnLoadSpeed"]
        program.motionSpeeds=try settings.resolvedMotionSpeeds(workspace:workspace,types:types)
        var step=Step.blank(event)
        step.raw["plate_number"]=number
        step.raw=WellAddress.set(step.raw,row:row,column:column,rows:rows,columns:columns)
        return try compile(step,program:program)
    }
    private func fieldCoordinateLabel(_ key: String) -> String { "板位 \(key.prefix(1)) 坐标" }
}
