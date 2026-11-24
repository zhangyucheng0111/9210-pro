import Foundation

struct BluetoothCandidate: Equatable {
    let id: UUID
    let name: String
}

/// Connection preferences live separately from the program workspace. A saved
/// peripheral identity takes precedence over a matching advertised name.
struct BluetoothConnectionPreferences: Codable, Equatable {
    var autoConnect: Bool
    var preferredID: UUID?
    var preferredName: String

    init(autoConnect: Bool = true, preferredID: UUID? = nil, preferredName: String = "XLBLE") {
        self.autoConnect = autoConnect
        self.preferredID = preferredID
        self.preferredName = preferredName
    }

    private enum CodingKeys: String, CodingKey { case autoConnect, preferredID, preferredName }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        preferredID = try values.decodeIfPresent(UUID.self, forKey: .preferredID)
        preferredName = try values.decodeIfPresent(String.self, forKey: .preferredName) ?? "XLBLE"
    }

    mutating func remember(id: UUID, name: String) {
        preferredID = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { preferredName = trimmed }
    }

    func matches(id: UUID, name: String) -> Bool {
        if let preferredID = preferredID { return id == preferredID }
        let expected = normalized(preferredName), actual = normalized(name)
        guard !expected.isEmpty else { return false }
        if expected == "XLBLE" { return actual == "XLBLE" || actual == "XBLE" }
        return actual == expected
    }

    func candidate(in devices: [BluetoothCandidate]) -> UUID? {
        let matchingIDs = Set(devices.filter { matches(id: $0.id, name: $0.name) }.map(\.id))
        return matchingIDs.count == 1 ? matchingIDs.first : nil
    }

    private func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

struct BluetoothPreferencesStore {
    let url: URL

    func load() throws -> BluetoothConnectionPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return BluetoothConnectionPreferences() }
        return try JSONDecoder().decode(BluetoothConnectionPreferences.self, from: Data(contentsOf: url))
    }

    func save(_ preferences: BluetoothConnectionPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
