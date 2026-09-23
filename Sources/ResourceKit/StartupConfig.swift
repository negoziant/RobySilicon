import Foundation

public struct CharacterDef {
    public let name: String
    public let direction: Int
    public let gridX: Int
    public let gridY: Int
    public let isStart: Bool
}

public struct StartupConfig {
    public let sceneDirectory: String
    public let movieDirectory: String
    public let waveDirectory: String
    public let characterDirectory: String
    public let barDirectory: String
    public let textFile: String
    public let scenes: [(name: String, isStart: Bool)]
    public let characters: [CharacterDef]
    public let intVariables: [(name: String, value: Int)]
    public let charVariables: [(name: String, value: String)]
    public let gridDebug: Int
    public let delayFactor: Int

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var sceneDir = ""
        var movieDir = ""
        var waveDir = ""
        var charDir = ""
        var barDir = ""
        var textFile = ""
        var scenes: [(String, Bool)] = []
        var characters: [CharacterDef] = []
        var intVars: [(String, Int)] = []
        var charVars: [(String, String)] = []
        var gridDebug = 0
        var delayFactor = 1

        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            if let keyword = Self.extractKeyword(line) {
                currentSection = keyword
                let value = Self.extractValue(line)

                switch keyword {
                case "SceneDirectory": sceneDir = value
                case "MovieDirectory": movieDir = value
                case "WaveDirectory": waveDir = value
                case "CharacterDirectory": charDir = value
                case "BarDirectory": barDir = value
                case "Text": textFile = value
                case "GridDebug": gridDebug = Int(value) ?? 0
                case "DelayFactor": delayFactor = Int(value) ?? 1
                case "Scenes":
                    if let scene = Self.parseScene(value) { scenes.append(scene) }
                case "Characters":
                    if let ch = Self.parseCharacter(value) { characters.append(ch) }
                case "IntVariables":
                    if let iv = Self.parseIntVar(value) { intVars.append(iv) }
                case "CharVariables":
                    if let cv = Self.parseCharVar(value) { charVars.append(cv) }
                default: break
                }
            } else {
                let value = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
                switch currentSection {
                case "Scenes":
                    if let scene = Self.parseScene(value) { scenes.append(scene) }
                case "Characters":
                    if let ch = Self.parseCharacter(value) { characters.append(ch) }
                case "IntVariables":
                    if let iv = Self.parseIntVar(value) { intVars.append(iv) }
                case "CharVariables":
                    if let cv = Self.parseCharVar(value) { charVars.append(cv) }
                default: break
                }
            }
        }

        self.sceneDirectory = sceneDir
        self.movieDirectory = movieDir
        self.waveDirectory = waveDir
        self.characterDirectory = charDir
        self.barDirectory = barDir
        self.textFile = textFile
        self.scenes = scenes
        self.characters = characters
        self.intVariables = intVars
        self.charVariables = charVars
        self.gridDebug = gridDebug
        self.delayFactor = delayFactor
    }

    private static func extractKeyword(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
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

    private static func parseScene(_ value: String) -> (String, Bool)? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty else { return nil }
        if name.first?.isLetter != true { return nil }
        let isStart = parts.contains("*")
        return (name, isStart)
    }

    private static func parseCharacter(_ value: String) -> CharacterDef? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4, parts[0].first?.isUppercase == true else { return nil }
        return CharacterDef(
            name: parts[0],
            direction: Int(parts[1]) ?? 0,
            gridX: Int(parts[2]) ?? 0,
            gridY: Int(parts[3]) ?? 0,
            isStart: parts.contains("*")
        )
    }

    private static func parseIntVar(_ value: String) -> (String, Int)? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0].first?.isLetter == true else { return nil }
        return (parts[0], Int(parts[1]) ?? 0)
    }

    private static func parseCharVar(_ value: String) -> (String, String)? {
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0].first?.isLetter == true else { return nil }
        var val = parts[1]
        if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
        return (parts[0], val)
    }
}
