import Foundation

public enum FSCommand {
    case frame(index: Int, delta: Int)
    case delay(ms: Int)
    case sound(name: String, params: [String])
    case text(index: Int, param: Int)
    case aproach(character: String, object: String, x: Int, y: Int)
    case createObject(scene: String, obj: String, character: String, x: Int, y: Int)
    case delObject(scene: String, obj: String, character: String, x: Int, y: Int)
    case shift(target: String, axis: String, value: String)
    case set(target: String, axis: String, value: String)
    case setVar(name: String, value: String)
    case setCharVar(name: String, value: String)
    case setRest(character: String, param: String, script: String)
    case setVert(x: Int, y: Int, state: String)
    // character пустой = активный персонаж; "AddItem Frid, confr" — адресно
    case addItem(name: String, character: String)
    case deleteItem(name: String, character: String)
    case setActive(name: String) // предмет становится выбранным («в руке»)
    case lockBar(state: String)
    case showChar(name: String)
    case hideChar(name: String)
    case goScene(params: [String])
    case setBar(state: String)
    case setMouse(state: String)
    case setMap(state: String)
    case startGame(number: Int, resultVar: String, stateVar: String)
    case setMusic(name: String)
    case shiftScreen(dx: Int, dy: Int)
    case ifCondition(variable: String, value: String)
    case endIf
}

public struct FrameSequence {
    public let scriptName: String
    public let movieName: String
    public let shiftX: Int
    public let shiftY: Int
    public let totalFrames: Int
    public let commands: [FSCommand]

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var scriptName = "", movieName = ""
        var shiftX = 0, shiftY = 0, totalFrames = 0
        var commands: [FSCommand] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            let clean = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed

            let splitIdx = clean.firstIndex(where: { $0 == " " || $0 == "\t" })
            if let splitIdx = splitIdx {
                let keyword = String(clean[clean.startIndex..<splitIdx])
                let rest = String(clean[clean.index(after: splitIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
                    .trimmingCharacters(in: .whitespaces)

                switch keyword.lowercased() {
                case "scriptname":
                    scriptName = rest
                case "moviename":
                    movieName = rest
                case "shift":
                    if commands.isEmpty {
                        let pair = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if pair.count >= 2 {
                            shiftX = Int(pair[0]) ?? 0
                            shiftY = Int(pair[1]) ?? 0
                        }
                    } else {
                        let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if parts.count >= 3 {
                            commands.append(.shift(target: parts[0], axis: parts[1], value: parts[2]))
                        }
                    }
                case "totalframes":
                    totalFrames = Int(rest) ?? 0
                case "frame":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.frame(index: Int(parts[0]) ?? 0, delta: Int(parts[1]) ?? 0))
                    }
                case "delay":
                    commands.append(.delay(ms: Int(rest) ?? 0))
                case "sound":
                    let parts = Self.splitParams(rest)
                    if let first = parts.first {
                        commands.append(.sound(name: first, params: Array(parts.dropFirst())))
                    }
                case "text":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.text(index: Int(parts[0]) ?? 0, param: Int(parts[1]) ?? 0))
                    }
                case "aproach":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 4 {
                        commands.append(.aproach(character: parts[0], object: parts[1],
                                                 x: Int(parts[2]) ?? 0, y: Int(parts[3]) ?? 0))
                    } else if parts.count == 3, let x = Int(parts[1]), let y = Int(parts[2]) {
                        // Трёхаргументная форма: Aproach char,x,y — абсолютная клетка
                        commands.append(.aproach(character: parts[0], object: "", x: x, y: y))
                    }
                case "createobject":
                    // 5 аргументов: scene,obj,char,x,y; 4 аргумента: scene,obj,x,y (клетка)
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 5 {
                        commands.append(.createObject(scene: parts[0], obj: parts[1], character: parts[2],
                                                      x: Int(parts[3]) ?? 0, y: Int(parts[4]) ?? 0))
                    } else if parts.count == 4 {
                        commands.append(.createObject(scene: parts[0], obj: parts[1], character: "",
                                                      x: Int(parts[2]) ?? 0, y: Int(parts[3]) ?? 0))
                    }
                case "delobject":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 5 {
                        commands.append(.delObject(scene: parts[0], obj: parts[1], character: parts[2],
                                                   x: Int(parts[3]) ?? 0, y: Int(parts[4]) ?? 0))
                    } else if parts.count == 4 {
                        commands.append(.delObject(scene: parts[0], obj: parts[1], character: "",
                                                   x: Int(parts[2]) ?? 0, y: Int(parts[3]) ?? 0))
                    }
                case "set":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 3 {
                        commands.append(.set(target: parts[0], axis: parts[1], value: parts[2]))
                    }
                case "setvar":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.setVar(name: parts[0], value: parts[1]))
                    }
                case "setcharvar":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.setCharVar(name: parts[0], value: parts[1]))
                    }
                case "setrest":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 3 {
                        commands.append(.setRest(character: parts[0], param: parts[1], script: parts[2]))
                    }
                case "setvert":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 3 {
                        commands.append(.setVert(x: Int(parts[0]) ?? 0, y: Int(parts[1]) ?? 0, state: parts[2]))
                    }
                case "additem":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.addItem(name: parts[1], character: parts[0]))
                    } else {
                        commands.append(.addItem(name: rest.trimmingCharacters(in: .whitespaces), character: ""))
                    }
                case "deleteitem":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.deleteItem(name: parts[1], character: parts[0]))
                    } else {
                        commands.append(.deleteItem(name: rest.trimmingCharacters(in: .whitespaces), character: ""))
                    }
                case "setactive":
                    commands.append(.setActive(name: rest.trimmingCharacters(in: .whitespaces)))
                case "lockbar":
                    commands.append(.lockBar(state: rest.trimmingCharacters(in: .whitespaces)))
                case "showchar":
                    commands.append(.showChar(name: rest.trimmingCharacters(in: .whitespaces)))
                case "hidechar":
                    commands.append(.hideChar(name: rest.trimmingCharacters(in: .whitespaces)))
                case "goscene":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    commands.append(.goScene(params: parts))
                case "setbar":
                    commands.append(.setBar(state: rest.trimmingCharacters(in: .whitespaces)))
                case "setmouse":
                    commands.append(.setMouse(state: rest.trimmingCharacters(in: .whitespaces)))
                case "setmap":
                    commands.append(.setMap(state: rest.trimmingCharacters(in: .whitespaces)))
                case "startgame":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 3 {
                        commands.append(.startGame(number: Int(parts[0]) ?? -1,
                                                   resultVar: parts[1], stateVar: parts[2]))
                    }
                case "setmusic":
                    commands.append(.setMusic(name: rest.trimmingCharacters(in: .whitespaces)))
                case "shiftscreen":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.shiftScreen(dx: Int(parts[0]) ?? 0, dy: Int(parts[1]) ?? 0))
                    }
                case "if":
                    let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        commands.append(.ifCondition(variable: parts[0], value: parts[1]))
                    }
                case "endif":
                    commands.append(.endIf)
                default:
                    break
                }
            } else if clean.lowercased() == "endif" {
                commands.append(.endIf)
            }
        }

        self.scriptName = scriptName
        self.movieName = movieName
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.totalFrames = totalFrames
        self.commands = commands
    }

    private static func splitParams(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { result.append(last) }
        return result
    }
}
