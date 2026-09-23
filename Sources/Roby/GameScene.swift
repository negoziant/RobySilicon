import SpriteKit
import ResourceKit

final class GameScene: SKScene, BarPanelDelegate, CutscenePlayerDelegate, CharacterNodeDelegate {
    private let loader = ResourceLoader()
    private lazy var soundManager = SoundManager(gameDataPath: loader.gameDataPath)
    private var skipAutoEntry = false
    private var menuOverlay: MenuOverlay?
    private var saveLoadOverlay: SaveLoadOverlay?
    private var miniGameNode: MiniGameNodeProtocol?
    private var gameStarted = false
    private var startupConfig: StartupConfig?
    private var startupTexts: TextDatabase?
    private var backgroundNode: SKSpriteNode?
    private var barNode: SKSpriteNode?
    private var barPanel: BarPanel?
    private var fadeOverlay: SKSpriteNode?
    private var sceneConfig: SceneConfig?
    private var currentFAD: FADTable?
    private var currentPalette: COLPalette?
    private var currentNGB: NGBImage?

    private let viewportWidth: CGFloat = 640
    private let sceneAreaHeight: CGFloat = 400
    private let barHeight: CGFloat = 80

    private var scrollOffset: CGFloat = 0
    private var backgroundWidth: CGFloat = 0
    private var maxScroll: CGFloat { max(0, backgroundWidth - viewportWidth) }

    private var animationNodes: [FSAnimationNode] = []
    private var cutscenePlayer: CutscenePlayer?
    private var cutsceneAnchor: (character: String, fs: FrameSequence)?
    private var objectDefs: [String: ObjectDef] = [:]
    private var characterNodes: [String: CharacterNode] = [:]
    private var characterConfigs: [String: CharacterConfig] = [:]
    private var walkingMaps: [String: WalkingAnimationMap] = [:]
    private var pendingAproachResume: CutscenePlayer?
    private var pendingEntryFS: String?
    private var pendingEntryChar: String?
    private var pendingEntryGridX: Int = 0
    private var pendingEntryGridY: Int = 0

    private var currentSceneName = "SCENA0"
    private var sceneNames: [String] = []
    private var hoveredObjectName: String? = nil
    let gameState = GameState()
    private var selectedItemName: String? = nil

    // Item name → BAR sprite pair index из BAR.BAR (порядок Items канонический):
    // предмет i → спрайты BAR(6+i*2) обычный / BAR(7+i*2) подсвеченный
    private var itemNameToIndex: [String: Int] = [:]
    private var indexToItemName: [Int: String] = [:]
    private var barConfig: BarConfig?

    override func didMove(to view: SKView) {
        backgroundColor = .black
        anchorPoint = CGPoint(x: 0, y: 0)

        do {
            let startup = try loader.loadStartup()
            startupConfig = startup.config
            startupTexts = startup.texts
            sceneNames = startup.config.scenes.map { $0.name.uppercased() }
            gameState.initialize(startup: startup.config, texts: startup.texts)
            currentSceneName = gameState.currentScene
            loadCharacterConfigs()

            let bar = try loader.loadBarConfig()
            barConfig = bar
            itemNameToIndex = bar.itemIndex
            for (name, idx) in itemNameToIndex { indexToItemName[idx] = name }
            fputs("[GameScene] BAR.BAR: \(bar.items.count) items\n", stderr)

            fputs("[GameScene] \(sceneNames.count) scenes loaded, start=\(currentSceneName)\n", stderr)
        } catch {
            fputs("[GameScene] Failed to load startup: \(error)\n", stderr)
            sceneNames = (0...8).map { "SCENA\($0)" }
        }

        showMenu()

        // Дебаг-хук: ROBY_MINIGAME=N [ROBY_STATE=v] [ROBY_SHOT=path] — сразу
        // открыть мини-игру N; со снимком через 3с в path (для проверки рендера)
        let env = ProcessInfo.processInfo.environment
        if let numStr = env["ROBY_MINIGAME"], let num = Int(numStr) {
            menuOverlay?.removeFromParent()
            menuOverlay = nil
            gameState.setInt("DebugState", value: Int(env["ROBY_STATE"] ?? "7") ?? 7)
            startMiniGame(number: num, resultVar: "DebugResult", stateVar: "DebugState") {
                fputs("[Debug] мини-игра завершена\n", stderr)
            }
            if env["ROBY_AUTO"] == "organ" { autoplayOrgan() }
        }
        if let shotPath = env["ROBY_SHOT"] {
            let delay = Double(env["ROBY_SHOT_DELAY"] ?? "3") ?? 3
            run(.sequence([
                .wait(forDuration: delay),
                .run { [weak self] in
                    self?.saveScreenshot(to: shotPath)
                    exit(0)
                },
            ]))
        }
    }

    // Автотест органа: правильная расстановка [3,1,2,4,5,6,7,8] и клик по органу
    private func autoplayOrgan() {
        // (id предмета, зона): зона0=id2, зона1=id0, ... по проверке победы
        let placement: [(id: Int, zone: Int)] =
            [(2, 0), (0, 1), (1, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7)]
        var actions: [SKAction] = [.wait(forDuration: 0.5)]
        for (id, zone) in placement {
            actions.append(.run { [weak self] in
                // взять из стойки (центр бокса 78×78 в (id*80, 5), y экрана→сцены)
                self?.miniGameNode?.handleMouseDown(
                    at: CGPoint(x: CGFloat(id * 80 + 39), y: 480 - 44))
            })
            actions.append(.wait(forDuration: 0.15))
            actions.append(.run { [weak self] in
                self?.miniGameNode?.handleMouseDown(
                    at: CGPoint(x: CGFloat(-2 + zone * 75 + 37), y: 480 - 435))
            })
            actions.append(.wait(forDuration: 0.15))
        }
        actions.append(.run { [weak self] in
            self?.miniGameNode?.handleMouseDown(at: CGPoint(x: 233, y: 480 - 250))
        })
        run(.sequence(actions))
    }

    private func saveScreenshot(to path: String) {
        guard let view = self.view, let tex = view.texture(from: self) else { return }
        let img = tex.cgImage()
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            fputs("[Debug] скриншот → \(path)\n", stderr)
        }
    }

    // MARK: - Menu

    private func showMenu() {
        guard menuOverlay == nil else { return }
        let menu = MenuOverlay(loader: loader)
        menu.zPosition = 1000
        menu.onNewGame = { [weak self] in self?.startNewGame() }
        menu.onContinue = { [weak self] in
            guard let self, self.gameStarted else { return }
            self.hideMenu()
        }
        menu.onLoad = { [weak self] in
            guard let self else { return }
            self.hideMenu()
            self.showSaveLoad(mode: .load)
        }
        menu.onSave = { [weak self] in
            guard let self, self.gameStarted else { return }
            self.hideMenu()
            self.showSaveLoad(mode: .save)
        }
        menu.onQuit = { NSApp.terminate(nil) }
        menu.onSliderChanged = { [weak self] index, value in
            switch index {
            case 0: GameSettings.effectsVolume = value
            case 1: GameSettings.musicVolume = value
            default: GameSettings.gameSpeed = value
            }
            self?.soundManager.refreshVolumes()
        }
        menu.onSliderTick = { [weak self] in self?.soundManager.playSlider() }
        addChild(menu)
        menuOverlay = menu
    }

    private func hideMenu() {
        menuOverlay?.removeFromParent()
        menuOverlay = nil
    }

    private func startNewGame() {
        hideMenu()
        soundManager.stopMusic()
        soundManager.stopAmbient()
        gameState.resetAll()
        if let cfg = startupConfig, let texts = startupTexts {
            gameState.initialize(startup: cfg, texts: texts)
        }
        for (name, config) in characterConfigs {
            for item in config.items {
                gameState.addItem(item, to: name)
            }
        }
        selectedItemName = nil
        pendingEntryFS = nil
        pendingEntryChar = nil
        currentSceneName = gameState.currentScene
        gameStarted = true
        loadCurrentScene()
        updateBarState()
    }

    // Клетка объекта: переопределение из CreateObject или позиция из SCN
    private func objectGrid(name: String, defaultX: Int, defaultY: Int) -> (x: Int, y: Int) {
        if let pos = gameState.objectPosition(scene: currentSceneName, object: name) {
            return pos
        }
        return (defaultX, defaultY)
    }

    private func removeAnimations() {
        for node in animationNodes {
            node.stop()
            node.removeFromParent()
        }
        animationNodes.removeAll()
    }

    private func removeCharacters() {
        for (_, node) in characterNodes {
            node.stopAll()
            node.removeFromParent()
        }
        characterNodes.removeAll()
    }

    private func loadCurrentScene() {
        loader.clearFrameCache() // палитра сцены меняется — кэш кадров невалиден
        backgroundNode?.removeFromParent()
        fadeOverlay?.removeFromParent()
        removeAnimations()
        removeCharacters()

        do {
            let sceneData = try loader.loadScene(named: currentSceneName)
            sceneConfig = try loader.loadSceneConfig(named: currentSceneName)
            gameState.initializeObjectStates(forScene: currentSceneName, from: sceneConfig!)
            currentFAD = sceneData.fad
            currentPalette = sceneData.palette
            currentNGB = sceneData.ngb

            if let bgImage = PNGRenderer.render(ngb: sceneData.ngb, palette: sceneData.palette, transparentIndex: nil) {
                let texture = SKTexture(cgImage: bgImage)
                texture.filteringMode = .nearest
                let bgNode = SKSpriteNode(texture: texture)
                bgNode.anchorPoint = CGPoint(x: 0, y: 1)
                bgNode.position = CGPoint(x: 0, y: barHeight + sceneAreaHeight)
                bgNode.zPosition = 0
                addChild(bgNode)

                backgroundNode = bgNode
                backgroundWidth = CGFloat(sceneData.ngb.width)
                scrollOffset = 0
                updateScroll()

                fadeIn()
            }

            loadSceneAnimations()
            loadCharactersOnScene()

            // Звук сцены: эмбиент из активных SoundVariables type=5, музыка по SCN
            if let config = sceneConfig {
                let ambients = config.sounds.filter { $0.type == 5 && $0.isActive }
                if let amb = ambients.randomElement() {
                    soundManager.playAmbient(file: amb.file)
                } else {
                    soundManager.stopAmbient()
                }
                if config.music.lowercased() != "continue", !config.music.isEmpty {
                    soundManager.playMusic(name: config.music)
                }
            }

            if barNode == nil {
                let barData = try loader.loadBarBackground()
                if let barImage = PNGRenderer.render(ngb: barData.ngb, palette: barData.palette, transparentIndex: nil) {
                    let barTexture = SKTexture(cgImage: barImage)
                    barTexture.filteringMode = .nearest
                    let bar = SKSpriteNode(texture: barTexture)
                    bar.anchorPoint = CGPoint(x: 0, y: 0)
                    bar.position = CGPoint(x: 0, y: 0)
                    bar.zPosition = 100
                    addChild(bar)
                    barNode = bar
                }

                let allBar = try loader.loadAllBarSprites()
                let panel = BarPanel()
                panel.position = CGPoint(x: 0, y: 0)
                panel.zPosition = 110
                panel.delegate = self
                panel.setup(sprites: allBar.sprites, palette: allBar.palette)
                addChild(panel)
                barPanel = panel
                updateBarState()
            }
        } catch {
            fputs("[GameScene] Failed to load scene \(currentSceneName): \(error)\n", stderr)
        }

        fputs("[GameScene] \(currentSceneName) loaded\n", stderr)

        if let entryFS = pendingEntryFS {
            let gx = pendingEntryGridX, gy = pendingEntryGridY
            let anchorChar = pendingEntryChar
            pendingEntryFS = nil
            pendingEntryChar = nil
            playCutscene(mvName: "", fsName: entryFS, forScene: currentSceneName,
                         objectGridX: gx, objectGridY: gy, anchorCharacter: anchorChar)
        } else if skipAutoEntry {
            skipAutoEntry = false // загрузка сейва: entry-скрипты не переигрываем
        } else {
            autoPlayEntryScript()
        }
    }

    private func autoPlayEntryScript() {
        guard let config = sceneConfig else { return }
        for obj in config.objects {
            guard gameState.isObjectActive(scene: currentSceneName, object: obj.name),
                  let ob = objectDefs[obj.name.lowercased()],
                  let fonScript = ob.fonScript else { continue }
            do {
                guard let fs = try loader.loadFrameSequence(named: fonScript, forScene: currentSceneName) else { continue }
                let hasGameCommands = fs.commands.contains { cmd in
                    switch cmd {
                    case .goScene, .showChar, .hideChar, .setBar, .setVar, .setCharVar,
                         .addItem, .deleteItem, .createObject, .delObject, .aproach:
                        return true
                    default:
                        return false
                    }
                }
                if hasGameCommands {
                    fputs("[Entry] Auto-play \(fonScript).FS on \(currentSceneName) at grid(\(obj.gridX),\(obj.gridY))\n", stderr)
                    playCutscene(mvName: "", fsName: fonScript, forScene: currentSceneName, objectGridX: obj.gridX, objectGridY: obj.gridY)
                    return
                }
            } catch {}
        }
    }

    private func fadeIn() {
        guard let ngb = currentNGB, let pal = currentPalette, let fad = currentFAD else { return }

        let fadeLevels = [15, 13, 11, 9, 7, 5, 3, 1]
        var textures: [SKTexture] = []
        for level in fadeLevels {
            if let img = PNGRenderer.render(ngb: ngb, palette: pal, transparentIndex: nil, fad: fad, fadeLevel: level) {
                let tex = SKTexture(cgImage: img)
                tex.filteringMode = .nearest
                textures.append(tex)
            }
        }

        guard !textures.isEmpty else { return }

        let overlay = SKSpriteNode(texture: textures[0])
        overlay.anchorPoint = CGPoint(x: 0, y: 1)
        overlay.position = CGPoint(x: 0, y: barHeight + sceneAreaHeight)
        overlay.zPosition = 50
        addChild(overlay)
        fadeOverlay = overlay

        let animate = SKAction.animate(with: textures, timePerFrame: 0.8 / Double(textures.count))
        overlay.run(SKAction.sequence([animate, SKAction.removeFromParent()]))
    }

    private func updateScroll() {
        scrollOffset = max(0, min(scrollOffset, maxScroll))
        backgroundNode?.position.x = -scrollOffset
    }

    private func loadSceneAnimations() {
        guard let config = sceneConfig else { return }

        do {
            objectDefs = try loader.loadObjectDefs(forScene: currentSceneName)
        } catch {
            fputs("[Anim] Error loading animations for \(currentSceneName): \(error)\n", stderr)
            return
        }

        for obj in config.objects {
            guard gameState.isObjectActive(scene: currentSceneName, object: obj.name) else { continue }
            spawnAnimationNode(objectName: obj.name, defaultX: obj.gridX, defaultY: obj.gridY)
        }
    }

    private func spawnAnimationNode(objectName: String, defaultX: Int, defaultY: Int) {
        guard let config = sceneConfig, let bgNode = backgroundNode,
              let ob = objectDefs[objectName.lowercased()],
              let fonScript = ob.fonScript else { return }

        do {
            guard let fs = try loader.loadFrameSequence(named: fonScript, forScene: currentSceneName),
                  !fs.movieName.isEmpty else { return }

            let frames = try loader.renderedFrames(
                fs: fs, cacheKey: "SCEN|\(currentSceneName)|\(fonScript)", palette: currentPalette)
            guard !frames.isEmpty else { return }

            let grid = objectGrid(name: objectName, defaultX: defaultX, defaultY: defaultY)
            let gridPixelX = config.leftTopGrid.0 + grid.x * config.gridSize.0 + config.gridShift.0
            let gridPixelY = config.leftTopGrid.1 + grid.y * config.gridSize.1 + config.gridShift.1
            let renderOriginX = gridPixelX - fs.shiftX
            let renderOriginY = gridPixelY - fs.shiftY

            let animNode = FSAnimationNode(fs: fs, frames: frames)
            animNode.name = objectName.lowercased()
            animNode.onCommand = { [weak self] cmd in self?.handleFonCommand(cmd) }
            animNode.evaluateIf = { [weak self] variable, value in
                guard let self else { return false }
                return self.gameState.getInt(variable) == (Int(value) ?? 0)
            }
            animNode.position = CGPoint(x: CGFloat(renderOriginX), y: CGFloat(-renderOriginY))
            animNode.zPosition = CGFloat(grid.y * config.zPerGrid + ob.zCoord)
            bgNode.addChild(animNode)
            animNode.play(loop: true)
            animationNodes.append(animNode)

            fputs("[Anim] \(objectName) -> \(fonScript).FS (\(frames.count) frames)\n", stderr)
        } catch {
            fputs("[Anim] Error loading \(objectName) for \(currentSceneName): \(error)\n", stderr)
        }
    }

    /// Команды внутри fon-анимаций объектов: одноразовые анимации (пчёлы из
    /// дупла, уплывающие туземцы) завершаются self-DelObject в последнем кадре.
    /// Точечно, без пересборки всех нод — иначе соседние циклы сбрасываются.
    private func handleFonCommand(_ cmd: FSCommand) {
        switch cmd {
        case .createObject(let scene, let obj, let character, let x, let y):
            guard !gameState.isObjectActive(scene: scene, object: obj) else { break }
            gameState.setObjectActive(scene: scene, object: obj, active: true)
            if character.isEmpty {
                gameState.setObjectPosition(scene: scene, object: obj, x: x, y: y)
            } else if let ch = gameState.character(character) {
                gameState.setObjectPosition(scene: scene, object: obj, x: ch.gridX + x, y: ch.gridY + y)
            }
            fputs("[Anim] CreateObject \(scene).\(obj)\n", stderr)
            if scene.uppercased() == currentSceneName,
               let sceneObj = sceneConfig?.objects.first(where: { $0.name.lowercased() == obj.lowercased() }) {
                spawnAnimationNode(objectName: sceneObj.name, defaultX: sceneObj.gridX, defaultY: sceneObj.gridY)
            }

        case .delObject(let scene, let obj, _, _, _):
            guard gameState.isObjectActive(scene: scene, object: obj) else { break }
            gameState.setObjectActive(scene: scene, object: obj, active: false)
            fputs("[Anim] DelObject \(scene).\(obj)\n", stderr)
            if scene.uppercased() == currentSceneName {
                let key = obj.lowercased()
                for node in animationNodes where node.name == key {
                    node.stop()
                    node.removeFromParent()
                }
                animationNodes.removeAll { $0.name == key }
            }

        case .sound(let name, _):
            playSound(named: name)

        case .setVar(let name, let value):
            gameState.setInt(name, value: Int(value) ?? 0)
            fputs("[Anim] SetVar \(name)=\(value)\n", stderr)

        case .setCharVar(let name, let value):
            let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            gameState.setChar(name, value: clean)
            fputs("[Anim] SetCharVar \(name)=\(clean)\n", stderr)

        default:
            break
        }
    }

    // MARK: - Characters

    private func loadCharacterConfigs() {
        for (name, _) in gameState.characters {
            do {
                let config = try loader.loadCharacterConfig(name: name)
                characterConfigs[name] = config
                for item in config.items {
                    gameState.addItem(item, to: name) // стартовые предметы — в инвентарь владельца
                }
                let map = try loader.loadWalkingMap(name: name)
                walkingMaps[name] = map
                fputs("[Char] Loaded \(name).CHR: fonScripts=\(config.fonScripts), items=\(config.items), walkAnims=\(map.count)\n", stderr)
            } catch {
                fputs("[Char] Failed to load \(name): \(error)\n", stderr)
            }
        }
    }

    private func loadCharactersOnScene() {
        guard let config = sceneConfig, let bgNode = backgroundNode else { return }

        for (name, charState) in gameState.characters {
            guard charState.isVisible else { continue }
            guard let chrConfig = characterConfigs[name] else { continue }

            let node = CharacterNode(characterName: name, loader: loader)
            node.fonScripts = chrConfig.fonScripts
            node.scenePalette = currentPalette
            node.sceneName = currentSceneName
            if let rest = charState.restScript, !rest.isEmpty, node.fonScripts.count > 2 {
                node.fonScripts[2] = rest
            }
            node.walkingMap = walkingMaps[name]
            node.direction = charState.direction
            node.delegate = self
            node.updatePosition(config: config, gridX: charState.gridX, gridY: charState.gridY, zPerGrid: config.zPerGrid, z: charState.z)
            bgNode.addChild(node)
            characterNodes[name] = node

            // restScript уже заменил слот 2 списка — реплика-напоминалка играет
            // в свой черёд цикла после паузы, а не немедленно при входе
            node.startIdle()

            fputs("[Char] \(name) placed at grid(\(charState.gridX),\(charState.gridY))\n", stderr)
        }
    }

    func refreshCharacter(_ name: String) {
        guard let config = sceneConfig, let bgNode = backgroundNode else { return }
        guard let charState = gameState.characters[name] else { return }

        if let existing = characterNodes[name] {
            existing.stopAll()
            existing.removeFromParent()
            characterNodes.removeValue(forKey: name)
        }

        guard charState.isVisible else { return }
        guard let chrConfig = characterConfigs[name] else { return }

        let node = CharacterNode(characterName: name, loader: loader)
        node.fonScripts = chrConfig.fonScripts
        node.scenePalette = currentPalette
        node.sceneName = currentSceneName
        if let rest = charState.restScript, !rest.isEmpty, node.fonScripts.count > 2 {
            node.fonScripts[2] = rest
        }
        node.walkingMap = walkingMaps[name]
        node.direction = charState.direction
        node.delegate = self
        node.updatePosition(config: config, gridX: charState.gridX, gridY: charState.gridY, zPerGrid: config.zPerGrid, z: charState.z)
        bgNode.addChild(node)
        characterNodes[name] = node

        if cutscenePlayer != nil {
            node.isHidden = true
            node.isPaused = true
        } else {
            // напоминалка (restScript, слот 2) — только по циклу, после паузы
            node.startIdle()
        }
    }

    // MARK: - Cutscenes

    private func playCutscene(mvName: String, fsName: String, forScene sceneName: String,
                              objectGridX: Int = 0, objectGridY: Int = 0, anchorCharacter: String? = nil) {
        guard cutscenePlayer == nil, let bgNode = backgroundNode, let config = sceneConfig else { return }

        do {
            guard let fs = try loader.loadFrameSequence(named: fsName, forScene: sceneName) else {
                fputs("[Cutscene] FS \(fsName) not found in \(sceneName)\n", stderr)
                return
            }
            let movie = try loader.loadCompositeMovie(named: fs.movieName)
            if let pal = currentPalette { movie.setPalette(pal) }

            // Якорь: клетка персонажа-владельца (entry/action FS), иначе клетка объекта.
            // Set/Shift внутри FS переякоривают канву через cutsceneDidChangeCharacter.
            let gridX: Int, gridY: Int
            if let anchor = anchorCharacter, let ch = gameState.characters[anchor] {
                gridX = ch.gridX
                gridY = ch.gridY
                cutsceneAnchor = (anchor, fs)
            } else {
                gridX = objectGridX
                gridY = objectGridY
                cutsceneAnchor = nil
            }
            let gridPixelX = config.leftTopGrid.0 + gridX * config.gridSize.0 + config.gridShift.0
            let gridPixelY = config.leftTopGrid.1 + gridY * config.gridSize.1 + config.gridShift.1
            let renderOriginX = gridPixelX - fs.shiftX
            let renderOriginY = gridPixelY - fs.shiftY

            let player = CutscenePlayer(movie: movie, fs: fs, gameState: gameState)
            player.delegate = self
            player.position = CGPoint(x: CGFloat(renderOriginX), y: CGFloat(-renderOriginY))
            // Фильм рисуется на глубине персонажа-якоря: фасад дома (z=19)
            // перекрывает входящего Roby (Set Roby,Z,0 в ROHANHOM); без якоря — поверх
            if let anchor = anchorCharacter, let ch = gameState.characters[anchor] {
                player.zPosition = CGFloat(ch.gridY * config.zPerGrid + ch.z) + 0.5
            } else {
                player.zPosition = 200
            }
            bgNode.addChild(player)
            cutscenePlayer = player

            scrollOffset = CGFloat(max(0, min(Int(maxScroll), renderOriginX)))
            updateScroll()

            for (_, ch) in characterNodes {
                ch.isHidden = true
                ch.isPaused = true // idle-цикл (реплики!) на паузу
            }
            player.play()
            fputs("[Cutscene] Playing \(fsName) → \(fs.movieName) at bgOrigin=(\(renderOriginX),\(renderOriginY)) anchor=\(anchorCharacter ?? "obj") scroll=\(scrollOffset)\n", stderr)
        } catch {
            fputs("[Cutscene] Error: \(error)\n", stderr)
        }
    }

    private func reanchorCutscene() {
        guard let player = cutscenePlayer, let (anchorChar, fs) = cutsceneAnchor,
              let config = sceneConfig, let ch = gameState.characters[anchorChar] else { return }
        let gridPixelX = config.leftTopGrid.0 + ch.gridX * config.gridSize.0 + config.gridShift.0
        let gridPixelY = config.leftTopGrid.1 + ch.gridY * config.gridSize.1 + config.gridShift.1
        player.position = CGPoint(x: CGFloat(gridPixelX - fs.shiftX), y: CGFloat(-(gridPixelY - fs.shiftY)))
        player.zPosition = CGFloat(ch.gridY * config.zPerGrid + ch.z) + 0.5 // Set Z меняет глубину
    }

    func cutsceneDidFinish(_ player: CutscenePlayer) {
        player.stop()
        player.removeFromParent()
        cutscenePlayer = nil
        cutsceneAnchor = nil
        updateBarState() // FridIs/MapOK/инвентарь могли измениться скриптом
        removeAnimations()
        loadSceneAnimations()
        let names = Array(characterNodes.keys)
        for name in names { refreshCharacter(name) }
        gameState.dumpState()
        fputs("[Cutscene] Finished\n", stderr)
    }

    func cutsceneDidShowText(_ player: CutscenePlayer, text: String) {
        barPanel?.setText(text)
    }

    func cutsceneDidRequestSceneChange(_ player: CutscenePlayer, params: [String]) {
        // GoScene scene, {char, fs}×N, gridX, gridY — пар может быть 1 или 2:
        // обычный переход: SCENA7,Roby,Roin6,Frid,Frin6,6,0
        // триггер осознания: SCENA7,Roby,Disc6,5,0 (5 аргументов, без Frid)
        guard let sceneName = params.first else { return }

        player.stop()
        player.removeFromParent()
        cutscenePlayer = nil

        if params.count >= 3 {
            // Координаты в хвосте опциональны: GoScene SCENA8,Roby,Roin4,Frid,Frin4
            var tail = params.count
            var gridX: Int? = nil, gridY: Int? = nil
            if params.count >= 5, let x = Int(params[params.count - 2]),
               let y = Int(params[params.count - 1]) {
                gridX = x; gridY = y
                tail = params.count - 2
            }
            var pairs: [(char: String, fs: String)] = []
            var i = 1
            while i + 1 <= tail - 1 {
                pairs.append((params[i], params[i + 1]))
                i += 2
            }

            if let gx = gridX, let gy = gridY {
                for pair in pairs {
                    gameState.setCharacterPosition(pair.char, x: gx, y: gy)
                }
            }
            if let first = pairs.first {
                gameState.setCharacterVisible(first.char, visible: true)
                let resolved = gameState.getChar(first.fs.lowercased())
                let fsName = resolved.isEmpty ? first.fs : resolved
                pendingEntryFS = fsName
                pendingEntryChar = first.char
                let ch = gameState.character(first.char)
                pendingEntryGridX = gridX ?? ch?.gridX ?? 0
                pendingEntryGridY = gridY ?? ch?.gridY ?? 0
                fputs("[GoScene] → \(sceneName), chars \(pairs.map(\.char)) at (\(pendingEntryGridX),\(pendingEntryGridY)), entry: \(fsName)\n", stderr)
            }
        }

        switchScene(to: sceneName)
    }

    func cutsceneDidChangeObjectState(_ player: CutscenePlayer, scene: String, object: String, active: Bool) {
        // DelObject/CreateObject внутри катсцены меняют сцену сразу:
        // фильм с крабом удаляет фонового краба (кадр 1) и возвращает в конце
        guard scene.uppercased() == currentSceneName else { return }
        removeAnimations()
        loadSceneAnimations()
    }

    func cutsceneDidChangeCharacter(_ player: CutscenePlayer, name: String) {
        refreshCharacter(name)
        if let anchor = cutsceneAnchor, anchor.character.lowercased() == name.lowercased() {
            reanchorCutscene()
        }
    }

    func cutsceneDidChangeInventory(_ player: CutscenePlayer) {
        refreshInventoryBar()
    }

    func cutsceneDidChangeBar(_ player: CutscenePlayer, visible: Bool) {
        barNode?.isHidden = !visible
        barPanel?.isHidden = !visible
        barPanel?.setMapAvailable(gameState.mapEnabled)
    }

    func cutsceneDidShiftScreen(_ player: CutscenePlayer, dx: Int, dy: Int) {
        guard let config = sceneConfig else { return }
        scrollOffset += CGFloat(dx * config.gridSize.0)
        scrollOffset = max(0, min(scrollOffset, maxScroll))
        updateScroll()
        fputs("[Script] ShiftScreen (\(dx),\(dy)) → scroll=\(scrollOffset)\n", stderr)
    }

    func cutsceneDidSetVert(_ player: CutscenePlayer, x: Int, y: Int, open: Bool) {
        gameState.setVert(scene: currentSceneName, x: x, y: y, open: open)
    }

    // Sound name,params: имя в кавычках — файл из WAVE.DAN; без — переменная
    // из SoundVariables текущей сцены (step → step.wav и т.п.)
    private func playSound(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if name.lowercased().hasSuffix(".wav") {
            soundManager.playEffect(file: name)
        } else if let snd = sceneConfig?.sounds.first(where: { $0.name.lowercased() == name.lowercased() }) {
            soundManager.playEffect(file: snd.file)
        } else {
            soundManager.playEffect(file: name)
        }
    }

    func cutsceneDidPlaySound(_ player: CutscenePlayer, name: String) {
        playSound(named: name)
    }

    // MARK: - Мини-игры (StartGame номер, varРезультат, varСостояние)

    func cutsceneDidRequestMiniGame(_ player: CutscenePlayer, number: Int, resultVar: String, stateVar: String) {
        startMiniGame(number: number, resultVar: resultVar, stateVar: stateVar) {
            player.resume()
        }
    }

    func startMiniGame(number: Int, resultVar: String, stateVar: String,
                       onDone: @escaping () -> Void) {
        func install(_ game: MiniGameNodeProtocol,
                     sound: @escaping (String) -> Void,
                     finish: @escaping (Bool) -> Void) {
            game.zPosition = 900
            addChild(game)
            miniGameNode = game
        }

        let finishHandler: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.gameState.setInt(resultVar, value: success ? 1 : 0)
            self.miniGameNode?.removeFromParent()
            self.miniGameNode = nil
            fputs("[MiniGame] игра \(number): \(success ? "успех" : "выход") → \(resultVar)=\(success ? 1 : 0)\n", stderr)
            onDone()
        }
        let soundHandler: (String) -> Void = { [weak self] name in
            self?.soundManager.playEffect(file: name)
        }

        switch number {
        case 0:
            let game = MapGameNode(gameDataPath: loader.gameDataPath,
                                   availableParts: gameState.getInt(stateVar))
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        case 1:
            let game = HouseGameNode(gameDataPath: loader.gameDataPath)
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        case 2:
            let game = ChessGameNode(gameDataPath: loader.gameDataPath)
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        case 3:
            let game = BalloonGameNode(gameDataPath: loader.gameDataPath)
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        case 4:
            let game = OrganGameNode(gameDataPath: loader.gameDataPath,
                                     tubs: gameState.getInt(stateVar))
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        case 5:
            let game = CryptGameNode(gameDataPath: loader.gameDataPath)
            game.soundPlayer = soundHandler
            game.onFinish = finishHandler
            install(game, sound: soundHandler, finish: finishHandler)
        default:
            // Остальные игры пока заглушены: мгновенный успех, чтобы не блокировать сюжет
            fputs("[MiniGame] игра \(number) не реализована — заглушка успеха (\(resultVar)=1)\n", stderr)
            gameState.setInt(resultVar, value: 1)
            onDone()
        }
    }

    // DeleteItem забирает предмет и «из руки»: доигранный до конца фильм
    // ROROPBAN (кадр 42) опустошает руку — верёвку надо брать заново
    func cutsceneDidDeleteItem(_ player: CutscenePlayer, item: String) {
        if selectedItemName == item.lowercased() {
            selectedItemName = nil
            barPanel?.selectItem(nil)
            fputs("[Script] предмет выпал из руки: \(item)\n", stderr)
        }
    }

    func cutsceneDidSetMusic(_ player: CutscenePlayer, name: String) {
        soundManager.playMusic(name: name)
    }

    // SetActive: предмет «в руке» — выбран, даже если его нет в ленте инвентаря
    // (паттерн AddItem → SetActive → DeleteItem в ROHANRP1.FS)
    func cutsceneDidSetActiveItem(_ player: CutscenePlayer, item: String) {
        selectedItemName = item.lowercased()
        if let idx = itemNameToIndex[selectedItemName!] {
            barPanel?.selectItem(idx)
        }
        fputs("[Script] активный предмет → \(item)\n", stderr)
    }

    private func makePathfinder(config: SceneConfig, for character: String) -> GridPathfinder {
        let overrides = gameState.closedVertsOverrides(forScene: currentSceneName)
        let opened = Set(overrides.opened.map { GridPathfinder.GridCell(x: $0.x, y: $0.y) })
        let closed = Set(overrides.closed.map { GridPathfinder.GridCell(x: $0.x, y: $0.y) })
        // ArrowGoing (Frid) ходит только по 4 направлениям — диагональных fg_* анимаций нет
        let dirs: [Int]
        if characterConfigs[character]?.moveType.lowercased() == "arrowgoing" {
            dirs = [2, 4, 6, 8]
        } else {
            dirs = GridPathfinder.moveDirs
        }
        // ClosedVert/ClosedDir активных объектов — относительно их клетки
        var objVerts: [(Int, Int)] = []
        var objDirs: [GridDirection] = []
        if let cfg = sceneConfig {
            for obj in cfg.objects where gameState.isObjectActive(scene: currentSceneName, object: obj.name) {
                guard let ob = objectDefs[obj.name.lowercased()] else { continue }
                let grid = objectGrid(name: obj.name, defaultX: obj.gridX, defaultY: obj.gridY)
                for v in ob.closedVerts {
                    objVerts.append((grid.x + v.0, grid.y + v.1))
                }
                for d in ob.closedDirs {
                    objDirs.append(GridDirection(x: grid.x + d.x, y: grid.y + d.y, dir: d.dir))
                }
            }
        }
        return GridPathfinder(config: config, dynamicOpened: opened, dynamicClosed: closed,
                              objectClosedVerts: objVerts, objectClosedDirs: objDirs, allowedDirs: dirs)
    }

    private func refreshInventoryBar() {
        let indices = gameState.inventory.compactMap { itemNameToIndex[$0] }
        barPanel?.setInventory(indices)
    }

    // Портреты (Пятница появляется при FridIs=1), карта (MapOK), инвентарь активного
    private func updateBarState() {
        let bothAvailable = gameState.getInt("FridIs") != 0
        let active = gameState.activeCharacter == "Frid" ? 1 : 0
        barPanel?.setCharacters(bothAvailable: bothAvailable, active: active)
        barPanel?.setMapAvailable(gameState.mapEnabled)
        refreshInventoryBar()
    }

    func cutsceneDidRequestAproach(_ player: CutscenePlayer, character: String, object: String, offsetX: Int, offsetY: Int) {
        guard let config = sceneConfig,
              let charState = gameState.characters[character],
              let node = characterNodes[character] else {
            player.resume()
            return
        }

        // Aproach char,x,y (object пуст) — абсолютная клетка; иначе клетка объекта + смещение
        let targetX: Int, targetY: Int
        if object.isEmpty {
            targetX = offsetX
            targetY = offsetY
        } else {
            let targetObj = config.objects.first { $0.name.lowercased() == object.lowercased() }
            let grid = objectGrid(name: object,
                                  defaultX: targetObj?.gridX ?? charState.gridX,
                                  defaultY: targetObj?.gridY ?? charState.gridY)
            targetX = grid.x + offsetX
            targetY = grid.y + offsetY
        }

        let start = GridPathfinder.GridCell(x: charState.gridX, y: charState.gridY)
        let target = GridPathfinder.GridCell(x: targetX, y: targetY)
        let pathfinder = makePathfinder(config: config, for: character)

        if player.skipping {
            // пропуск фильма: телепорт вместо ходьбы
            let cell = pathfinder.findNearestReachable(from: start, to: target)?.cell ?? target
            gameState.setCharacterPosition(character, x: cell.x, y: cell.y)
            refreshCharacter(character)
            fputs("[Aproach] пропуск: \(character) телепорт в (\(cell.x),\(cell.y))\n", stderr)
            player.resume()
            return
        }

        if let result = pathfinder.findNearestReachable(from: start, to: target), !result.path.isEmpty {
            pendingAproachResume = player
            // Подход виден: персонаж идёт, фильм скрыт до конца ходьбы
            player.isHidden = true
            node.isHidden = false
            node.isPaused = false
            node.walk(path: result.path)
            fputs("[Aproach] \(character) walking \(result.path.count) steps to (\(result.cell.x),\(result.cell.y))\n", stderr)
        } else {
            fputs("[Aproach] \(character) already at target or no path\n", stderr)
            player.resume()
        }
    }

    // MARK: - CharacterNodeDelegate

    func characterDidFinishWalking(_ node: CharacterNode) {
        // Позиция ноды уже актуальна: Shift-команды walk FS применялись сразу.
        gameState.setCharacterDirection(node.characterName, direction: node.direction)

        if let player = pendingAproachResume {
            pendingAproachResume = nil
            node.isHidden = true
            node.isPaused = true
            reanchorCutscene() // Aproach сдвинул персонажа — канва следует за ним
            player.isHidden = false
            player.resume()
        }
    }

    func characterDidExecuteCommand(_ node: CharacterNode, command: FSCommand) {
        switch command {
        case .sound(let name, _):
            playSound(named: name)
            return
        case .text(let index, _):
            if let t = gameState.text(at: index) { barPanel?.setText(t) }
            return
        case .setRest(let character, let slotStr, let script):
            // SetRest char,slot,script — заменяет fon-скрипт слота (эскалация
            // жажды: roby1 → roby1a → roby1b в SCENA0)
            gameState.setCharacterRest(character, script: script)
            if let target = characterNodes[character], let slot = Int(slotStr),
               slot >= 0, slot < target.fonScripts.count {
                target.fonScripts[slot] = script
            }
            fputs("[Idle] SetRest \(character)[\(slotStr)] → \(script)\n", stderr)
            return
        case .setVar(let name, let value):
            gameState.setInt(name, value: Int(value) ?? 0)
            return
        case .shift(let target, let axis, let value):
            if let delta = Int(value), let ch = gameState.character(target) {
                switch axis.uppercased() {
                case "X": gameState.setCharacterPosition(target, x: ch.gridX + delta)
                case "Y": gameState.setCharacterPosition(target, y: ch.gridY + delta)
                case "Z": gameState.setCharacterPosition(target, z: ch.z + delta)
                default: break
                }
            }
        case .set(let target, let axis, let value):
            if let v = Int(value) {
                switch axis.uppercased() {
                case "X": gameState.setCharacterPosition(target, x: v)
                case "Y": gameState.setCharacterPosition(target, y: v)
                case "Z": gameState.setCharacterPosition(target, z: v)
                default: break
                }
            }
        default:
            break
        }

        if let config = sceneConfig, let ch = gameState.character(node.characterName) {
            node.updatePosition(config: config, gridX: ch.gridX, gridY: ch.gridY, zPerGrid: config.zPerGrid, z: ch.z)
        }
    }

    // MARK: - Save / Load

    private var saveDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NovyRobinzon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func slotURL(_ i: Int) -> URL { saveDir.appendingPathComponent("save\(i + 1).json") }
    private func thumbURL(_ i: Int) -> URL { saveDir.appendingPathComponent("save\(i + 1).png") }

    private func slotInfos() -> [SaveLoadOverlay.SlotInfo] {
        // миграция старого одиночного сейва в слот 1
        let old = saveDir.appendingPathComponent("save.json")
        if FileManager.default.fileExists(atPath: old.path),
           !FileManager.default.fileExists(atPath: slotURL(0).path) {
            try? FileManager.default.moveItem(at: old, to: slotURL(0))
        }
        return (0..<12).map { i in
            guard let data = try? Data(contentsOf: slotURL(i)),
                  let save = try? JSONDecoder().decode(SaveData.self, from: data) else {
                return SaveLoadOverlay.SlotInfo(exists: false, label: "— пусто —", thumbnail: nil)
            }
            var thumb: CGImage? = nil
            if let src = CGImageSourceCreateWithURL(thumbURL(i) as CFURL, nil) {
                thumb = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            let date = (try? FileManager.default.attributesOfItem(atPath: slotURL(i).path)[.modificationDate] as? Date) ?? nil
            let df = DateFormatter()
            df.dateFormat = "dd.MM HH:mm"
            let when = date.map { df.string(from: $0) } ?? ""
            return SaveLoadOverlay.SlotInfo(exists: true,
                                            label: "\(save.currentScene) \(when)",
                                            thumbnail: thumb)
        }
    }

    private func showSaveLoad(mode: SaveLoadOverlay.Mode) {
        guard saveLoadOverlay == nil else { return }
        // превью текущего экрана для записываемого слота
        let overlay = SaveLoadOverlay(loader: loader, mode: mode, slots: slotInfos())
        overlay.zPosition = 1100
        overlay.onCancel = { [weak self] in
            self?.saveLoadOverlay?.removeFromParent()
            self?.saveLoadOverlay = nil
        }
        overlay.onSlot = { [weak self] i in
            guard let self else { return }
            self.saveLoadOverlay?.removeFromParent()
            self.saveLoadOverlay = nil
            switch mode {
            case .save: self.saveGame(slot: i)
            case .load: self.loadGame(slot: i)
            }
        }
        addChild(overlay)
        saveLoadOverlay = overlay
    }

    private func captureThumbnail(to url: URL) {
        guard let view = self.view,
              let tex = view.texture(from: self) else { return }
        let cg = tex.cgImage()
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private func saveGame(slot: Int) {
        let save = gameState.makeSave(selectedItem: selectedItemName)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(save).write(to: slotURL(slot))
            captureThumbnail(to: thumbURL(slot))
            barPanel?.setText("Игра сохранена (слот \(slot + 1))")
            fputs("[Save] слот \(slot + 1)\n", stderr)
        } catch {
            barPanel?.setText("Ошибка сохранения")
            fputs("[Save] ошибка: \(error)\n", stderr)
        }
    }

    private func loadGame(slot: Int) {
        guard let data = try? Data(contentsOf: slotURL(slot)),
              let save = try? JSONDecoder().decode(SaveData.self, from: data) else {
            barPanel?.setText("Слот пуст")
            return
        }
        gameStarted = true
        cutscenePlayer?.stop()
        cutscenePlayer?.removeFromParent()
        cutscenePlayer = nil
        cutsceneAnchor = nil
        pendingAproachResume = nil
        pendingEntryFS = nil
        pendingEntryChar = nil

        gameState.restore(from: save)
        selectedItemName = save.selectedItem
        currentSceneName = gameState.currentScene
        soundManager.playMusic(name: save.currentMusic)
        skipAutoEntry = true
        loadCurrentScene()
        updateBarState()
        barPanel?.setText("Игра загружена")
        fputs("[Save] загружен слот \(slot + 1): \(currentSceneName)\n", stderr)
    }

    func barPanelDidClickSave(_ bar: BarPanel) {
        showSaveLoad(mode: .save)
    }

    // MARK: - Scene switching

    // GoScene в ту же сцену легален (SCENA5→SCENA5 в ветках стройки) —
    // перезагружаем всегда, чтобы сыграл входной FS (nohome/home_ok)
    private func switchScene(to name: String) {
        currentSceneName = name.uppercased()
        gameState.currentScene = currentSceneName
        loadCurrentScene()
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        let loc = event.location(in: self)
        if let overlay = saveLoadOverlay {
            overlay.handleClick(at: loc)
            return
        }
        if let menu = menuOverlay {
            menu.handleClick(at: loc)
            return
        }
        if let game = miniGameNode {
            game.handleMouseDown(at: loc)
            return
        }
        if loc.y > barHeight {
            handleSceneClick(at: loc)
        } else {
            handleBarClick(at: loc)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let menu = menuOverlay {
            menu.handleDrag(at: event.location(in: self))
            return
        }
        miniGameNode?.handleMouseDragged(to: event.location(in: self))
    }

    override func mouseUp(with event: NSEvent) {
        if let menu = menuOverlay {
            menu.handleMouseUp()
            return
        }
        miniGameNode?.handleMouseUp(at: event.location(in: self))
    }

    override func rightMouseDown(with event: NSEvent) {
        miniGameNode?.handleRightMouseDown(at: event.location(in: self))
    }

    override func keyDown(with event: NSEvent) {
        if saveLoadOverlay != nil {
            if event.keyCode == 53 {
                saveLoadOverlay?.removeFromParent()
                saveLoadOverlay = nil
            }
            return
        }
        if menuOverlay != nil {
            if event.keyCode == 53, gameStarted { hideMenu() } // Escape — вернуться
            return
        }
        if let game = miniGameNode {
            game.handleKeyDown(keyCode: event.keyCode)
            return
        }
        if cutscenePlayer != nil {
            if event.keyCode == 53 { // Escape: доиграть команды мгновенно
                cutscenePlayer?.skipToEnd()
            }
            return
        }

        switch event.keyCode {
        case 53: showMenu()     // Escape — меню
        case 123: scrollBy(-40) // left arrow
        case 124: scrollBy(40)  // right arrow
        case 37: showSaveLoad(mode: .load) // L
        case 1: showSaveLoad(mode: .save)  // S
        default: break
        }
    }

    private func scrollBy(_ delta: CGFloat) {
        scrollOffset += delta
        updateScroll()
    }

    // Объект под точкой сцены. ActiveZone считается БЕЗ gridShift, в отличие
    // от рендера анимаций: зона краба (60,-30) и огня (55,10) в SCENA0
    // попадают на видимые спрайты только от базы leftTopGrid + grid*cellSize.
    // При перекрытии зон побеждает объект с наибольшей глубиной — кликается
    // то, что нарисовано сверху (кокос z=13 поверх скалы z=9 в SCENA2)
    private func objectAt(sceneX: CGFloat, sceneY: CGFloat) -> (name: String, def: ObjectDef)? {
        guard let config = sceneConfig else { return nil }
        var best: (name: String, def: ObjectDef, depth: Int)? = nil
        for obj in config.objects {
            guard gameState.isObjectActive(scene: currentSceneName, object: obj.name),
                  let ob = objectDefs[obj.name.lowercased()] else { continue }

            let grid = objectGrid(name: obj.name, defaultX: obj.gridX, defaultY: obj.gridY)
            let baseX = config.leftTopGrid.0 + grid.x * config.gridSize.0
            let baseY = config.leftTopGrid.1 + grid.y * config.gridSize.1
            for zone in ob.activeZones where zone.width > 0 && zone.height > 0 {
                let rect = CGRect(x: CGFloat(baseX + zone.x), y: CGFloat(baseY + zone.y),
                                  width: CGFloat(zone.width), height: CGFloat(zone.height))
                if rect.contains(CGPoint(x: sceneX, y: sceneY)) {
                    let depth = grid.y * config.zPerGrid + ob.zCoord
                    if best == nil || depth >= best!.depth {
                        best = (obj.name, ob, depth)
                    }
                }
            }
        }
        if let best { return (best.name, best.def) }
        return nil
    }

    private func handleSceneClick(at point: CGPoint) {
        guard pendingAproachResume == nil else { return }
        let sceneX = point.x + scrollOffset
        let sceneY = sceneAreaHeight - (point.y - barHeight)

        // Интерактивная пауза фильма (SetMouse ON, Delay -5000): клик по
        // объекту ПРЕРЫВАЕТ фильм и диспатчит новый FS — хвост команд
        // старого не исполняется (иначе ROROPBAN кадр 44 воссоздаёт
        // верёвку и пальму → дубли на сцене)
        if let player = cutscenePlayer {
            guard player.mouseWindowOpen else { return }
            if let hit = objectAt(sceneX: sceneX, sceneY: sceneY) {
                fputs("[Click] прерывание паузы → \(hit.name)\n", stderr)
                player.stop()
                player.removeFromParent()
                cutscenePlayer = nil
                cutsceneAnchor = nil
                dispatchObjectInteraction(objectName: hit.name)
            }
            return
        }

        let active = gameState.activeCharacter
        if let node = characterNodes[active], node.state == .walking {
            node.stopAll()
            node.startIdle()
        }

        if let hit = objectAt(sceneX: sceneX, sceneY: sceneY) {
            fputs("[Click] Object: \(hit.name)\n", stderr)
            // Подход к объекту делает сам FS через Aproach — как в оригинале
            dispatchObjectInteraction(objectName: hit.name)
            return
        }

        // Клик предметом мимо объектов: RO{item}.FS без суффикса объекта —
        // «применить предмет здесь». Для большинства предметов это Cannotdo
        // («не могу»), а ROSTO в SCENA8 — постройка очага: Aproach сам ведёт
        // Роби к месту (1,2). Если такого FS в сцене нет — обычная ходьба.
        if let item = selectedItemName {
            let key = "\(active.lowercased().prefix(2))\(item.lowercased().prefix(3))"
            let fsName = gameState.getChar(key).isEmpty ? key : gameState.getChar(key)
            if let charState = gameState.characters[active],
               (try? loader.loadFrameSequence(named: fsName, forScene: currentSceneName)) != nil {
                selectedItemName = nil
                barPanel?.selectItem(nil)
                fputs("[Dispatch] предмет в пустоту → \(fsName).FS\n", stderr)
                playCutscene(mvName: "", fsName: fsName, forScene: currentSceneName,
                             objectGridX: charState.gridX, objectGridY: charState.gridY,
                             anchorCharacter: active)
                return
            }
        }

        // Клик по земле НЕ сбрасывает предмет в руке — иначе SetActive-предметы
        // (верёвка rp1) терялись бы при любом шаге
        walkActiveCharacter(toPixelX: Int(sceneX), pixelY: Int(sceneY))
    }

    private func walkActiveCharacter(toPixelX px: Int, pixelY py: Int) {
        guard let config = sceneConfig else { return }
        let active = gameState.activeCharacter
        guard let charState = gameState.characters[active],
              let node = characterNodes[active] else { return }

        let gridX = (px - config.leftTopGrid.0) / max(config.gridSize.0, 1)
        let gridY = (py - config.leftTopGrid.1) / max(config.gridSize.1, 1)
        let clampedX = max(0, min(gridX, config.gridLength.0 - 1))
        let clampedY = max(0, min(gridY, config.gridLength.1 - 1))

        let start = GridPathfinder.GridCell(x: charState.gridX, y: charState.gridY)
        let target = GridPathfinder.GridCell(x: clampedX, y: clampedY)
        let pathfinder = makePathfinder(config: config, for: active)

        if let result = pathfinder.findNearestReachable(from: start, to: target), !result.path.isEmpty {
            node.walk(path: result.path)
            fputs("[Walk] \(active) → (\(result.cell.x),\(result.cell.y)) \(result.path.count) steps\n", stderr)
        }
    }

    private func dispatchObjectInteraction(objectName: String) {
        let active = gameState.activeCharacter
        let charPrefix = active.lowercased().prefix(2)
        let itemCode: String
        if let item = selectedItemName {
            itemCode = String(item.lowercased().prefix(3))
        } else {
            itemCode = "han"
        }
        let objAbbrev = String(objectName.lowercased().prefix(3))
        let key = "\(charPrefix)\(itemCode)\(objAbbrev)"

        let fsName = gameState.getChar(key).isEmpty ? key : gameState.getChar(key)

        selectedItemName = nil
        barPanel?.selectItem(nil)

        let sceneObj = sceneConfig?.objects.first { $0.name.lowercased() == objectName.lowercased() }
        let grid = objectGrid(name: objectName, defaultX: sceneObj?.gridX ?? 0, defaultY: sceneObj?.gridY ?? 0)
        fputs("[Dispatch] \(objectName) grid(\(grid.x),\(grid.y)) → \(fsName).FS\n", stderr)

        playCutscene(mvName: "", fsName: fsName, forScene: currentSceneName,
                     objectGridX: grid.x, objectGridY: grid.y, anchorCharacter: active)
    }

    private func handleBarClick(at point: CGPoint) {
        if cutscenePlayer?.barLocked == true { return } // LockBar ON в паузе
        let barLocal = CGPoint(x: point.x, y: point.y)
        barPanel?.handleClick(at: barLocal)
        fputs("click: bar(\(Int(point.x)),\(Int(point.y)))\n", stderr)
    }

    // MARK: - BarPanelDelegate

    func barPanel(_ bar: BarPanel, didClickInventoryItem index: Int) {
        if let name = indexToItemName[index], selectedItemName != name {
            selectedItemName = name
            fputs("[BAR] selected item: \(name)\n", stderr)
        } else {
            selectedItemName = nil
            fputs("[BAR] deselected item\n", stderr)
        }
    }

    func barPanel(_ bar: BarPanel, didClickPortrait character: Int) {
        let names = ["Roby", "Frid"]
        guard character < names.count else { return }
        let name = names[character]
        gameState.activeCharacter = name
        selectedItemName = nil
        barPanel?.selectItem(nil)
        updateBarState() // портрет + инвентарь нового активного персонажа
        fputs("[BAR] active character → \(name)\n", stderr)
    }

    func barPanelDidClickMap(_ bar: BarPanel) {
        // Как GoScene MAPSCR, Roby, roin00, 0,0 в DISC6
        guard cutscenePlayer == nil else { return }
        pendingEntryFS = "roin00"
        pendingEntryChar = "Roby"
        pendingEntryGridX = 0
        pendingEntryGridY = 0
        fputs("[BAR] map → MAPSCR\n", stderr)
        switchScene(to: "MAPSCR")
    }

    func barPanelDidScrollInventory(_ bar: BarPanel, direction: Int) {
        fputs("[BAR] scroll \(direction > 0 ? "right" : "left")\n", stderr)
    }

    override func update(_ currentTime: TimeInterval) {
        if let game = miniGameNode {
            game.tick(currentTime)
            return
        }
        if let menu = menuOverlay {
            // игра на паузе; ховер по кнопкам меню
            if let view = self.view, let window = view.window {
                let mouseInWindow = window.mouseLocationOutsideOfEventStream
                let mouseInView = view.convert(mouseInWindow, from: nil)
                menu.handleHover(at: convertPoint(fromView: mouseInView))
            }
            return
        }

        cutscenePlayer?.tick(currentTime)
        for (_, node) in characterNodes {
            node.tick(currentTime)
        }

        guard cutscenePlayer == nil,
              let view = self.view,
              let window = view.window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = view.convert(mouseInWindow, from: nil)
        let mouseInScene = convertPoint(fromView: mouseInView)

        if mouseInScene.y > barHeight {
            let edgeZone: CGFloat = 60
            let scrollSpeed: CGFloat = 4
            if mouseInScene.x < edgeZone {
                let factor = 1.0 - mouseInScene.x / edgeZone
                scrollBy(-scrollSpeed * factor)
            } else if mouseInScene.x > viewportWidth - edgeZone {
                let factor = (mouseInScene.x - (viewportWidth - edgeZone)) / edgeZone
                scrollBy(scrollSpeed * factor)
            }
        }

        updateHoverText(mouseInScene: mouseInScene)
    }

    // Наведение на интерактивный объект показывает его название в текстовом блоке
    private func updateHoverText(mouseInScene: CGPoint) {
        var newHover: String? = nil
        var textIndex = 0
        if mouseInScene.y > barHeight {
            let sceneX = mouseInScene.x + scrollOffset
            let sceneY = sceneAreaHeight - (mouseInScene.y - barHeight)
            if let hit = objectAt(sceneX: sceneX, sceneY: sceneY) {
                newHover = hit.name
                textIndex = hit.def.textIndex
            }
        }
        guard newHover != hoveredObjectName else { return }
        hoveredObjectName = newHover
        if newHover != nil, let text = gameState.text(at: textIndex) {
            barPanel?.setText(text)
        } else {
            barPanel?.setText("")
        }
    }
}
