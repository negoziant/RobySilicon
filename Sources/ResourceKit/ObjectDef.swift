import Foundation

public struct ObjectDef {
    public let name: String
    public let fonScript: String?
    public let zCoord: Int
    public let closedVerts: [(Int, Int)]
    public let closedDirs: [GridDirection]
    public let activeZones: [(x: Int, y: Int, width: Int, height: Int)]
    public var activeZone: (x: Int, y: Int, width: Int, height: Int)? { activeZones.first }
    public let cursor: Int
    public let textIndex: Int

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var name = ""
        var fonScript: String? = nil
        var zCoord = 0
        var closedVerts: [(Int, Int)] = []
        var closedDirs: [GridDirection] = []
        var activeZones: [(x: Int, y: Int, width: Int, height: Int)] = []
        var cursor = 0
        var textIndex = 0
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            if let keyword = Self.extractKeyword(line) {
                currentSection = keyword
                let value = Self.extractValue(line)

                switch keyword {
                case "ObjectName": name = value
                case "FonScript":
                    fonScript = (value == "NULL" || value.isEmpty) ? nil : value
                case "ZCoord": zCoord = Int(value) ?? 0
                case "Cursor": cursor = Int(value) ?? 0
                case "Text": textIndex = Int(value) ?? 0
                case "ClosedVert":
                    closedVerts += Self.parseVertPairs(value)
                case "ClosedDir":
                    closedDirs += Self.parseDirTriples(value)
                case "ActiveZone":
                    if let r = Self.parseRect(value) { activeZones.append(r) }
                default: break
                }
            } else {
                let value = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
                switch currentSection {
                case "ClosedVert":
                    closedVerts += Self.parseVertPairs(value)
                case "ClosedDir":
                    closedDirs += Self.parseDirTriples(value)
                case "ActiveZone":
                    // Зон может быть несколько — continuation-строки (ctree в SCENA3)
                    if let r = Self.parseRect(value) { activeZones.append(r) }
                default: break
                }
            }
        }

        self.name = name
        self.fonScript = fonScript
        self.zCoord = zCoord
        self.closedVerts = closedVerts
        self.closedDirs = closedDirs
        self.activeZones = activeZones
        self.cursor = cursor
        self.textIndex = textIndex
    }

    private static func extractKeyword(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        let parts = line.components(separatedBy: CharacterSet.whitespaces)
        guard let word = parts.first, !word.isEmpty else { return nil }
        let keyword = word.hasSuffix(";") ? String(word.dropLast()) : word
        if keyword.first?.isUppercase == true { return keyword }
        return nil
    }

    private static func extractValue(_ line: String) -> String {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
        if parts.count >= 2 {
            var val = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if val.hasSuffix(";") { val = String(val.dropLast()) }
            return val
        }
        let spaced = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet.whitespaces)
        if spaced.count >= 2 {
            var val = spaced.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if val.hasSuffix(";") { val = String(val.dropLast()) }
            return val
        }
        return ""
    }

    private static func parseVertPairs(_ s: String) -> [(Int, Int)] {
        let entries = s.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [(Int, Int)] = []
        for entry in entries {
            let parts = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, let x = Int(parts[0]), let y = Int(parts[1]) {
                result.append((x, y))
            }
        }
        return result
    }

    private static func parseDirTriples(_ s: String) -> [GridDirection] {
        let entries = s.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [GridDirection] = []
        for entry in entries {
            let parts = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let x = Int(parts[0]), let y = Int(parts[1]), let d = Int(parts[2]) {
                result.append(GridDirection(x: x, y: y, dir: d))
            }
        }
        return result
    }

    private static func parseRect(_ s: String) -> (Int, Int, Int, Int)? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4,
              let x = Int(parts[0]), let y = Int(parts[1]),
              let w = Int(parts[2]), let h = Int(parts[3]) else { return nil }
        return (x, y, w, h)
    }
}
