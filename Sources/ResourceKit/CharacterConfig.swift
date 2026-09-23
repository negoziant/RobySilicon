import Foundation

public struct CharacterConfig {
    public let name: String
    public let moveType: String
    public let fonScripts: [String]
    public let lookBox: (x: Int, y: Int, width: Int, height: Int)?
    public let items: [String]
    public let gridToClose: [GridDirection]

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var name = "", moveType = ""
        var fonScripts: [String] = []
        var lookBox: (Int, Int, Int, Int)? = nil
        var items: [String] = []
        var gridToClose: [GridDirection] = []
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            if let keyword = Self.extractKeyword(line) {
                currentSection = keyword
                let value = Self.extractValue(line)

                switch keyword {
                case "CharacterName": name = value
                case "MoveType": moveType = value
                case "FonScript":
                    if !value.isEmpty { fonScripts.append(value) }
                case "LookBox":
                    lookBox = Self.parseRect(value)
                case "Items":
                    if !value.isEmpty { items.append(value) }
                case "GridToClose":
                    gridToClose += Self.parseDirTriples(value)
                default: break
                }
            } else {
                let value = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
                switch currentSection {
                case "FonScript":
                    if !value.isEmpty { fonScripts.append(value) }
                case "Items":
                    if !value.isEmpty { items.append(value) }
                case "GridToClose":
                    gridToClose += Self.parseDirTriples(value)
                default: break
                }
            }
        }

        self.name = name
        self.moveType = moveType
        self.fonScripts = fonScripts
        self.lookBox = lookBox
        self.items = items
        self.gridToClose = gridToClose
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

    private static func parseRect(_ s: String) -> (Int, Int, Int, Int)? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4,
              let x = Int(parts[0]), let y = Int(parts[1]),
              let w = Int(parts[2]), let h = Int(parts[3]) else { return nil }
        return (x, y, w, h)
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
}
