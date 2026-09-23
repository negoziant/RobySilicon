import SpriteKit
import ResourceKit

protocol CharacterNodeDelegate: AnyObject {
    func characterDidFinishWalking(_ node: CharacterNode)
    func characterDidExecuteCommand(_ node: CharacterNode, command: FSCommand)
}

extension CharacterNodeDelegate {
    func characterDidFinishWalking(_ node: CharacterNode) {}
    func characterDidExecuteCommand(_ node: CharacterNode, command: FSCommand) {}
}

final class CharacterNode: SKNode {
    let characterName: String
    weak var delegate: CharacterNodeDelegate?
    private let loader: ResourceLoader

    private let spriteNode = SKSpriteNode()
    private var gridPixelX = 0
    private var gridPixelY = 0
    private var storedZPerGrid = 0
    private var storedGridY = 0
    private var storedZ = 0

    var fonScripts: [String] = []
    var walkingMap: WalkingAnimationMap?
    var scenePalette: COLPalette? // экран 8-битный: рендер всегда палитрой сцены
    var sceneName: String = ""    // для сценовых D-вариантов idle-скриптов
    var direction: Int = 5
    private var idlePause: TimeInterval { .random(in: 30...60) }
    private var idleIndex = -1

    enum State {
        case idle
        case walking
    }
    private(set) var state: State = .idle

    // Walking state
    private var walkQueue: [(fsName: String, endDir: Int)] = []
    private var currentFS: FrameSequence?
    private var preRenderedFrames: [ResourceLoader.RenderedFrame] = []
    private var walkFrameIndex = 0
    private var commandIndex = 0
    private var waitUntil: TimeInterval = 0

    init(characterName: String, loader: ResourceLoader) {
        self.characterName = characterName
        self.loader = loader
        super.init()
        spriteNode.anchorPoint = CGPoint(x: 0, y: 1)
        addChild(spriteNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadFrames(fs: FrameSequence, fsName: String) throws -> [ResourceLoader.RenderedFrame] {
        try loader.renderedFrames(fs: fs,
                                  cacheKey: "CHAR|\(characterName)|\(fsName)|\(sceneName)",
                                  palette: scenePalette)
    }

    // MARK: - Idle

    func startIdle() {
        state = .idle
        direction = 5 // rest-позы всегда лицом к камере
        spriteNode.removeAction(forKey: "walk")
        guard !fonScripts.isEmpty else { return }
        // После остановки персонаж просто стоит (последний кадр rg_X5 — rest-
        // поза); fon-анимация играет только после паузы. Без текстуры (первое
        // размещение на сцене) — играем сразу, чтобы персонаж не был невидим.
        if spriteNode.texture == nil {
            playNextIdle()
            return
        }
        spriteNode.removeAllActions()
        let wait = SKAction.wait(forDuration: idlePause)
        let play = SKAction.run { [weak self] in self?.playNextIdle() }
        spriteNode.run(SKAction.sequence([wait, play]), withKey: "idle")
    }

    private func playNextIdle() {
        // fon-скрипты по кругу: head → ok0 → roby1 → … (roby1 в сценах
        // может иметь D-вариант с репликами — «Я пить хочу...»)
        idleIndex = (idleIndex + 1) % fonScripts.count
        playIdleAnimation(fsName: fonScripts[idleIndex])
    }

    func playIdleAnimation(fsName: String) {
        state = .idle
        spriteNode.removeAllActions()

        do {
            guard let fs = try loader.loadIdleFS(named: fsName, charName: characterName, sceneName: sceneName) else {
                fputs("[CharNode] FS \(fsName) not found in \(characterName)\n", stderr)
                return
            }
            let frames = try loadFrames(fs: fs, fsName: fsName)
            currentFS = fs
            applyPosition()

            var actions = buildSpriteActions(fs: fs, renderedFrames: frames)
            actions.append(SKAction.wait(forDuration: idlePause))
            actions.append(SKAction.run { [weak self] in self?.playNextIdle() })
            spriteNode.run(SKAction.sequence(actions), withKey: "idle")
        } catch {
            fputs("[CharNode] Error loading idle \(fsName): \(error)\n", stderr)
        }
    }

    // MARK: - Walking

    // rg_FT двигает на одну клетку по ПЕРВОЙ цифре F и поворачивает к T;
    // 5 = rest (лицом к камере), rg_5X — поворот на месте, rg_X5 — шаг + стоп.
    // Путь [d1..dn] → rg_{dir}{d1} (поворот) → rg_{d1}{d2} → … → rg_{dn}5.
    func walk(path: [Int]) {
        guard !path.isEmpty, let map = walkingMap else {
            delegate?.characterDidFinishWalking(self)
            return
        }
        state = .walking
        spriteNode.removeAllActions()
        walkQueue = []
        if direction != path[0], let turn = map.fsName(from: direction, to: path[0]) {
            walkQueue.append((turn, path[0]))
        }
        for i in 0..<path.count {
            let moveDir = path[i]
            let nextDir = i + 1 < path.count ? path[i + 1] : 5
            if let fsName = map.fsName(from: moveDir, to: nextDir) {
                walkQueue.append((fsName, nextDir))
            } else {
                fputs("[CharNode] No walk anim \(characterName) rg_\(moveDir)\(nextDir)\n", stderr)
            }
        }
        startNextStep()
    }

    private func startNextStep() {
        guard !walkQueue.isEmpty else {
            state = .idle
            delegate?.characterDidFinishWalking(self)
            startIdle()
            return
        }

        let step = walkQueue.removeFirst()

        do {
            guard let fs = try loader.loadCharacterFS(named: step.fsName, charName: characterName) else {
                fputs("[CharNode] Walk FS \(step.fsName) not found\n", stderr)
                direction = step.endDir
                startNextStep()
                return
            }
            preRenderedFrames = try loadFrames(fs: fs, fsName: step.fsName)
            currentFS = fs
            walkFrameIndex = 0
            commandIndex = 0
            waitUntil = 0
            direction = step.endDir
            applyMovementCommands(fs: fs)
            applyPosition()
            processWalkCommands(at: CACurrentMediaTime())
        } catch {
            fputs("[CharNode] Error loading walk \(step.fsName): \(error)\n", stderr)
            direction = step.endDir
            startNextStep()
        }
    }

    // Вся анимация шага рисуется относительно клетки НАЗНАЧЕНИЯ: rest-поза
    // ложится верхним левым углом в gridPixel только после применения Shift.
    // Поэтому Shift/Set X,Y применяются до первого кадра, а не по ходу скрипта.
    private func applyMovementCommands(fs: FrameSequence) {
        for cmd in fs.commands {
            switch cmd {
            case .shift(_, let axis, _) where axis.uppercased() != "Z":
                delegate?.characterDidExecuteCommand(self, command: cmd)
            case .set(_, let axis, _) where axis.uppercased() != "Z":
                delegate?.characterDidExecuteCommand(self, command: cmd)
            default:
                break
            }
        }
    }

    func tick(_ currentTime: TimeInterval) {
        guard state == .walking, currentFS != nil else { return }
        if currentTime >= waitUntil {
            processWalkCommands(at: currentTime)
        }
    }

    private func processWalkCommands(at time: TimeInterval) {
        guard let fs = currentFS else { return }

        while commandIndex < fs.commands.count {
            let cmd = fs.commands[commandIndex]
            commandIndex += 1

            switch cmd {
            case .frame:
                guard walkFrameIndex < preRenderedFrames.count else { continue }
                let frame = preRenderedFrames[walkFrameIndex]
                walkFrameIndex += 1
                spriteNode.texture = frame.texture
                spriteNode.size = frame.texture.size()
                spriteNode.position = CGPoint(x: frame.offsetX, y: -frame.offsetY)

            case .delay(let ms):
                let seconds = Double(abs(ms)) / 1000.0 / GameSettings.speedFactor
                waitUntil = time + seconds
                return

            case .shift:
                break // X/Y применены в applyMovementCommands при старте шага

            case .set(_, let axis, _):
                if axis.uppercased() == "Z" {
                    delegate?.characterDidExecuteCommand(self, command: cmd)
                }

            case .sound:
                delegate?.characterDidExecuteCommand(self, command: cmd)

            default:
                delegate?.characterDidExecuteCommand(self, command: cmd)
            }
        }

        startNextStep()
    }

    // MARK: - Position

    func updatePosition(config: SceneConfig, gridX: Int, gridY: Int, zPerGrid: Int, z: Int = 0) {
        gridPixelX = config.leftTopGrid.0 + gridX * config.gridSize.0 + config.gridShift.0
        gridPixelY = config.leftTopGrid.1 + gridY * config.gridSize.1 + config.gridShift.1
        storedZPerGrid = zPerGrid
        storedGridY = gridY
        storedZ = z
        applyPosition()
    }

    func stopAll() {
        spriteNode.removeAllActions()
        spriteNode.texture = nil
        state = .idle
        direction = 5
        currentFS = nil
        preRenderedFrames = []
        walkQueue = []
    }

    private func applyPosition() {
        let shiftX = currentFS?.shiftX ?? 0
        let shiftY = currentFS?.shiftY ?? 0
        position = CGPoint(x: CGFloat(gridPixelX - shiftX), y: CGFloat(-(gridPixelY - shiftY)))
        // Глубина как у объектов: ряд*ZPerGrid + подслой z (Set Roby.Z из FS)
        zPosition = CGFloat(storedZPerGrid * storedGridY + storedZ)
    }

    private func buildSpriteActions(fs: FrameSequence, renderedFrames: [ResourceLoader.RenderedFrame]) -> [SKAction] {
        var actions: [SKAction] = []
        var frameIdx = 0
        for cmd in fs.commands {
            switch cmd {
            case .frame:
                guard frameIdx < renderedFrames.count else { continue }
                let frame = renderedFrames[frameIdx]
                frameIdx += 1
                let setTex = SKAction.run { [weak self] in
                    guard let self else { return }
                    self.spriteNode.texture = frame.texture
                    self.spriteNode.size = frame.texture.size()
                    self.spriteNode.position = CGPoint(x: frame.offsetX, y: -frame.offsetY)
                }
                actions.append(setTex)
            case .delay(let ms):
                let duration = Double(abs(ms)) / 1000.0 / GameSettings.speedFactor
                if duration > 0 {
                    actions.append(SKAction.wait(forDuration: duration))
                }
            default:
                // D-варианты idle-скриптов содержат Text/SetRest/Sound —
                // исполняем по таймлайну через делегата
                actions.append(SKAction.run { [weak self] in
                    guard let self else { return }
                    self.delegate?.characterDidExecuteCommand(self, command: cmd)
                })
            }
        }
        if actions.isEmpty {
            actions.append(SKAction.wait(forDuration: 0.1))
        }
        return actions
    }
}
