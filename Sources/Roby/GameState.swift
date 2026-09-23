import Foundation
import ResourceKit

struct SaveData: Codable {
    struct CharSave: Codable {
        var x: Int, y: Int, z: Int, dir: Int
        var visible: Bool
        var rest: String?
    }
    var intVars: [String: Int]
    var charVars: [String: String]
    var inventories: [String: [String]]
    var characters: [String: CharSave]
    var objectStates: [String: [String: Bool]]
    var objectPositions: [String: [String: [Int]]]
    var openVerts: [String: [[Int]]]
    var closedVerts: [String: [[Int]]]
    var currentScene: String
    var activeCharacter: String
    var currentMusic: String
    var selectedItem: String?
    var mapEnabled: Bool? // optional — совместимость со старыми сейвами
}

final class GameState {

    struct CharacterState {
        var gridX: Int
        var gridY: Int
        var z: Int
        var direction: Int
        var isVisible: Bool
        var restScript: String?
    }

    var intVars: [String: Int] = [:]
    var charVars: [String: String] = [:]

    // Инвентарь раздельный по персонажам (hand у Roby, handfr у Frid)
    var inventories: [String: [String]] = [:]
    var inventory: [String] { inventories[activeCharacter] ?? [] }

    var characters: [String: CharacterState] = [:]

    // sceneName(upper) -> objectName(lower) -> isActive
    var objectStates: [String: [String: Bool]] = [:]

    // CreateObject scene,obj,x,y может переопределить клетку объекта из SCN
    var objectPositionOverrides: [String: [String: (x: Int, y: Int)]] = [:]

    struct GridVert: Hashable {
        let x: Int
        let y: Int
    }
    var dynamicOpenVerts: [String: Set<GridVert>] = [:]
    var dynamicClosedVerts: [String: Set<GridVert>] = [:]

    var currentScene: String = ""
    var activeCharacter: String = "Roby"

    var barVisible = true
    var mouseEnabled = true
    var mapEnabled = false // SetMap ON после осознания острова (DISC6)
    var currentMusic: String = ""

    private(set) var textDB: TextDatabase?

    // MARK: - Initialization

    func initialize(startup: StartupConfig, texts: TextDatabase) {
        textDB = texts

        for (name, value) in startup.intVariables {
            intVars[name] = value
        }

        for (name, value) in startup.charVariables {
            charVars[name] = value
        }

        for char in startup.characters {
            characters[char.name] = CharacterState(
                gridX: char.gridX,
                gridY: char.gridY,
                z: 0,
                direction: char.direction,
                isVisible: false,
                restScript: nil
            )
        }

        if let startScene = startup.scenes.first(where: { $0.isStart }) {
            currentScene = startScene.name.uppercased()
        }
    }

    func initializeObjectStates(forScene name: String, from config: SceneConfig) {
        let key = name.uppercased()
        if objectStates[key] != nil { return }
        var states: [String: Bool] = [:]
        for obj in config.objects {
            states[obj.name.lowercased()] = obj.isActive
        }
        objectStates[key] = states
    }

    // MARK: - Object states

    func isObjectActive(scene: String, object: String) -> Bool {
        objectStates[scene.uppercased()]?[object.lowercased()] ?? false
    }

    func setObjectActive(scene: String, object: String, active: Bool) {
        let key = scene.uppercased()
        if objectStates[key] == nil { objectStates[key] = [:] }
        objectStates[key]![object.lowercased()] = active
    }

    func setObjectPosition(scene: String, object: String, x: Int, y: Int) {
        let key = scene.uppercased()
        if objectPositionOverrides[key] == nil { objectPositionOverrides[key] = [:] }
        objectPositionOverrides[key]![object.lowercased()] = (x, y)
    }

    func objectPosition(scene: String, object: String) -> (x: Int, y: Int)? {
        objectPositionOverrides[scene.uppercased()]?[object.lowercased()]
    }

    // MARK: - SetVert

    func setVert(scene: String, x: Int, y: Int, open: Bool) {
        let key = scene.uppercased()
        let vert = GridVert(x: x, y: y)
        if open {
            dynamicClosedVerts[key, default: []].remove(vert)
            dynamicOpenVerts[key, default: []].insert(vert)
        } else {
            dynamicOpenVerts[key, default: []].remove(vert)
            dynamicClosedVerts[key, default: []].insert(vert)
        }
    }

    func closedVertsOverrides(forScene scene: String) -> (opened: Set<GridVert>, closed: Set<GridVert>) {
        let key = scene.uppercased()
        return (dynamicOpenVerts[key] ?? [], dynamicClosedVerts[key] ?? [])
    }

    // MARK: - Inventory

    func addItem(_ name: String, to character: String? = nil) {
        let char = character ?? activeCharacter
        let key = name.lowercased()
        if !inventories[char, default: []].contains(key) {
            inventories[char, default: []].append(key)
        }
    }

    func deleteItem(_ name: String, from character: String? = nil) {
        let char = character ?? activeCharacter
        inventories[char]?.removeAll { $0 == name.lowercased() }
    }

    func hasItem(_ name: String) -> Bool {
        inventory.contains(name.lowercased())
    }

    // MARK: - Variables

    func getInt(_ name: String) -> Int {
        intVars[name] ?? 0
    }

    func setInt(_ name: String, value: Int) {
        intVars[name] = value
    }

    func getChar(_ name: String) -> String {
        charVars[name] ?? ""
    }

    func setChar(_ name: String, value: String) {
        charVars[name] = value
    }

    // MARK: - Characters

    func character(_ name: String) -> CharacterState? {
        characters[name]
    }

    func setCharacterPosition(_ name: String, x: Int? = nil, y: Int? = nil, z: Int? = nil) {
        guard characters[name] != nil else { return }
        if let x { characters[name]!.gridX = x }
        if let y { characters[name]!.gridY = y }
        if let z { characters[name]!.z = z }
    }

    func setCharacterVisible(_ name: String, visible: Bool) {
        characters[name]?.isVisible = visible
    }

    func setCharacterDirection(_ name: String, direction: Int) {
        characters[name]?.direction = direction
    }

    func setCharacterRest(_ name: String, script: String?) {
        characters[name]?.restScript = script
    }

    // MARK: - Text

    func text(at index: Int) -> String? {
        textDB?[index]
    }

    // Полный сброс для «Начать новую игру» (перед повторным initialize)
    func resetAll() {
        intVars = [:]
        charVars = [:]
        inventories = [:]
        characters = [:]
        objectStates = [:]
        objectPositionOverrides = [:]
        dynamicOpenVerts = [:]
        dynamicClosedVerts = [:]
        currentScene = ""
        activeCharacter = "Roby"
        barVisible = true
        mouseEnabled = true
        mapEnabled = false
        currentMusic = ""
    }

    // MARK: - Save / Load

    func makeSave(selectedItem: String?) -> SaveData {
        SaveData(
            intVars: intVars,
            charVars: charVars,
            inventories: inventories,
            characters: characters.mapValues {
                SaveData.CharSave(x: $0.gridX, y: $0.gridY, z: $0.z, dir: $0.direction,
                                  visible: $0.isVisible, rest: $0.restScript)
            },
            objectStates: objectStates,
            objectPositions: objectPositionOverrides.mapValues { $0.mapValues { [$0.x, $0.y] } },
            openVerts: dynamicOpenVerts.mapValues { $0.map { [$0.x, $0.y] } },
            closedVerts: dynamicClosedVerts.mapValues { $0.map { [$0.x, $0.y] } },
            currentScene: currentScene,
            activeCharacter: activeCharacter,
            currentMusic: currentMusic,
            selectedItem: selectedItem,
            mapEnabled: mapEnabled
        )
    }

    func restore(from save: SaveData) {
        intVars = save.intVars
        charVars = save.charVars
        inventories = save.inventories
        // Миграция: до фикса "AddItem Frid, confr" попадал одной строкой
        // в инвентарь активного персонажа — раздаём адресатам
        for (owner, items) in inventories {
            for entry in items where entry.contains(",") {
                let parts = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                inventories[owner]?.removeAll { $0 == entry }
                if parts.count >= 2 {
                    addItem(parts[1], to: parts[0].capitalized)
                    fputs("[GameState] миграция: \(entry) → \(parts[0].capitalized).\(parts[1])\n", stderr)
                }
            }
        }
        characters = save.characters.mapValues {
            CharacterState(gridX: $0.x, gridY: $0.y, z: $0.z, direction: $0.dir,
                           isVisible: $0.visible, restScript: $0.rest)
        }
        objectStates = save.objectStates
        objectPositionOverrides = save.objectPositions.mapValues {
            $0.compactMapValues { $0.count >= 2 ? (x: $0[0], y: $0[1]) : nil }
        }
        dynamicOpenVerts = save.openVerts.mapValues {
            Set($0.compactMap { $0.count >= 2 ? GridVert(x: $0[0], y: $0[1]) : nil })
        }
        dynamicClosedVerts = save.closedVerts.mapValues {
            Set($0.compactMap { $0.count >= 2 ? GridVert(x: $0[0], y: $0[1]) : nil })
        }
        currentScene = save.currentScene
        activeCharacter = save.activeCharacter
        currentMusic = save.currentMusic
        // Старые сейвы без поля: карта доступна, если остров уже осознан
        mapEnabled = save.mapEnabled ?? (intVars["Island"] == 1)
    }

    // MARK: - Debug

    func dumpState() {
        fputs("[GameState] scene=\(currentScene)\n", stderr)
        fputs("[GameState] chars: \(characters.map { "\($0.key)(\($0.value.gridX),\($0.value.gridY) z=\($0.value.z) vis=\($0.value.isVisible))" }.joined(separator: ", "))\n", stderr)
        fputs("[GameState] inventories: \(inventories)\n", stderr)
        let nonZero = intVars.filter { $0.value != 0 }
        if !nonZero.isEmpty {
            fputs("[GameState] intVars(!=0): \(nonZero)\n", stderr)
        }
    }
}
