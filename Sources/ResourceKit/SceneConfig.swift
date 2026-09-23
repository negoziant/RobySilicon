import Foundation

public struct SceneObject {
    public let name: String
    public let gridX: Int
    public let gridY: Int
    public let isActive: Bool
}

public struct SoundVariable {
    public let name: String
    public let file: String
    public let type: Int
    public let isActive: Bool
}

public struct GridDirection {
    public let x: Int
    public let y: Int
    public let dir: Int

    public init(x: Int, y: Int, dir: Int) {
        self.x = x
        self.y = y
        self.dir = dir
    }
}

public struct SceneConfig {
    public let sceneName: String
    public let screenName: String
    public let barName: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let scrollPar: (Int, Int)
    public let scrollDesc: (Int, Int)
    public let leftTopGrid: (Int, Int)
    public let gridSize: (Int, Int)
    public let gridLength: (Int, Int)
    public let gridShift: (Int, Int)
    public let zPerGrid: Int
    public let closedVerts: [(Int, Int)]
    public let closedDirs: [GridDirection]
    public let objects: [SceneObject]
    public let sounds: [SoundVariable]
    public let textVariables: [(name: String, index: Int)]
    public let music: String

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var sceneName = "", screenName = "", barName = "", music = ""
        var screenW = 0, screenH = 0
        var scrollPar = (0, 0), scrollDesc = (0, 0)
        var leftTopGrid = (0, 0), gridSize = (0, 0), gridLength = (0, 0), gridShift = (0, 0)
        var zPerGrid = 0
        var closedVerts: [(Int, Int)] = []
        var closedDirs: [GridDirection] = []
        var objects: [SceneObject] = []
        var sounds: [SoundVariable] = []
        var textVars: [(String, Int)] = []
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            if let keyword = Self.extractKeyword(line) {
                currentSection = keyword
                let value = Self.extractValue(line)

                switch keyword {
                case "SceneName": sceneName = value
                case "ScreenName": screenName = value
                case "BarName": barName = value
                case "ScreenSize":
                    let pair = Self.parseIntPair(value)
                    screenW = pair.0; screenH = pair.1
                case "ScrollPar": scrollPar = Self.parseIntPair(value)
                case "ScrollDesc": scrollDesc = Self.parseIntPair(value)
                case "LeftTopGrid": leftTopGrid = Self.parseIntPair(value)
                case "GridSize": gridSize = Self.parseIntPair(value)
                case "GridLength": gridLength = Self.parseIntPair(value)
                case "GridShift": gridShift = Self.parseIntPair(value)
                case "ZPerGrid": zPerGrid = Int(value) ?? 0
                case "Music": music = value
                case "ClosedVert":
                    closedVerts += Self.parseVertPairs(value)
                case "ClosedDir":
                    closedDirs += Self.parseDirTriples(value)
                case "ObjectList":
                    if let obj = Self.parseObject(value) { objects.append(obj) }
                case "SoundVariables":
                    if let snd = Self.parseSound(value) { sounds.append(snd) }
                case "TextVariables":
                    if let tv = Self.parseTextVar(value) { textVars.append(tv) }
                default: break
                }
            } else {
                let value = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
                switch currentSection {
                case "ClosedVert":
                    closedVerts += Self.parseVertPairs(value)
                case "ClosedDir":
                    closedDirs += Self.parseDirTriples(value)
                case "ObjectList":
                    if let obj = Self.parseObject(value) { objects.append(obj) }
                case "SoundVariables":
                    if let snd = Self.parseSound(value) { sounds.append(snd) }
                case "TextVariables":
                    if let tv = Self.parseTextVar(value) { textVars.append(tv) }
                default: break
                }
            }
        }

        self.sceneName = sceneName
        self.screenName = screenName
        self.barName = barName
        self.screenWidth = screenW
        self.screenHeight = screenH
        self.scrollPar = scrollPar
        self.scrollDesc = scrollDesc
        self.leftTopGrid = leftTopGrid
        self.gridSize = gridSize
        self.gridLength = gridLength
        self.gridShift = gridShift
        self.zPerGrid = zPerGrid
        self.closedVerts = closedVerts
        self.closedDirs = closedDirs
        self.objects = objects
        self.sounds = sounds
        self.textVariables = textVars
        self.music = music
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

    private static func parseIntPair(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
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

    private static func parseObject(_ s: String) -> SceneObject? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
        let name = parts[0].lowercased()
        guard name.first?.isLetter == true else { return nil }
        let isActive = parts.contains("*")
        return SceneObject(name: name, gridX: x, gridY: y, isActive: isActive)
    }

    private static func parseSound(_ s: String) -> SoundVariable? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let name = parts[0]
        guard name.first?.isLetter == true else { return nil }
        var file = parts[1]
        if file.hasPrefix("\"") && file.hasSuffix("\"") { file = String(file.dropFirst().dropLast()) }
        let type = Int(parts[2]) ?? 0
        let isActive = parts.contains("*")
        return SoundVariable(name: name, file: file, type: type, isActive: isActive)
    }

    private static func parseTextVar(_ s: String) -> (String, Int)? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0].first?.isLetter == true else { return nil }
        return (parts[0], Int(parts[1]) ?? 0)
    }
}
