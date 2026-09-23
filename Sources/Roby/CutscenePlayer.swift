import SpriteKit
import ResourceKit

protocol CutscenePlayerDelegate: AnyObject {
    func cutsceneDidFinish(_ player: CutscenePlayer)
    func cutsceneDidShowText(_ player: CutscenePlayer, text: String)
    func cutsceneDidRequestSceneChange(_ player: CutscenePlayer, params: [String])
    func cutsceneDidChangeObjectState(_ player: CutscenePlayer, scene: String, object: String, active: Bool)
    func cutsceneDidChangeCharacter(_ player: CutscenePlayer, name: String)
    func cutsceneDidRequestAproach(_ player: CutscenePlayer, character: String, object: String, offsetX: Int, offsetY: Int)
    func cutsceneDidChangeInventory(_ player: CutscenePlayer)
    func cutsceneDidChangeBar(_ player: CutscenePlayer, visible: Bool)
    func cutsceneDidShiftScreen(_ player: CutscenePlayer, dx: Int, dy: Int)
    func cutsceneDidSetVert(_ player: CutscenePlayer, x: Int, y: Int, open: Bool)
    func cutsceneDidSetActiveItem(_ player: CutscenePlayer, item: String)
    func cutsceneDidDeleteItem(_ player: CutscenePlayer, item: String)
    func cutsceneDidPlaySound(_ player: CutscenePlayer, name: String)
    func cutsceneDidSetMusic(_ player: CutscenePlayer, name: String)
    func cutsceneDidRequestMiniGame(_ player: CutscenePlayer, number: Int, resultVar: String, stateVar: String)
}

extension CutscenePlayerDelegate {
    func cutsceneDidShowText(_ player: CutscenePlayer, text: String) {}
    func cutsceneDidRequestSceneChange(_ player: CutscenePlayer, params: [String]) {}
    func cutsceneDidChangeObjectState(_ player: CutscenePlayer, scene: String, object: String, active: Bool) {}
    func cutsceneDidChangeCharacter(_ player: CutscenePlayer, name: String) {}
    func cutsceneDidRequestAproach(_ player: CutscenePlayer, character: String, object: String, offsetX: Int, offsetY: Int) {}
    func cutsceneDidChangeInventory(_ player: CutscenePlayer) {}
    func cutsceneDidChangeBar(_ player: CutscenePlayer, visible: Bool) {}
    func cutsceneDidShiftScreen(_ player: CutscenePlayer, dx: Int, dy: Int) {}
    func cutsceneDidSetVert(_ player: CutscenePlayer, x: Int, y: Int, open: Bool) {}
    func cutsceneDidSetActiveItem(_ player: CutscenePlayer, item: String) {}
    func cutsceneDidDeleteItem(_ player: CutscenePlayer, item: String) {}
    func cutsceneDidPlaySound(_ player: CutscenePlayer, name: String) {}
    func cutsceneDidSetMusic(_ player: CutscenePlayer, name: String) {}
    func cutsceneDidRequestMiniGame(_ player: CutscenePlayer, number: Int, resultVar: String, stateVar: String) {}
}

final class CutscenePlayer: SKNode {
    weak var delegate: CutscenePlayerDelegate?

    private let movie: CompositeMovie
    private let fs: FrameSequence
    private let spriteNode = SKSpriteNode()
    private weak var gameState: GameState?

    private var commandIndex = 0
    private var waitUntil: TimeInterval = 0
    private var pendingWait: TimeInterval = 0
    private var isPlaying = false
    private var skipDepth = 0

    // Интерактивная пауза: SetMouse ON + LockBar ON посреди фильма (кадр с
    // Delay -5000) — персонаж «держит предмет», клики игрока разрешены и
    // прерывают фильм (ROROPBAN кадр 40, ROHANRP1 кадр 13)
    private(set) var mouseWindowOpen = false
    private(set) var barLocked = false

    // Пропуск (Escape): оставшиеся команды исполняются мгновенно — состояние
    // (SetVar/Set/AddItem/...) доигрывается, кадры/звуки/тексты/паузы
    // пропускаются; Aproach при пропуске телепортирует (GameScene)
    private(set) var skipping = false

    init(movie: CompositeMovie, fs: FrameSequence, gameState: GameState? = nil) {
        self.movie = movie
        self.fs = fs
        self.gameState = gameState
        super.init()

        spriteNode.anchorPoint = CGPoint(x: 0, y: 1)
        addChild(spriteNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    func play() {
        isPlaying = true
        commandIndex = 0
        waitUntil = 0
        pendingWait = 0
        skipDepth = 0
        mouseWindowOpen = false
        barLocked = false
        movie.clearCanvas()
        processCommands(at: CACurrentMediaTime())
    }

    func stop() {
        isPlaying = false
        spriteNode.texture = nil
    }

    func resume() {
        isPlaying = true
        processCommands(at: CACurrentMediaTime())
    }

    func skipToEnd() {
        guard !skipping else { return }
        fputs("[Cutscene] пропуск\n", stderr)
        skipping = true
        pendingWait = 0
        waitUntil = 0
        isPlaying = true
        processCommands(at: CACurrentMediaTime())
    }

    func tick(_ currentTime: TimeInterval) {
        guard isPlaying else { return }
        if currentTime >= waitUntil {
            processCommands(at: currentTime)
        }
    }

    // Семантика блока кадра как в оригинале: кадр показывается, все команды
    // до следующего Frame выполняются сразу, Delay лишь накапливает паузу
    // перед показом следующего кадра. Иначе Set/Shift после Delay исполнялись
    // бы с опозданием и катсцена прыгала бы посреди воспроизведения (ROBAWAKE).
    private func processCommands(at time: TimeInterval) {
        while commandIndex < fs.commands.count {
            let cmd = fs.commands[commandIndex]

            if case .frame = cmd, skipDepth == 0, pendingWait > 0, !skipping {
                waitUntil = time + pendingWait
                pendingWait = 0
                return
            }
            commandIndex += 1

            if skipDepth > 0 {
                switch cmd {
                case .ifCondition:
                    skipDepth += 1
                case .endIf:
                    skipDepth -= 1
                default:
                    break
                }
                continue
            }

            switch cmd {
            case .frame(let index, _):
                // Кадры MV самодостаточны: RLE нигде не красит индекс 0, т.е.
                // стирать предыдущий кадр нечем — delta не композитинг.
                // Пропуск в SCR (индекс 0) — удержание предыдущего кадра.
                guard !skipping else { break }
                movie.clearCanvas()
                if movie.applyFrame(logicalIndex: index) {
                    updateTexture()
                }

            case .delay(let ms):
                guard !skipping else { break }
                pendingWait += Double(abs(ms)) / 1000.0 / GameSettings.speedFactor

            case .ifCondition(let variable, let value):
                guard let gs = gameState else {
                    skipDepth = 1
                    continue
                }
                let current = gs.getInt(variable)
                let expected = Int(value) ?? 0
                if current != expected {
                    skipDepth = 1
                }

            case .endIf:
                break

            case .setVar(let name, let value):
                gameState?.setInt(name, value: Int(value) ?? 0)
                fputs("[Script] SetVar \(name)=\(value)\n", stderr)

            case .setCharVar(let name, let value):
                let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                gameState?.setChar(name, value: clean)
                fputs("[Script] SetCharVar \(name)=\(clean)\n", stderr)

            case .addItem(let name, let character):
                // "AddItem Frid, confr" — предмет адресату, не активному персонажу
                gameState?.addItem(name, to: character.isEmpty ? nil : character.capitalized)
                delegate?.cutsceneDidChangeInventory(self)
                fputs("[Script] AddItem \(name)\(character.isEmpty ? "" : " → \(character)")\n", stderr)

            case .deleteItem(let name, let character):
                gameState?.deleteItem(name, from: character.isEmpty ? nil : character.capitalized)
                delegate?.cutsceneDidDeleteItem(self, item: name)
                delegate?.cutsceneDidChangeInventory(self)
                fputs("[Script] DeleteItem \(name)\(character.isEmpty ? "" : " ← \(character)")\n", stderr)

            case .setActive(let name):
                delegate?.cutsceneDidSetActiveItem(self, item: name)
                fputs("[Script] SetActive \(name)\n", stderr)

            case .lockBar(let state):
                barLocked = state.uppercased() == "ON"
                fputs("[Script] LockBar \(state)\n", stderr)

            case .createObject(let scene, let obj, let character, let x, let y):
                gameState?.setObjectActive(scene: scene, object: obj, active: true)
                // 4-арг форма: x,y — абсолютная клетка; 5-арг: смещение от персонажа
                if character.isEmpty {
                    gameState?.setObjectPosition(scene: scene, object: obj, x: x, y: y)
                } else if let ch = gameState?.character(character) {
                    gameState?.setObjectPosition(scene: scene, object: obj, x: ch.gridX + x, y: ch.gridY + y)
                }
                delegate?.cutsceneDidChangeObjectState(self, scene: scene, object: obj, active: true)
                fputs("[Script] CreateObject \(scene).\(obj) char=\(character) (\(x),\(y))\n", stderr)

            case .delObject(let scene, let obj, _, _, _):
                gameState?.setObjectActive(scene: scene, object: obj, active: false)
                delegate?.cutsceneDidChangeObjectState(self, scene: scene, object: obj, active: false)
                fputs("[Script] DelObject \(scene).\(obj)\n", stderr)

            case .set(let target, let axis, let value):
                if let v = Int(value) {
                    switch axis.uppercased() {
                    case "X": gameState?.setCharacterPosition(target, x: v)
                    case "Y": gameState?.setCharacterPosition(target, y: v)
                    case "Z": gameState?.setCharacterPosition(target, z: v)
                    default: break
                    }
                    delegate?.cutsceneDidChangeCharacter(self, name: target)
                    fputs("[Script] Set \(target).\(axis)=\(value)\n", stderr)
                }

            case .shift(let target, let axis, let value):
                if let delta = Int(value), let gs = gameState, let ch = gs.character(target) {
                    switch axis.uppercased() {
                    case "X": gs.setCharacterPosition(target, x: ch.gridX + delta)
                    case "Y": gs.setCharacterPosition(target, y: ch.gridY + delta)
                    case "Z": gs.setCharacterPosition(target, z: ch.z + delta)
                    default: break
                    }
                    delegate?.cutsceneDidChangeCharacter(self, name: target)
                    fputs("[Script] Shift \(target).\(axis) += \(delta)\n", stderr)
                }

            case .showChar(let name):
                gameState?.setCharacterVisible(name, visible: true)
                delegate?.cutsceneDidChangeCharacter(self, name: name)
                fputs("[Script] ShowChar \(name)\n", stderr)

            case .hideChar(let name):
                gameState?.setCharacterVisible(name, visible: false)
                delegate?.cutsceneDidChangeCharacter(self, name: name)
                fputs("[Script] HideChar \(name)\n", stderr)

            case .setBar(let state):
                let visible = state.uppercased() == "ON"
                gameState?.barVisible = visible
                delegate?.cutsceneDidChangeBar(self, visible: visible)
                fputs("[Script] SetBar \(state)\n", stderr)

            case .startGame(let number, let resultVar, let stateVar):
                fputs("[Script] StartGame \(number) → \(resultVar)/\(stateVar)\n", stderr)
                isPlaying = false
                delegate?.cutsceneDidRequestMiniGame(self, number: number, resultVar: resultVar, stateVar: stateVar)
                return

            case .setMap(let state):
                gameState?.mapEnabled = state.uppercased() == "ON"
                delegate?.cutsceneDidChangeBar(self, visible: gameState?.barVisible ?? true)
                fputs("[Script] SetMap \(state)\n", stderr)

            case .setMouse(let state):
                let on = state.uppercased() == "ON"
                gameState?.mouseEnabled = on
                mouseWindowOpen = on
                fputs("[Script] SetMouse \(state)\n", stderr)

            case .setMusic(let name):
                gameState?.currentMusic = name
                delegate?.cutsceneDidSetMusic(self, name: name)
                fputs("[Script] SetMusic \(name)\n", stderr)

            case .setRest(let character, _, let script):
                gameState?.setCharacterRest(character, script: script)
                delegate?.cutsceneDidChangeCharacter(self, name: character)
                fputs("[Script] SetRest \(character) -> \(script)\n", stderr)

            case .setVert(let x, let y, let state):
                let open = state.uppercased() != "CLOSE"
                delegate?.cutsceneDidSetVert(self, x: x, y: y, open: open)
                fputs("[Script] SetVert (\(x),\(y))=\(state)\n", stderr)

            case .text(let index, _):
                guard !skipping else { break }
                if let text = gameState?.text(at: index) {
                    delegate?.cutsceneDidShowText(self, text: text)
                    fputs("[Script] Text[\(index)]: \(text.prefix(40))\n", stderr)
                }

            case .sound(let name, _):
                guard !skipping else { break }
                delegate?.cutsceneDidPlaySound(self, name: name)

            case .shiftScreen(let dx, let dy):
                delegate?.cutsceneDidShiftScreen(self, dx: dx, dy: dy)
                fputs("[Script] ShiftScreen (\(dx),\(dy))\n", stderr)

            case .aproach(let character, let object, let ox, let oy):
                fputs("[Script] Aproach \(character) -> \(object) offset=(\(ox),\(oy))\n", stderr)
                isPlaying = false
                delegate?.cutsceneDidRequestAproach(self, character: character, object: object, offsetX: ox, offsetY: oy)
                return

            case .goScene(let params):
                fputs("[Script] GoScene \(params.joined(separator: ","))\n", stderr)
                isPlaying = false
                delegate?.cutsceneDidRequestSceneChange(self, params: params)
                return
            }
        }

        // Дать последнему кадру отвисеть свой Delay перед завершением
        if pendingWait > 0 {
            waitUntil = time + pendingWait
            pendingWait = 0
            return
        }

        isPlaying = false
        delegate?.cutsceneDidFinish(self)
    }

    private func updateTexture() {
        guard let r = movie.renderCanvasCropped() else { return }
        let tex = SKTexture(cgImage: r.image)
        tex.filteringMode = .nearest
        spriteNode.texture = tex
        spriteNode.size = tex.size()
        spriteNode.position = CGPoint(x: CGFloat(r.x), y: CGFloat(-r.y))
    }
}
