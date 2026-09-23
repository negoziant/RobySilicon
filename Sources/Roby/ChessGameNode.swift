import SpriteKit
import ResourceKit

/// Мини-игра №2 «Шашки» (сцена CHESS, StartGame 2, Dames, Find5 — не используется).
/// Вопреки имени CHESS.DAT это русские ШАШКИ на доске 6×6, фигуры — рюмки (R1/G1)
/// и бутылки-дамки (R2/G2). Полный реверс MiniGame.dll game #2:
///
/// - Доска: клик-зона (364,71)-(621,328), клетка 43px (0x10003eb0); board[row*6+col]:
///   1/3 = красные шашка/дамка (низ, ходят вверх), 2/4 = зелёные (верх, вниз).
///   Расстановка (0x10004270): по 6 шашек в 2 ряда на тёмных клетках.
/// - Два матча (0x134): №1 Пятница (красные, человек, первый ход) против пирата,
///   №2 Роби (зелёные, человек, первым ходит ИИ красными). Победа в №1 → VICTORY1 →
///   матч №2; победа в №2 → VICTORY2 → Dames=1. Поражение → реплика ra1138/ra1139 +
///   рестарт текущего матча (0x10005d03). ESC — выход-проигрыш, F1 — рестарт с №1.
/// - Правила (0x10004840/0x10004a00/0x10004ff0/0x10004e60): шашка ходит на 1
///   вперёд по диагонали, бьёт через клетку во все 4 стороны; дамка летает;
///   взятие обязательно; серия взятий одной фигурой (тип фиксируется на начало
///   хода, съеденные снимаются по ходу шагов, дважды одну не бить);
///   превращение — только последним шагом хода на дальнем ряду (lady.wav).
///   Проигрыш — нет фигур или нет ходов. Отмена выбора — клик по исходной клетке.
/// - ИИ (0x100065b0) — СЛУЧАЙНЫЙ: каждые 3.2с выбирает случайную выбираемую
///   фигуру (canSelect уже требует взятие при наличии), затем тыкает случайные
///   клетки, пока ход не пройдёт валидацию.
/// - Хореография хода (0x100058f0): подъём фигуры 1.4с → полёт 2.6с (move.wav /
///   movelady.wav) → спуск 2.0с → снятие съеденной (eat.wav) → следующий шаг.
/// - Сценка слева (MINIGAME.SDT + MV): вся компания за столом; статично — кадр 0
///   P1MOVE0 (№1) / P2MOVE0 (№2); ходы отыгрывают FMOVE0/1 (Пятница), RMOVE0/1
///   (Роби), P1MOVE0/1, P2MOVE0/1 (пираты), победы — VICTORY1/2 (0x100040c0).
final class ChessGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480

    // Геометрия из DLL
    private let boardRect = CGRect(x: 364, y: 71, width: 258, height: 258) // 0x10003eb0
    private let cell = 43
    private func pieceScreenPos(c: Int, r: Int) -> CGPoint { // 0x10004401: (369+c*43, 40+r*43)
        CGPoint(x: CGFloat(369 + c * cell), y: CGFloat(40 + r * cell))
    }
    private func accentScreenPos(c: Int, r: Int) -> CGPoint { // 0x100043a8: (361+c*43, 68+r*43)
        CGPoint(x: CGFloat(361 + c * cell), y: CGFloat(68 + r * cell))
    }

    // Состояние партии
    private var board = [Int](repeating: 0, count: 36) // 0 пусто, 1/3 красные, 2/4 зелёные
    private var match = 1        // 0x134
    private var humanTurn = true // 0x138
    private var path: [(c: Int, r: Int)] = []   // 0xb4: путь формируемого хода
    private var eaten: [(c: Int, r: Int)] = []  // съеденные формируемого хода
    private var mustCapture = false             // 0x120
    private var executing = false               // +4: идёт исполнение хода
    private var modal = false                   // victory/реплика — всё заблокировано
    private var finished = false

    // ИИ: пауза 32 тика × 100мс (0x128)
    private var aiAccumulator: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private let aiDelay: TimeInterval
    private let stepRise: TimeInterval
    private let stepFly: TimeInterval
    private let stepFall: TimeInterval
    private let autoplay: Bool // дебаг: человек играет сам (случайно), как ИИ

    // Спрайты
    private var pieceTextures: [Int: SKTexture] = [:] // 1..4 → R1/G1/R2/G2
    private var accentTexture: SKTexture?
    private let piecesLayer = SKNode()
    private let accentLayer = SKNode()
    private var flyingNode = SKSpriteNode()

    // Сценка за столом
    private struct AnimFrame {
        let texture: SKTexture?
        let origin: CGPoint
        let delayMs: Int
        let sounds: [String]
    }
    private struct Anim { var frames: [AnimFrame] = [] }
    private var anims: [String: Anim] = [:]
    private var sceneNode = SKSpriteNode()
    private var sceneQueue: [String] = []
    private var sceneAnim: Anim?
    private var sceneFrame = 0
    private var sceneDeadline: TimeInterval = 0
    private var sceneCompletion: (() -> Void)?

    init(gameDataPath: String) {
        let env = ProcessInfo.processInfo.environment
        autoplay = env["ROBY_AUTO"] == "chess"
        let fast = env["ROBY_FAST"] != nil
        aiDelay = fast ? 0.3 : 3.2
        stepRise = fast ? 0.1 : 1.4
        stepFly = fast ? 0.2 : 2.6
        stepFall = fast ? 0.1 : 2.0
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../CHESS.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name })
                else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("PALETTE.COL") else { return }
            let pal = try COLPalette(data: colData)

            func texture(_ name: String, transparent: Bool) throws -> SKTexture? {
                guard let d = try resource(name),
                      let img = MiniGameArt.decodeNGB(d, palette: pal, transparent: transparent)
                else { return nil }
                let tex = SKTexture(cgImage: img.image)
                tex.filteringMode = .nearest
                return tex
            }

            if let bg = try texture("BACK.NGB", transparent: false) {
                let node = SKSpriteNode(texture: bg)
                node.anchorPoint = CGPoint(x: 0, y: 0)
                addChild(node)
            }
            for (piece, name) in [1: "R1.NGB", 2: "G1.NGB", 3: "R2.NGB", 4: "G2.NGB"] {
                pieceTextures[piece] = try texture(name, transparent: true)
            }
            accentTexture = try texture("ACCENT.NGB", transparent: true)

            try loadAnims(gameDataPath: gameDataPath, palette: pal)
        } catch {
            fputs("[Chess] ошибка загрузки: \(error)\n", stderr)
        }

        sceneNode.anchorPoint = CGPoint(x: 0, y: 1)
        sceneNode.zPosition = 1
        addChild(sceneNode)
        accentLayer.zPosition = 2
        addChild(accentLayer)
        piecesLayer.zPosition = 3
        addChild(piecesLayer)
        flyingNode.anchorPoint = CGPoint(x: 0, y: 1)
        flyingNode.zPosition = 4
        flyingNode.isHidden = true
        addChild(flyingNode)

        startMatch(1)
        fputs("[Chess] старт: шашки 6×6, матч 1 (Пятница)\n", stderr)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadAnims(gameDataPath: String, palette: COLPalette) throws {
        let root = gameDataPath + "/.."
        let sdt = try NLContainer(path: root + "/MINIGAME.SDT")
        let decompressor = NGIDecompressor()
        for name in ["FMOVE0", "FMOVE1", "RMOVE0", "RMOVE1",
                     "P1MOVE0", "P1MOVE1", "P2MOVE0", "P2MOVE1",
                     "VICTORY1", "VICTORY2"] {
            guard let idx = sdt.entries.firstIndex(where: { $0.name.uppercased() == name + ".FS" }),
                  let fsData = try? sdt.extractResource(at: idx, decompressor: decompressor)
            else {
                fputs("[Chess] нет FS \(name)\n", stderr)
                continue
            }
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
                    var texture: SKTexture? = anim.frames.last?.texture
                    var origin = anim.frames.last?.origin ?? .zero
                    if movie.applyFrame(logicalIndex: index),
                       let crop = movie.renderCanvasCropped() {
                        let tex = SKTexture(cgImage: crop.image)
                        tex.filteringMode = .nearest
                        texture = tex
                        origin = CGPoint(x: CGFloat(crop.x), y: CGFloat(crop.y))
                    }
                    current = AnimFrame(texture: texture, origin: origin, delayMs: 0, sounds: [])
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
        }
    }

    // MARK: - Матчи

    // 0x10004270: расстановка и начальные флаги
    private func startMatch(_ n: Int) {
        match = n
        board = [Int](repeating: 0, count: 36)
        for idx in [1, 3, 5, 6, 8, 10] { board[idx] = 2 }      // зелёные сверху
        for idx in [25, 27, 29, 30, 32, 34] { board[idx] = 1 } // красные снизу
        path = []
        eaten = []
        executing = false
        humanTurn = (n == 1) // в матче 2 первым ходит ИИ (красные)
        aiAccumulator = 0
        redrawPieces()
        redrawAccents()
        showSceneIdle()
        fputs("[Chess] матч \(n): человек = \(n == 1 ? "красные (Пятница)" : "зелёные (Роби)")\n", stderr)
    }

    private func humanOwns(_ piece: Int) -> Bool {
        // матч 1: человек красные (1/3); матч 2: зелёные (2/4)
        let red = piece == 1 || piece == 3
        return match == 1 ? red : !red
    }

    private func sideOnMove(ownedByHuman: Bool) -> Bool { humanTurn == ownedByHuman }

    // MARK: - Правила (по 0x10004840 canMove, 0x10004a00 canJump, 0x10004ff0 canSelect)

    private func piece(_ c: Int, _ r: Int) -> Int {
        guard (0..<6).contains(c), (0..<6).contains(r) else { return -1 }
        return board[r * 6 + c]
    }

    private func isEnemy(_ p: Int, of mine: Int) -> Bool {
        guard p > 0 else { return false }
        let mineRed = mine == 1 || mine == 3
        let otherRed = p == 1 || p == 3
        return mineRed != otherRed
    }

    private func isQueen(_ p: Int) -> Bool { p == 3 || p == 4 }

    // Тихий ход фигуры типа type с (fc,fr) на (c,r); доска текущая
    private func canQuietMove(type: Int, from: (c: Int, r: Int), to: (c: Int, r: Int)) -> Bool {
        guard piece(to.c, to.r) == 0 else { return false }
        let dc = to.c - from.c, dr = to.r - from.r
        switch type {
        case 1: return abs(dc) == 1 && dr == -1 // красная шашка вверх
        case 2: return abs(dc) == 1 && dr == 1  // зелёная вниз
        case 3, 4: // дамка: пустая диагональ
            guard abs(dc) == abs(dr), dc != 0 else { return false }
            let sc = dc > 0 ? 1 : -1, sr = dr > 0 ? 1 : -1
            var x = from.c + sc, y = from.r + sr
            while x != to.c {
                if piece(x, y) != 0 { return false }
                x += sc; y += sr
            }
            return true
        default: return false
        }
    }

    // Взятие: прыжок с from на to фигурой type; возвращает съеденную клетку.
    // Съеденные текущей серии (eatenSoFar) перепрыгивать нельзя (0x10004ae7).
    private func captureAt(type: Int, from: (c: Int, r: Int), to: (c: Int, r: Int),
                           eatenSoFar: [(c: Int, r: Int)]) -> (c: Int, r: Int)? {
        guard piece(to.c, to.r) == 0 else { return nil }
        let dc = to.c - from.c, dr = to.r - from.r
        guard abs(dc) == abs(dr), dc != 0 else { return nil }
        let sc = dc > 0 ? 1 : -1, sr = dr > 0 ? 1 : -1
        if !isQueen(type) {
            guard abs(dc) == 2 else { return nil }
            let mid = (c: from.c + sc, r: from.r + sr)
            guard isEnemy(piece(mid.c, mid.r), of: type),
                  !eatenSoFar.contains(where: { $0 == mid }) else { return nil }
            return mid
        }
        // дамка: ровно один враг на пути, свои и съеденные — блок
        var victim: (c: Int, r: Int)?
        var x = from.c + sc, y = from.r + sr
        while x != to.c {
            let p = piece(x, y)
            if p != 0 {
                guard isEnemy(p, of: type), victim == nil,
                      !eatenSoFar.contains(where: { $0 == (x, y) }) else { return nil }
                victim = (x, y)
            }
            x += sc; y += sr
        }
        return victim
    }

    // Есть ли у фигуры (учитывая тип type и позицию at) хоть одно взятие
    private func hasCapture(type: Int, at: (c: Int, r: Int),
                            eatenSoFar: [(c: Int, r: Int)] = [],
                            excluding pathCells: [(c: Int, r: Int)] = []) -> Bool {
        let range = isQueen(type) ? 2...5 : 2...2
        for sc in [-1, 1] {
            for sr in [-1, 1] {
                for d in range {
                    let to = (c: at.c + sc * d, r: at.r + sr * d)
                    guard (0..<6).contains(to.c), (0..<6).contains(to.r) else { break }
                    if pathCells.contains(where: { $0 == to }) { continue }
                    if captureAt(type: type, from: at, to: to, eatenSoFar: eatenSoFar) != nil {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func hasQuietMove(type: Int, at: (c: Int, r: Int)) -> Bool {
        let range = isQueen(type) ? 1...5 : 1...1
        for sc in [-1, 1] {
            for sr in [-1, 1] {
                for d in range {
                    let to = (c: at.c + sc * d, r: at.r + sr * d)
                    guard (0..<6).contains(to.c), (0..<6).contains(to.r) else { break }
                    if canQuietMove(type: type, from: at, to: to) { return true }
                }
            }
        }
        return false
    }

    // Сторона humanSide имеет хоть одно взятие?
    private func sideHasCapture(human: Bool) -> Bool {
        for r in 0..<6 {
            for c in 0..<6 {
                let p = piece(c, r)
                if p > 0, humanOwns(p) == human,
                   hasCapture(type: p, at: (c, r)) { return true }
            }
        }
        return false
    }

    // 0x10004ff0: можно ли выбрать фигуру стороной на ходу
    private func canSelect(_ c: Int, _ r: Int) -> Bool {
        let p = piece(c, r)
        guard p > 0, sideOnMove(ownedByHuman: humanOwns(p)) else { return false }
        mustCapture = sideHasCapture(human: humanOwns(p))
        if mustCapture {
            return hasCapture(type: p, at: (c, r))
        }
        return hasQuietMove(type: p, at: (c, r)) || hasCapture(type: p, at: (c, r))
    }

    // MARK: - Клик по клетке (0x100045d0) — общий для человека и ИИ

    @discardableResult
    private func cellClick(_ c: Int, _ r: Int) -> Bool {
        guard !executing, !modal else { return false }
        if let first = path.first, first == (c, r) {
            // клик по исходной клетке — сброс выбора
            path = []
            eaten = []
            redrawAccents()
            return true
        }
        if path.isEmpty {
            guard canSelect(c, r) else { return false }
            path = [(c, r)]
            redrawAccents()
            return true
        }
        let type = piece(path[0].c, path[0].r)
        let from = path[path.count - 1]
        // прыжок-взятие (в любой момент серии); цель не из пути
        if !path.contains(where: { $0 == (c, r) }),
           let victim = captureAt(type: type, from: from, to: (c, r), eatenSoFar: eaten) {
            eaten.append(victim)
            path.append((c, r))
            redrawAccents()
            // серия продолжается, пока есть взятия (0x10004e60)
            if !hasCapture(type: type, at: (c, r), eatenSoFar: eaten, excluding: path) {
                executeMove()
            }
            return true
        }
        // тихий ход — только первым шагом и только без обязательного взятия
        if path.count == 1, !mustCapture,
           canQuietMove(type: type, from: from, to: (c, r)) {
            path.append((c, r))
            executeMove()
            return true
        }
        return false
    }

    // MARK: - Исполнение хода (0x100058f0 state 1→2→3 на каждый шаг)

    private func executeMove() {
        executing = true
        redrawAccents()
        // сценка: код за каждый шаг (0x100046dc); MOVE1 = взятие, MOVE0 = тихий
        let mover = sceneAnimName(capture: !eaten.isEmpty)
        for _ in 0..<(path.count - 1) { sceneQueue.append(mover) }
        runStep(0)
    }

    private func sceneAnimName(capture: Bool) -> String {
        let suffix = capture ? "1" : "0"
        if humanTurn {
            return (match == 1 ? "FMOVE" : "RMOVE") + suffix
        }
        return (match == 1 ? "P1MOVE" : "P2MOVE") + suffix
    }

    private func runStep(_ i: Int) {
        let from = path[i], to = path[i + 1]
        var type = board[from.r * 6 + from.c]
        board[from.r * 6 + from.c] = 0
        redrawPieces()

        let fromPos = pieceScreenPos(c: from.c, r: from.r)
        let toPos = pieceScreenPos(c: to.c, r: to.r)
        flyingNode.texture = pieceTextures[type]
        flyingNode.size = pieceTextures[type]?.size() ?? .zero
        flyingNode.position = CGPoint(x: fromPos.x, y: screenH - fromPos.y)
        flyingNode.isHidden = false

        // превращение на последнем шаге при достижении дальнего ряда (0x10005abd)
        let lastStep = (i == path.count - 2)
        let promoted = lastStep && !isQueen(type)
            && ((type == 1 && to.r == 0) || (type == 2 && to.r == 5))

        let rise = SKAction.moveBy(x: 0, y: 20, duration: stepRise) // подъём (0x10005c8e)
        let fly = SKAction.move(to: CGPoint(x: toPos.x, y: screenH - toPos.y + 10),
                                duration: stepFly)                  // полёт на высоте 10
        let land = SKAction.move(to: CGPoint(x: toPos.x, y: screenH - toPos.y),
                                 duration: stepFall)                // спуск (0x100059f4)
        let fix = SKAction.run { [weak self] in
            guard let self else { return }
            if promoted {
                type += 2 // 1→3, 2→4
                self.soundPlayer?("lady.wav")
            } else {
                self.soundPlayer?(self.isQueen(type) ? "movelady.wav" : "move.wav")
            }
            if promoted { self.flyingNode.texture = self.pieceTextures[type] }
        }
        let finishStep = SKAction.run { [weak self] in
            guard let self else { return }
            self.board[to.r * 6 + to.c] = type
            self.flyingNode.isHidden = true
            // снятие съеденной этим шагом (0x10005946: по одной за шаг)
            if i < self.eaten.count {
                let v = self.eaten[i]
                self.board[v.r * 6 + v.c] = 0
                self.soundPlayer?("eat.wav")
            }
            self.redrawPieces()
            if i + 1 < self.path.count - 1 {
                self.runStep(i + 1)
            } else {
                self.moveCompleted()
            }
        }
        flyingNode.run(.sequence([rise, fly, fix, land, finishStep]))
    }

    // MARK: - Смена хода и исход (0x100059c2, 0x10006760)

    private func moveCompleted() {
        path = []
        eaten = []
        executing = false
        humanTurn.toggle()
        aiAccumulator = 0
        redrawAccents()

        // checkWinner: сторона без фигур или без ходов проиграла
        if let humanWon = winnerIsHuman() {
            modal = true
            if humanWon {
                let anim = match == 1 ? "VICTORY1" : "VICTORY2"
                playScene(anim) { [weak self] in
                    guard let self else { return }
                    if self.match == 1 {
                        self.fadeAndThen { self.modal = false; self.startMatch(2) }
                    } else {
                        self.finished = true
                        self.onFinish?(true) // Dames=1 (0x10006c2d: state 4)
                    }
                }
            } else {
                // поражение: реплика пирата + рестарт матча (0x10005d23)
                soundPlayer?(match == 1 ? "ra1138.wav" : "ra1139.wav")
                fadeAndThen { [weak self] in
                    guard let self else { return }
                    self.modal = false
                    self.startMatch(self.match)
                }
            }
        }
    }

    // nil = игра продолжается; иначе — выиграл ли человек
    private func winnerIsHuman() -> Bool? {
        var count = [true: 0, false: 0]
        var canAct = [true: false, false: false]
        for r in 0..<6 {
            for c in 0..<6 {
                let p = piece(c, r)
                guard p > 0 else { continue }
                let human = humanOwns(p)
                count[human]! += 1
                if !canAct[human]!,
                   hasQuietMove(type: p, at: (c, r)) || hasCapture(type: p, at: (c, r)) {
                    canAct[human] = true
                }
            }
        }
        if count[humanTurn]! == 0 || !canAct[humanTurn]! { return !humanTurn }
        return nil
    }

    private func fadeAndThen(_ block: @escaping () -> Void) {
        let cover = SKSpriteNode(color: .black, size: CGSize(width: 640, height: 480))
        cover.anchorPoint = .zero
        cover.alpha = 0
        cover.zPosition = 100
        addChild(cover)
        cover.run(.sequence([
            .fadeAlpha(to: 1, duration: 0.8),
            .wait(forDuration: 1.2), // реплика успевает прозвучать
            .run(block),
            .fadeAlpha(to: 0, duration: 0.8),
            .removeFromParent(),
        ]))
    }

    // MARK: - ИИ (0x100065b0): случайный валидный ход раз в 3.2с

    private func aiAct() {
        if path.isEmpty {
            var candidates: [(c: Int, r: Int)] = []
            for r in 0..<6 {
                for c in 0..<6 where canSelect(c, r) {
                    candidates.append((c, r))
                }
            }
            guard let pick = candidates.randomElement() else { return }
            cellClick(pick.c, pick.r)
            return
        }
        // случайные клики до валидного (0x1000662f); с запасным полным перебором
        for _ in 0..<200 {
            let c = Int.random(in: 0..<6), r = Int.random(in: 0..<6)
            if (c, r) == path[0] { continue }
            if cellClick(c, r) { return }
        }
        for r in 0..<6 {
            for c in 0..<6 where !((c, r) == path[0]) {
                if cellClick(c, r) { return }
            }
        }
    }

    // MARK: - Рендер

    private func redrawPieces() {
        piecesLayer.removeAllChildren()
        for r in 0..<6 {
            for c in 0..<6 {
                let p = piece(c, r)
                guard p > 0, let tex = pieceTextures[p] else { continue }
                let node = SKSpriteNode(texture: tex)
                node.anchorPoint = CGPoint(x: 0, y: 1)
                node.size = tex.size()
                let pos = pieceScreenPos(c: c, r: r)
                node.position = CGPoint(x: pos.x, y: screenH - pos.y)
                piecesLayer.addChild(node)
            }
        }
    }

    private func redrawAccents() {
        accentLayer.removeAllChildren()
        guard !executing, let tex = accentTexture else { return }
        for cellPos in path {
            let node = SKSpriteNode(texture: tex)
            node.anchorPoint = CGPoint(x: 0, y: 1)
            node.size = tex.size()
            let pos = accentScreenPos(c: cellPos.c, r: cellPos.r)
            node.position = CGPoint(x: pos.x, y: screenH - pos.y)
            accentLayer.addChild(node)
        }
    }

    // MARK: - Сценка за столом

    private func showSceneIdle() {
        let idle = anims[match == 1 ? "P1MOVE0" : "P2MOVE0"]
        showSceneFrame(idle?.frames.first)
    }

    private func showSceneFrame(_ f: AnimFrame?) {
        guard let f else {
            sceneNode.isHidden = true
            return
        }
        sceneNode.texture = f.texture
        sceneNode.size = f.texture?.size() ?? .zero
        sceneNode.position = CGPoint(x: f.origin.x, y: screenH - f.origin.y)
        sceneNode.isHidden = f.texture == nil
        for s in f.sounds { soundPlayer?(s) }
    }

    private func playScene(_ name: String, completion: (() -> Void)? = nil) {
        guard let anim = anims[name], !anim.frames.isEmpty else {
            completion?()
            return
        }
        sceneAnim = anim
        sceneFrame = 0
        sceneCompletion = completion
        showSceneFrame(anim.frames[0])
        sceneDeadline = CACurrentMediaTime() + TimeInterval(anim.frames[0].delayMs) / 1000
    }

    private func tickScene(_ now: TimeInterval) {
        if sceneAnim == nil, !sceneQueue.isEmpty {
            playScene(sceneQueue.removeFirst())
        }
        guard let anim = sceneAnim, now >= sceneDeadline else { return }
        if sceneFrame + 1 < anim.frames.count {
            sceneFrame += 1
            showSceneFrame(anim.frames[sceneFrame])
            sceneDeadline = now + TimeInterval(anim.frames[sceneFrame].delayMs) / 1000
        } else {
            sceneAnim = nil
            showSceneIdle()
            let done = sceneCompletion
            sceneCompletion = nil
            done?()
        }
    }

    // MARK: - Ввод

    func handleMouseDown(at scenePoint: CGPoint) {
        guard !finished, !modal, !executing else { return }
        guard humanTurn || autoplay else { return }
        let p = CGPoint(x: scenePoint.x, y: screenH - scenePoint.y)
        guard boardRect.contains(p) else { return }
        let c = Int(p.x - boardRect.minX) / cell
        let r = Int(p.y - boardRect.minY) / cell
        guard c < 6, r < 6 else { return }
        cellClick(c, r)
    }

    func handleMouseDragged(to scenePoint: CGPoint) {}
    func handleMouseUp(at scenePoint: CGPoint) {}
    func handleRightMouseDown(at scenePoint: CGPoint) {}

    func handleKeyDown(keyCode: UInt16) {
        switch keyCode {
        case 53: // ESC → выход-проигрыш (0x10003ff0)
            guard !finished else { return }
            finished = true
            onFinish?(false)
        case 122: // F1 → рестарт с матча 1 (0x10003fc9)
            guard !modal, !finished else { return }
            flyingNode.removeAllActions()
            flyingNode.isHidden = true
            sceneQueue = []
            sceneAnim = nil
            startMatch(1)
        default:
            break
        }
    }

    // MARK: - Тик

    func tick(_ currentTime: TimeInterval) {
        defer { lastTick = currentTime }
        tickScene(currentTime)
        guard !finished, !modal, !executing else { return }

        let aiMove = !humanTurn || (autoplay && humanTurn)
        guard aiMove else { return }
        if lastTick > 0 { aiAccumulator += currentTime - lastTick }
        if aiAccumulator >= aiDelay {
            aiAccumulator = 0
            aiAct()
        }
    }
}
