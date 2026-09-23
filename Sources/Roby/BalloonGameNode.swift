import SpriteKit
import ResourceKit

/// Мини-игра №3 «Воздушный шар» (SCENA1 ROHANMON, StartGame 3, LandOK).
/// ТОЧНАЯ физика из MiniGame.dll game #3 (0x100027f0 фазы, 0x10002dd0 физшаг):
///
/// - Мир 1000×1000 (границы 30..970), остров и площадка LAND в (200,200)
///   (ctor 0x10003190), шар стартует в (750,750) на высоте 0 (0x10001b7a).
/// - Направление ветра НЕПРЕРЫВНО крутится с высотой: θ = база + alt·3π/550
///   (0x10002df2, константы 3π и −1/550) — полтора оборота на весь диапазон.
///   Вектор скорости: (cosθ+sinθ, cosθ−sinθ), скорость 0.3·(1−rand20·0.01)
///   ед/тик (тик 100мс). У границ мира угол мгновенно отражается на
///   квантованные азимуты 120°/330°/150°/300°/30°/240°/60°/210° (0x10002e50).
/// - Высота: цель 50..550, накопитель команд ±2 (клавиши ↑↓ / кнопки Роби и
///   Пятница на панели), фактическая ползёт ±2/тик; фазы: взлёт (+15/тик до
///   412), ровный полёт FLY, подъём RAISE (цель +16 за цикл анимации,
///   stnbalon.wav), спуск FALL (−16, airbal.wav).
/// - Посадка (0x10002fd5): alt ≤ 175 и |Δ| < 50 по обеим осям от LAND →
///   фаза 5 (final3.wav): alt −2/тик, шар съезжает вниз экрана; alt ≤ −200 →
///   успех (0x10030174=4 → LandOK=1). ESC/дискета — выход-проигрыш.
/// - Экран: SKY 640×600 сдвигается на y=alt·120/550−130, море SEA на +200 от
///   него; остров/LAND — перспективная проекция (0x10003270): H=max(alt,50)−50,
///   Yb=500+0.6H, dist=√(dx²+dy²+H²), scale=1−min((dist−50)/657.1, 0.85),
///   мип-уровень из 8 по ближайшей ширине; ниже линии моря (0x10003451).
/// - Панель BAR (0,400): лента высоты ALT на x=358, y=(alt−550)·210/500+37;
///   лента курса COURSE на y=48, x=83−(atan2(−vy,vx)+π)·120/π, окно 140..270;
///   мини-карта: точка BALL на (3+0.127x, 6+0.065y) (мир 1000 → карта 127×65);
///   кнопки (415,408)/(490,408)=вверх/вниз, (565,408)=выход (0x100021b0).
final class BalloonGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480

    // Мир (float в DLL)
    private var pos = CGPoint(x: 750, y: 750)
    private let island = CGPoint(x: 200, y: 200)
    private var alt = 0
    private var targetAlt = 0     // [esi+0x10]
    private var baseAngle = 0.0   // [esi+0x98]
    private var dirA = 0.0        // [esi+8]  = cosθ+sinθ (x-компонента)
    private var dirB = 0.0        // [esi+0xc] = cosθ−sinθ (y-компонента)
    private var climbCmd = 0      // [0x1002eac4] ∈ −2..2
    private var phase = 1         // 1 взлёт, 2 ровно, 3 вверх, 4 вниз, 5 посадка
    private var landingStartOffset = 0.0 // [0x10029d68]: canvas-оффсет шара на старте посадки
    private var landingStartAlt = 0      // [0x10029d6c]
    private var finished = false
    private var landingTest = false

    // Покачивание шара (0x10003039): canvas-оффсет качается вокруг (0, −160)
    private var swayX = 0.0, swayY = -160.0
    private var swayDX = 1.0, swayDY = -1.0
    private var swayCounter = 3

    // Тик 100мс (0x10001e73: период 0x64)
    private var tickAccumulator: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    // Кнопки панели (0x1002ea60): вверх, вниз, выход
    private let buttonRects = [CGRect(x: 415, y: 408, width: 68, height: 57),
                               CGRect(x: 490, y: 408, width: 68, height: 57),
                               CGRect(x: 565, y: 408, width: 68, height: 57)]

    // Анимации (FS из MINIGAME.SDT + MV из корня): SEA, RAISE, FALL, FLY
    private struct AnimFrame {
        let texture: SKTexture?
        let origin: CGPoint
        let delayMs: Int
        let sounds: [String]
    }
    private struct Anim { var frames: [AnimFrame] = [] }
    private var anims: [String: Anim] = [:]

    private var skyNode = SKSpriteNode()
    private var seaNode = SKSpriteNode()
    private var ballNode = SKSpriteNode()
    private var seaAnim: Anim?
    private var seaFrame = 0
    private var seaDeadline: TimeInterval = 0
    private var ballAnimName = "RAISE"
    private var ballFrame = 0
    private var ballDeadline: TimeInterval = 0

    // Остров и площадка: 8 мип-уровней
    private var islandTextures: [SKTexture] = []
    private var landTextures: [SKTexture] = []
    private var islandBase = CGSize(width: 636, height: 379)
    private var landBase = CGSize(width: 613, height: 369)
    private let worldCrop = SKCropNode()
    private var islandNode = SKSpriteNode()
    private var landNode = SKSpriteNode()
    private var cropMask = SKSpriteNode(color: .white, size: CGSize(width: 640, height: 480))

    // Панель
    private var altTape = SKSpriteNode()
    private var courseTape = SKSpriteNode()
    private var ballDot = SKSpriteNode()

    init(gameDataPath: String) {
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../BALOON.DAT")
            let decompressor = NGIDecompressor()
            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name })
                else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }
            guard let colData = try resource("PALETTE.COL") else { return }
            let pal = try COLPalette(data: colData)
            let barPal = (try? resource("BAR.COL")).flatMap { $0 }
                .flatMap { try? COLPalette(data: $0) } ?? pal

            func texture(_ name: String, palette: COLPalette, transparent: Bool) throws -> SKTexture? {
                guard let d = try resource(name),
                      let img = MiniGameArt.decodeNGB(d, palette: palette, transparent: transparent)
                else { return nil }
                let t = SKTexture(cgImage: img.image)
                t.filteringMode = .nearest
                return t
            }

            // Небо 640×600 и море — сдвигаются по высоте
            if let sky = try texture("SKY.NGB", palette: pal, transparent: false) {
                skyNode = SKSpriteNode(texture: sky)
                skyNode.anchorPoint = CGPoint(x: 0, y: 1)
                skyNode.zPosition = 0
                addChild(skyNode)
            }
            seaNode.anchorPoint = CGPoint(x: 0, y: 1)
            seaNode.zPosition = 1
            addChild(seaNode)

            // Остров/LAND в crop-контейнере: не рисуются выше линии моря
            islandTextures = try (0...7).compactMap {
                try texture($0 == 0 ? "ISLAND.NGB" : "ISLAND\($0).NGB", palette: pal, transparent: true)
            }
            landTextures = try (0...7).compactMap {
                try texture($0 == 0 ? "LAND.NGB" : "LAND\($0).NGB", palette: pal, transparent: true)
            }
            if let t = islandTextures.first { islandBase = t.size() }
            if let t = landTextures.first { landBase = t.size() }
            islandNode.anchorPoint = CGPoint(x: 0, y: 1)
            landNode.anchorPoint = CGPoint(x: 0, y: 1)
            islandNode.zPosition = 0
            landNode.zPosition = 1
            cropMask.anchorPoint = CGPoint(x: 0, y: 1)
            worldCrop.maskNode = cropMask
            worldCrop.zPosition = 2
            worldCrop.addChild(islandNode)
            worldCrop.addChild(landNode)
            addChild(worldCrop)

            // Шар (полноэкранные канвы RAISE/FALL/FLY)
            ballNode.anchorPoint = CGPoint(x: 0, y: 1)
            ballNode.zPosition = 3
            addChild(ballNode)

            // Приборы — как в DLL: фоны и ленты рисуются ПОД панелью в её
            // surface 640×80 (клип 0x1000381b), панель BAR.NGB с прозрачными
            // окнами-прорезями (высотомер 355..390/16..64, курс 148..259/49..60 —
            // ровно DLL-клип 140..270) кадрирует их
            let panelClip = SKCropNode()
            let panelMask = SKSpriteNode(color: .white, size: CGSize(width: 640, height: 80))
            panelMask.anchorPoint = CGPoint(x: 0, y: 1)
            panelMask.position = CGPoint(x: 0, y: 80)
            panelClip.maskNode = panelMask
            panelClip.zPosition = 8
            addChild(panelClip)
            func panelSprite(_ name: String, x: CGFloat, y: CGFloat, z: CGFloat,
                             clipped: Bool = true) throws -> SKSpriteNode? {
                guard let t = try texture(name, palette: barPal, transparent: true) else { return nil }
                let n = SKSpriteNode(texture: t)
                n.anchorPoint = CGPoint(x: 0, y: 1)
                n.position = CGPoint(x: x, y: screenH - (y + 400))
                n.zPosition = z
                if clipped { panelClip.addChild(n) } else { addChild(n) }
                return n
            }
            _ = try panelSprite("ALTBGR.NGB", x: 342, y: 8, z: 0)    // фон окна высотомера
            _ = try panelSprite("COURSBGR.NGB", x: 140, y: 36, z: 0) // фон окна курса
            if let n = try panelSprite("ALT.NGB", x: 358, y: 0, z: 1) { altTape = n }
            if let n = try panelSprite("COURSE.NGB", x: 0, y: 48, z: 1) { courseTape = n }
            if let bar = try texture("BAR.NGB", palette: barPal, transparent: true) {
                let n = SKSpriteNode(texture: bar)
                n.anchorPoint = CGPoint(x: 0, y: 1)
                n.position = CGPoint(x: 0, y: 80)
                n.zPosition = 10
                addChild(n)
            }
            // Точка шара на мини-карте — поверх панели (0x1000389a)
            if let n = try panelSprite("BALL.NGB", x: 0, y: 0, z: 12, clipped: false) { ballDot = n }

            try loadAnims(gameDataPath: gameDataPath, palette: pal)
        } catch {
            fputs("[Balloon] ошибка загрузки: \(error)\n", stderr)
        }

        seaAnim = anims["SEA"]
        if ProcessInfo.processInfo.environment["ROBY_BAL_TEST"] != nil {
            // тест посадки: шар рядом с площадкой, постоянное снижение
            landingTest = true
            pos = CGPoint(x: 230, y: 230)
            alt = 412
            targetAlt = 412
            phase = 2
        }
        updateScreen()
        fputs("[Balloon] старт: (750,750), взлёт\n", stderr)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadAnims(gameDataPath: String, palette: COLPalette) throws {
        let root = gameDataPath + "/.."
        let sdt = try NLContainer(path: root + "/MINIGAME.SDT")
        let decompressor = NGIDecompressor()
        for name in ["SEA", "RAISE", "FALL", "FLY"] {
            guard let idx = sdt.entries.firstIndex(where: { $0.name.uppercased() == name + ".FS" }),
                  let fsData = try? sdt.extractResource(at: idx, decompressor: decompressor)
            else { continue }
            let fs = FrameSequence(data: fsData)
            let movie = try CompositeMovie(path: root + "/" + fs.movieName.uppercased(),
                                           decompressor: decompressor)
            movie.setPalette(palette)
            var anim = Anim()
            var current: AnimFrame?
            func flush() {
                if let f = current { anim.frames.append(f) }
                current = nil
            }
            for cmd in fs.commands {
                switch cmd {
                case .frame(let index, _):
                    flush()
                    movie.clearCanvas()
                    // пропуск в SCR (индекс 0) = удержание предыдущего кадра
                    var tex: SKTexture? = anim.frames.last?.texture
                    var origin = anim.frames.last?.origin ?? .zero
                    if movie.applyFrame(logicalIndex: index),
                       let crop = movie.renderCanvasCropped() {
                        let t = SKTexture(cgImage: crop.image)
                        t.filteringMode = .nearest
                        tex = t
                        origin = CGPoint(x: CGFloat(crop.x), y: CGFloat(crop.y))
                    }
                    current = AnimFrame(texture: tex, origin: origin, delayMs: 0, sounds: [])
                case .delay(let ms):
                    if let f = current {
                        current = AnimFrame(texture: f.texture, origin: f.origin,
                                            delayMs: f.delayMs + max(0, ms), sounds: f.sounds)
                    }
                case .sound(let sname, _):
                    if let f = current {
                        current = AnimFrame(texture: f.texture, origin: f.origin,
                                            delayMs: f.delayMs, sounds: f.sounds + [sname])
                    }
                default:
                    break
                }
            }
            flush()
            anims[name] = anim
            let textured = anim.frames.filter { $0.texture != nil }.count
            fputs("[Balloon] аним \(name): \(anim.frames.count) кадров (\(textured) с текстурой)\n", stderr)
        }
    }

    // MARK: - Физика (0x10002dd0, дословно)

    private func physicsStep() {
        if alt < targetAlt { alt += 2 } else if alt > targetAlt { alt -= 2 }

        let theta = baseAngle + Double(alt) * 3.0 * Double.pi / 550.0
        let c = cos(theta), s = sin(theta)
        dirA = c + s
        dirB = c - s

        // отражение от границ мира на квантованные азимуты (0x10002e50)
        func snapAngle(_ k: Double) {
            baseAngle -= theta - k // новый θ станет ровно k
        }
        if pos.x < 30, dirA < 0 {
            snapAngle(dirB <= 0 ? 2.0943951023926664 : 5.759586531579833) // 120°/330°
        } else if pos.x > 970, dirA > 0 {
            snapAngle(dirB <= 0 ? 2.617993877990833 : 5.235987755981666)  // 150°/300°
        }
        if pos.y < 30, dirB < 0 {
            snapAngle(dirA < 0 ? 4.188790204785334 : 0.5235987755981666)  // 240°/30°
        } else if pos.y > 970, dirB > 0 {
            snapAngle(dirA < 0 ? 3.665191429187167 : 1.0471975511963334)  // 210°/60°
        }

        // скорость с джиттером (0x10002f80)
        let speed = (1.0 - Double(Int.random(in: 0..<20)) * 0.01) * 0.3
        pos.x += speed * dirA
        pos.y += speed * dirB

        // захват посадки (0x10002f8d): alt ≤ 175 и близко к LAND
        if phase != 5, alt <= 175,
           abs(pos.x - island.x) < 50, abs(pos.y - island.y) < 50 {
            phase = 5
            landingStartOffset = swayY
            landingStartAlt = alt
            soundPlayer?("final3.wav")
            fputs("[Balloon] посадка!\n", stderr)
        }

        // покачивание шара (0x10003039): период 3 тика
        swayCounter -= 1
        if swayCounter < 0 {
            swayCounter = 3
            if swayY < -164 || swayY > -155 { swayDY = -swayDY }
            swayY += swayDY
            if swayX < -2 || swayX > 2 { swayDX = -swayDX }
            swayX += swayDX
        }
    }

    private func gameTick(_ now: TimeInterval) {
        switch phase {
        case 1: // автовзлёт (0x1000282a)
            alt += 15
            advanceBallAnim("RAISE", now: now)
            if alt >= 412 {
                alt = 412
                targetAlt = 412
                phase = 2
                startBallAnim("FLY", now: now)
            }
        case 2:
            physicsStep()
            advanceBallAnim("FLY", now: now)
            if climbCmd > 0 { phase = 3; startBallAnim("RAISE", now: now) }
            if climbCmd < 0 { phase = 4; startBallAnim("FALL", now: now) }
        case 3, 4:
            physicsStep()
            // цикл анимации завершён → цель ±16, поглощение команды (0x1000294f)
            if advanceBallAnim(phase == 3 ? "RAISE" : "FALL", now: now) {
                if phase == 3 {
                    targetAlt = min(targetAlt + 16, 550)
                    climbCmd = max(climbCmd - 1, 0)
                    if climbCmd <= 0 || targetAlt >= 550 { phase = 2; startBallAnim("FLY", now: now) }
                } else {
                    targetAlt = max(targetAlt - 16, 50)
                    climbCmd = min(climbCmd + 1, 0)
                    if climbCmd >= 0 || targetAlt <= 50 { phase = 2; startBallAnim("FLY", now: now) }
                }
            }
        case 5: // снижение на площадку (0x100028aa)
            alt -= 2
            advanceBallAnim("FALL", now: now)
            if alt <= -200, !finished {
                finished = true
                onFinish?(true)
            }
        default:
            break
        }
        updateScreen()
    }

    // MARK: - Анимация шара и моря

    private func startBallAnim(_ name: String, now: TimeInterval) {
        ballAnimName = name
        ballFrame = 0
        ballDeadline = now + TimeInterval(anims[name]?.frames.first?.delayMs ?? 171) / 1000
        playFrameSounds(anims[name]?.frames.first)
    }

    // возвращает true когда цикл анимации завершился
    @discardableResult
    private func advanceBallAnim(_ name: String, now: TimeInterval) -> Bool {
        if ballAnimName != name { startBallAnim(name, now: now); return false }
        guard let anim = anims[name], !anim.frames.isEmpty, now >= ballDeadline else { return false }
        ballFrame += 1
        if ballFrame >= anim.frames.count {
            ballFrame = 0
            ballDeadline = now + TimeInterval(anim.frames[0].delayMs) / 1000
            return true
        }
        ballDeadline = now + TimeInterval(anim.frames[ballFrame].delayMs) / 1000
        playFrameSounds(anim.frames[ballFrame])
        return false
    }

    private func playFrameSounds(_ f: AnimFrame?) {
        for s in f?.sounds ?? [] { soundPlayer?(s) }
    }

    // MARK: - Экран

    private func updateScreen() {
        // canvas-оффсеты (экранная система y-вниз → SpriteKit y-вверх)
        let skyShift = CGFloat(alt) * 120 / 550 - 130 // 0x10001846
        skyNode.position = CGPoint(x: 0, y: screenH - skyShift)

        // море
        if let anim = seaAnim, !anim.frames.isEmpty {
            let f = anim.frames[seaFrame % anim.frames.count]
            seaNode.texture = f.texture
            seaNode.size = f.texture?.size() ?? .zero
            seaNode.position = CGPoint(x: f.origin.x,
                                       y: screenH - (f.origin.y + skyShift + 200))
            seaNode.isHidden = f.texture == nil
        }

        // шар: канва + качание; при посадке оффсет скользит к +20 (0x100028aa)
        var offY = swayY
        if phase == 5 {
            let t = Double(alt + 201) / Double(landingStartAlt + 201)
            offY = 20 + (landingStartOffset - 20) * max(0, min(1, t))
        }
        if let anim = anims[ballAnimName], !anim.frames.isEmpty {
            let f = anim.frames[min(ballFrame, anim.frames.count - 1)]
            ballNode.texture = f.texture
            ballNode.size = f.texture?.size() ?? .zero
            ballNode.position = CGPoint(x: f.origin.x + swayX,
                                        y: screenH - (f.origin.y + offY))
            ballNode.isHidden = f.texture == nil
        }

        // линия моря: остров и LAND не рисуются выше неё (0x10003451)
        let seaLine = skyShift + 200
        cropMask.position = CGPoint(x: 0, y: screenH - seaLine)

        // проекция острова и площадки (0x10003270)
        let h = Double(max(alt, 50) - 50)
        let dx = Double(island.x - pos.x), dy = Double(island.y - pos.y)
        let yb = 500.0 + 0.6 * h
        let dist = (dx * dx + dy * dy + h * h).squareRoot()
        let visible = abs(dx) < yb && abs(dy) < yb
        let scale = 1.0 - min((dist - 50) / 657.1068, 0.85)

        func project(_ node: SKSpriteNode, base: CGSize, textures: [SKTexture]) {
            node.isHidden = !visible
            guard visible, !textures.isEmpty else { return }
            let w = Double(base.width) * scale
            let hh = Double(base.height) * scale
            // мип-уровень: ближайший по ширине (0x1000356b)
            var best = 0
            var bestDiff = Double.infinity
            for (i, t) in textures.enumerated() {
                let d = abs(Double(t.size().width) - w)
                if d < bestDiff { bestDiff = d; best = i }
            }
            node.texture = textures[best]
            node.size = CGSize(width: w, height: hh)
            let sx = (320.0 + w / 2) * dx / yb + 320.0 - w / 2
            let sy = (hh - Double(skyShift) + 199.0) * dy / yb + 400.0 - hh / 2
            node.position = CGPoint(x: sx, y: screenH - CGFloat(sy))
        }
        project(islandNode, base: islandBase, textures: islandTextures)
        project(landNode, base: landBase, textures: landTextures)

        // панель: ленты двигаются под прорезями BAR (0x1000386b, 0x10003831)
        let altY = Double(alt - 550) * 210 / 500 + 37
        altTape.position = CGPoint(x: 358, y: screenH - (CGFloat(altY) + 400))
        let course = atan2(-dirB, dirA)
        let courseX = 83 - (course + Double.pi) * 120 / Double.pi
        courseTape.position = CGPoint(x: CGFloat(courseX), y: screenH - (48 + 400))
        ballDot.position = CGPoint(x: 3 + 0.127 * pos.x, y: screenH - (6 + 0.065 * pos.y) - 400)
    }

    // MARK: - Ввод (0x100021b0, 0x100022d0)

    private func commandUp() {
        guard (2...4).contains(phase), targetAlt < 550, climbCmd < 2 else { return }
        climbCmd += 1
    }

    private func commandDown() {
        guard (2...4).contains(phase), targetAlt > 50, climbCmd > -2 else { return }
        climbCmd -= 1
    }

    func handleMouseDown(at scenePoint: CGPoint) {
        guard !finished else { return }
        let p = CGPoint(x: scenePoint.x, y: screenH - scenePoint.y)
        if buttonRects[0].contains(p) { commandUp() }
        if buttonRects[1].contains(p) { commandDown() }
        if buttonRects[2].contains(p) {
            finished = true
            onFinish?(false)
        }
    }

    func handleMouseDragged(to scenePoint: CGPoint) {}
    func handleMouseUp(at scenePoint: CGPoint) {}
    func handleRightMouseDown(at scenePoint: CGPoint) {}

    func handleKeyDown(keyCode: UInt16) {
        guard !finished else { return }
        switch keyCode {
        case 126: commandUp()    // ↑
        case 125: commandDown()  // ↓
        case 53: // ESC (0x100022ef)
            finished = true
            onFinish?(false)
        default:
            break
        }
    }

    // MARK: - Тик 100мс

    func tick(_ currentTime: TimeInterval) {
        guard !finished else { return }
        if lastTime == 0 { lastTime = currentTime }
        tickAccumulator += currentTime - lastTime
        lastTime = currentTime

        // море анимируется своим темпом
        if let anim = seaAnim, !anim.frames.isEmpty, currentTime >= seaDeadline {
            seaFrame = (seaFrame + 1) % anim.frames.count
            seaDeadline = currentTime
                + TimeInterval(anim.frames[seaFrame].delayMs) / 1000
        }

        if landingTest, phase != 5 { climbCmd = -2 } // тест: жмём «вниз» постоянно
        let step: TimeInterval = 0.1
        while tickAccumulator >= step {
            tickAccumulator -= step
            gameTick(currentTime)
            if finished { break }
        }
    }
}
