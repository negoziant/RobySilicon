import SpriteKit
import ResourceKit

/// Мини-игра №4 «Орган из труб» (PALACE, StartGame 4, OrganOK, Tubs).
/// Полный реверс MiniGame.dll game #4 (функции 0x1000d900 init, 0x1000de30 клик,
/// 0x1000ec60 драйвер персонажа, 0x1000ef30 мелодия+вердикт):
///
/// - 8 предметов: 0-5 бамбуковые трубы PIPE10-15, 6 перо PIPE16, 7 тёмная трубка
///   PIPE17. Наличие — биты Tubs: 1=перо, 2=трубка, 4=бамбук (0x1000da5c).
/// - Стойка наверху: домашняя позиция предмета i = (i*80, 5) (0x1000d887).
/// - 8 зон-мундштуков внизу: x = -2+i*75, ширина 75, y 400..470 (0x1000da26).
///   Дроп в зону: позиция = оффсет предмета (0x1002a528) + (зона*75-2, 400).
///   Занятая зона выталкивает прежний предмет домой.
/// - Роби ходит за каркасом органа (PIPE18) по позициям 0..7 с шагом 24px
///   и анимируется FS из MINIGAME.SDT; очередь действий (0x10030324):
///   1/2 = шаг влево/вправо, 3/4 = вставить/вынуть бамбук (TUB_IN/OUT),
///   5/6 = перо (FEAR_IN/OUT), 7/8 = трубка (PIPE_IN/OUT), 9 = играть (LISTEN).
/// - Клик по даме (82..159, 203..370) — образец мелодии (SAMPLE + sample.wav).
/// - Клик по органу (202..263, 200..301) — вождь качает воздух (AIR1), затем
///   15 нот по зонам-паттерну [0,1,0,1,3,0,2,4,4,4,5,6,1,1,7]; звук ноты =
///   предмет в зоне: [pipe00,02,04,01,03,05,06,07,08][id] (0x1000e920);
///   длительности [2,2,2,2,2,2,4,2,2,2,1,1,2,2,4] × 150 мс (0x1002a57c).
/// - Победа (0x1000f24e): зоны = [3,1,2,4,5,6,7,8] или [3,8,2,4,5,6,7,1]
///   (1-базные id; трубка и короткая труба звучат одинаково). ESC — выход.
final class OrganGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480

    // Таблицы из MiniGame.dll
    private let placeOffsets: [(Int, Int)] = [(-2, -14), (0, -5), (2, 0), (2, -4),
                                              (2, -8), (0, -5), (9, -4), (-3, 0)] // 0x1002a528
    private let noteSounds = ["pipe00.wav", "pipe02.wav", "pipe04.wav", "pipe01.wav",
                              "pipe03.wav", "pipe05.wav", "pipe06.wav", "pipe07.wav",
                              "pipe08.wav"] // 0x1000e920: индекс = id предмета в зоне
    private let melodyPattern = [0, 1, 0, 1, 3, 0, 2, 4, 4, 4, 5, 6, 1, 1, 7] // 0x1000f016
    private let noteDurations = [2, 2, 2, 2, 2, 2, 4, 2, 2, 2, 1, 1, 2, 2, 4] // 0x1002a57c
    private let tempoMs = 150 // 0x1002a570
    private let ladyRect = CGRect(x: 83, y: 204, width: 76, height: 166)  // 0x1000e099
    private let organRect = CGRect(x: 202, y: 200, width: 62, height: 102) // 0x1000e0cb

    private final class Item {
        let id: Int // 0-базный; в проверке победы используется id+1
        let node: SKSpriteNode
        let home: CGPoint // экранные коорд. (y вниз), верх-лево спрайта
        var zone: Int? // nil = в стойке или в руке
        init(id: Int, node: SKSpriteNode, home: CGPoint) {
            self.id = id
            self.node = node
            self.home = home
        }
    }

    private var items: [Item] = [] // только имеющиеся по битам Tubs
    private var held: Item?
    private var finished = false

    // MARK: - Анимации персонажей (FS из MINIGAME.SDT + MV из корня GameData)

    private struct AnimFrame {
        let texture: SKTexture?
        let origin: CGPoint // позиция кропа в канве 640×480 (y вниз)
        let delayMs: Int
        let sounds: [String]
    }

    private struct Anim {
        var frames: [AnimFrame] = []
    }

    private var anims: [String: Anim] = [:]

    // Роби: позиция 0..7 за органом, очередь действий как в DLL
    private var robyNode = SKSpriteNode()
    private var robyPos = 0     // 0x10030348 — фактическая позиция
    private var queuedPos = 0   // 0x1003034c — позиция на конец очереди
    private var queue: [Int] = []
    private var robyAnim: Anim?
    private var robyFrame = 0
    private var robyDeadline: TimeInterval = 0
    private var robyAction = 0 // текущий код действия (0 = STAY)

    // Дама (SAMPLE) и вождь-качальщик (AIR1): кадр 0 в покое, анимация по событию
    private var ladyNode = SKSpriteNode()
    private var ladyAnim: Anim?
    private var ladyFrame = 0
    private var ladyPlaying = false
    private var ladyDeadline: TimeInterval = 0

    private var pumperNode = SKSpriteNode()
    private var pumperAnim: Anim?
    private var pumperFrame = 0
    private var pumperPlaying = false
    private var pumperLooping = false
    private var pumperDeadline: TimeInterval = 0

    // Мелодия: расписание нот (offsetSec, note), стартовое время
    private var melodyStart: TimeInterval?
    private var melodySchedule: [(at: TimeInterval, note: Int)] = []
    private var melodyIndex = 0
    private var melodyEndsAt: TimeInterval = 0
    private var pendingPlay = false // орган нажат, ждём окончания подготовки

    init(gameDataPath: String, tubs: Int) {
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../PIPE.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name })
                else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("BACK.COL") else { return }
            let pal = try COLPalette(data: colData)

            func sprite(_ name: String, transparent: Bool, z: CGFloat) throws -> SKSpriteNode? {
                guard let d = try resource(name),
                      let img = MiniGameArt.decodeNGB(d, palette: pal, transparent: transparent)
                else { return nil }
                let tex = SKTexture(cgImage: img.image)
                tex.filteringMode = .nearest
                let node = SKSpriteNode(texture: tex)
                node.anchorPoint = CGPoint(x: 0, y: 1)
                node.position = CGPoint(x: CGFloat(img.x), y: screenH - CGFloat(img.y))
                node.zPosition = z
                return node
            }

            if let bg = try sprite("BACK.NGB", transparent: false, z: 0) { addChild(bg) }
            if let organ = try sprite("PIPE18.NGB", transparent: true, z: 2) { addChild(organ) }
            if let strip = try sprite("PIPE112.NGB", transparent: true, z: 4) { addChild(strip) }

            // Предметы по битам Tubs (0x1000da5c): 4 → трубы 0-5, 1 → перо 6, 2 → трубка 7
            var present: [Int] = []
            if tubs & 4 != 0 { present += [0, 1, 2, 3, 4, 5] }
            if tubs & 1 != 0 { present.append(6) }
            if tubs & 2 != 0 { present.append(7) }
            for id in present {
                guard let node = try sprite("PIPE1\(id).NGB", transparent: true, z: 3) else { continue }
                let home = CGPoint(x: CGFloat(id * 80), y: 5) // 0x1000d887: (i*80, 5)
                node.position = CGPoint(x: home.x, y: screenH - home.y)
                addChild(node)
                items.append(Item(id: id, node: node, home: home))
            }

            try loadAnims(gameDataPath: gameDataPath, palette: pal)
        } catch {
            fputs("[Organ] ошибка загрузки: \(error)\n", stderr)
        }
        fputs("[Organ] старт: Tubs=\(tubs), предметов \(items.count)\n", stderr)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Привязка слотов анимаций к FS (0x1000e820): STAY/STEP_L/STEP_R,
    // TUB/PIPE/FEAR_IN|OUT, LISTEN, SAMPLE, AIR1
    private func loadAnims(gameDataPath: String, palette: COLPalette) throws {
        let root = gameDataPath + "/.."
        let sdt = try NLContainer(path: root + "/MINIGAME.SDT")
        let decompressor = NGIDecompressor()

        let names = ["STAY", "STEP_L", "STEP_R", "TUB_IN", "TUB_OUT",
                     "FEAR_IN", "FEAR_OUT", "PIPE_IN", "PIPE_OUT",
                     "LISTEN", "SAMPLE", "AIR1"]
        for name in names {
            guard let idx = sdt.entries.firstIndex(where: { $0.name.uppercased() == name + ".FS" }),
                  let fsData = try? sdt.extractResource(at: idx, decompressor: decompressor)
            else {
                fputs("[Organ] нет FS \(name)\n", stderr)
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
                    // кадры walk/катсцен MV самодостаточны — канву чистить всегда;
                    // пропуск в SCR (индекс 0) = удержание предыдущего кадра
                    movie.clearCanvas()
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

        // Персонажи. Роби за органом (z=1, каркас PIPE18 на z=2 его перекрывает)
        robyNode.anchorPoint = CGPoint(x: 0, y: 1)
        robyNode.zPosition = 1
        addChild(robyNode)
        ladyNode.anchorPoint = CGPoint(x: 0, y: 1)
        ladyNode.zPosition = 1
        addChild(ladyNode)
        pumperNode.anchorPoint = CGPoint(x: 0, y: 1)
        pumperNode.zPosition = 1
        addChild(pumperNode)

        robyAnim = anims["STAY"]
        showFrame(of: robyAnim, index: 0, on: robyNode, offset: robyOffset())
        ladyAnim = anims["SAMPLE"]
        pumperAnim = anims["AIR1"]
        showFrame(of: pumperAnim, index: 0, on: pumperNode, offset: .zero)
        // Дама играет образец при входе (init 0x1000d9ad: поле 0x1c0 = 0)
        startLady()
    }

    // SetPos Роби (0x1000ed20): оффсет канвы = (поз*24-16, 45)
    private func robyOffset() -> CGPoint {
        CGPoint(x: CGFloat(robyPos * 24 - 16), y: 45)
    }

    private func showFrame(of anim: Anim?, index: Int, on node: SKSpriteNode, offset: CGPoint) {
        guard let anim, index < anim.frames.count else { return }
        let f = anim.frames[index]
        node.texture = f.texture
        node.size = f.texture?.size() ?? .zero
        node.position = CGPoint(x: f.origin.x + offset.x,
                                y: screenH - (f.origin.y + offset.y))
        node.isHidden = f.texture == nil
        for s in f.sounds { soundPlayer?(s) }
    }

    // MARK: - Очередь действий Роби (0x1000e400 запись, 0x1000ec60 чтение)

    private func enqueueWalk(to zone: Int) {
        let steps = abs(queuedPos - zone)
        if steps > 0 {
            let code = zone > queuedPos ? 2 : 1
            queue.append(contentsOf: Array(repeating: code, count: steps))
        }
        queuedPos = zone
    }

    private func startAction(_ code: Int, at time: TimeInterval) {
        // Кромки как в DLL (0x1000ed02): у краёв шаг превращается в STAY
        var act = code
        if robyPos == 0 && act == 1 { act = 0 }
        if robyPos == 7 && act == 2 { act = 0 }
        robyAction = act
        let names = ["STAY", "STEP_L", "STEP_R", "TUB_IN", "TUB_OUT",
                     "FEAR_IN", "FEAR_OUT", "PIPE_IN", "PIPE_OUT", "LISTEN"]
        robyAnim = anims[names[act]]
        robyFrame = 0
        showFrame(of: robyAnim, index: 0, on: robyNode, offset: robyOffset())
        robyDeadline = time + TimeInterval(robyAnim?.frames.first?.delayMs ?? 171) / 1000
    }

    private func finishAction(at time: TimeInterval) {
        // Движение применяется по ОКОНЧАНИИ шага (0x1000eca1)
        if robyAction == 2 && robyPos < 7 { robyPos += 1 }
        if robyAction == 1 && robyPos > 0 { robyPos -= 1 }
        if robyAction == 9 {
            // Роби отыграл LISTEN — мелодия, как только вождь накачал воздух
            pendingPlay = true
            robyAction = 0
            tryStartMelody(at: time)
            return
        }
        if queue.isEmpty {
            robyAction = 0
            robyAnim = anims["STAY"]
            robyFrame = 0
            showFrame(of: robyAnim, index: 0, on: robyNode, offset: robyOffset())
        } else {
            startAction(queue.removeFirst(), at: time)
        }
    }

    // MARK: - Мелодия (0x1000ef30)

    private func organClicked(at time: TimeInterval) {
        guard melodyStart == nil, !pendingPlay else { return }
        // 0x1000e0fc: очередь сбрасывается, позиция очереди = фактической,
        // добавляется код 9; дама замолкает, вождь начинает качать (AIR1)
        queue.removeAll()
        queuedPos = robyPos
        ladyPlaying = false
        showFrame(of: ladyAnim, index: 0, on: ladyNode, offset: .zero)
        pumperPlaying = true
        pumperLooping = false
        pumperFrame = 0
        showFrame(of: pumperAnim, index: 0, on: pumperNode, offset: .zero)
        pumperDeadline = time + TimeInterval(pumperAnim?.frames.first?.delayMs ?? 171) / 1000
        if robyAction == 0 {
            startAction(9, at: time)
        } else {
            queue.append(9)
        }
    }

    private func tryStartMelody(at time: TimeInterval) {
        // Ждём и Роби (LISTEN), и вождя (AIR1) — как DLL ждёт флаг 0x1c4
        guard pendingPlay, !pumperPlaying || pumperLooping else { return }
        pendingPlay = false

        var zoneContent = [Int](repeating: 0, count: 8) // 0 = пусто, иначе id+1
        for item in items {
            if let z = item.zone { zoneContent[z] = item.id + 1 }
        }
        melodySchedule = []
        var t = TimeInterval(2 * tempoMs) / 1000 // 0x1002a578: старт через 2 такта
        for (k, zone) in melodyPattern.enumerated() {
            melodySchedule.append((at: t, note: zoneContent[zone]))
            t += TimeInterval(noteDurations[k] * tempoMs) / 1000
        }
        melodyStart = time
        melodyIndex = 0
        melodyEndsAt = time + t
        // вождь качает воздух всю мелодию
        pumperPlaying = true
        pumperLooping = true
        fputs("[Organ] мелодия: \(melodySchedule.map { $0.note })\n", stderr)
    }

    private func melodyFinished() {
        melodyStart = nil
        pumperPlaying = false
        pumperLooping = false
        showFrame(of: pumperAnim, index: 0, on: pumperNode, offset: .zero)
        showFrame(of: anims["STAY"], index: 0, on: robyNode, offset: robyOffset())
        robyAnim = anims["STAY"]

        // Проверка победы (0x1000f24e): [3,1,2,4,5,6,7,8] или [3,8,2,4,5,6,7,1]
        var zoneContent = [Int](repeating: 0, count: 8)
        for item in items {
            if let z = item.zone { zoneContent[z] = item.id + 1 }
        }
        if zoneContent == [3, 1, 2, 4, 5, 6, 7, 8] || zoneContent == [3, 8, 2, 4, 5, 6, 7, 1] {
            finished = true
            run(.sequence([
                .wait(forDuration: 0.8),
                .run { [weak self] in self?.onFinish?(true) },
            ]))
        }
    }

    private func startLady() {
        ladyPlaying = true
        ladyFrame = 0
        showFrame(of: ladyAnim, index: 0, on: ladyNode, offset: .zero)
        ladyDeadline = CACurrentMediaTime() + TimeInterval(ladyAnim?.frames.first?.delayMs ?? 171) / 1000
    }

    // MARK: - Ввод (координаты сцены y-вверх → экранные y-вниз)

    private func zoneRect(_ i: Int) -> CGRect { // 0x1000da26: x=-2+i*75, y 400..470
        CGRect(x: CGFloat(-2 + i * 75), y: 400, width: 75, height: 70)
    }

    private func zoneAt(_ p: CGPoint) -> Int? {
        for i in 0..<8 where zoneRect(i).contains(p) { return i }
        return nil
    }

    func handleMouseDown(at scenePoint: CGPoint) {
        guard !finished, melodyStart == nil, !pendingPlay else { return }
        let p = CGPoint(x: scenePoint.x, y: screenH - scenePoint.y)

        if let held {
            dropItem(held, at: p)
            return
        }

        // Взять предмет (0x1000de70: последний подошедший в порядке 0..7)
        var hit: Item?
        for item in items {
            let sz = item.node.size
            let rect = CGRect(x: item.node.position.x, y: screenH - item.node.position.y,
                              width: sz.width, height: sz.height)
            if rect.contains(p) { hit = item }
        }
        if let item = hit {
            held = item
            item.node.zPosition = 6
            item.node.position = CGPoint(x: p.x - item.node.size.width / 2,
                                         y: screenH - (p.y - item.node.size.height / 2))
            // Роби реагирует только на предмет из зоны (0x1000df4f: 0x38 != -1)
            if let z = item.zone {
                enqueueWalk(to: z)
                let outCode = item.id == 6 ? 6 : (item.id == 7 ? 8 : 4) // 0x1000e01a
                queue.append(outCode)
                item.zone = nil
                pumpQueue()
            }
            return
        }

        if ladyRect.contains(p) { // повтор образца (0x1000e099)
            startLady()
            return
        }
        if organRect.contains(p) { // сыграть свою мелодию (0x1000e0cb)
            organClicked(at: CACurrentMediaTime())
        }
    }

    private func dropItem(_ item: Item, at p: CGPoint) {
        held = nil
        item.node.zPosition = 3
        guard let zone = zoneAt(p) else {
            // мимо зон — домой в стойку (0x1000e2a7)
            item.node.position = CGPoint(x: item.home.x, y: screenH - item.home.y)
            item.zone = nil
            return
        }
        // Выталкиваем прежний предмет из зоны домой (0x1000e1c7)
        if let old = items.first(where: { $0.zone == zone && $0 !== item }) {
            old.zone = nil
            old.node.position = CGPoint(x: old.home.x, y: screenH - old.home.y)
        }
        item.zone = zone
        let off = placeOffsets[item.id] // 0x1002a528 + зона*75-2, низ y=400
        item.node.position = CGPoint(x: CGFloat(off.0 + zone * 75 - 2),
                                     y: screenH - CGFloat(off.1 + 400))
        enqueueWalk(to: zone)
        let inCode = item.id == 6 ? 5 : (item.id == 7 ? 7 : 3) // 0x1000e26b
        queue.append(inCode)
        pumpQueue()
    }

    private func pumpQueue() {
        if robyAction == 0, !queue.isEmpty {
            startAction(queue.removeFirst(), at: CACurrentMediaTime())
        }
    }

    func handleMouseDragged(to scenePoint: CGPoint) {
        guard let item = held else { return }
        let p = CGPoint(x: scenePoint.x, y: screenH - scenePoint.y)
        item.node.position = CGPoint(x: p.x - item.node.size.width / 2,
                                     y: screenH - (p.y - item.node.size.height / 2))
    }

    func handleMouseUp(at scenePoint: CGPoint) {
        // Поддержка обычного drag&drop: отпускание над зоной кладёт предмет.
        // Отпускание вне зон оставляет предмет «на курсоре» (клик-клик оригинала).
        guard let item = held else { return }
        let p = CGPoint(x: scenePoint.x, y: screenH - scenePoint.y)
        if zoneAt(p) != nil {
            dropItem(item, at: p)
        }
    }

    func handleRightMouseDown(at scenePoint: CGPoint) {}

    func handleKeyDown(keyCode: UInt16) {
        if keyCode == 53 { // ESC (0x1000e4e0: выход без победы)
            guard !finished else { return }
            finished = true
            onFinish?(false)
        }
    }

    // MARK: - Тик: анимации и мелодия

    func tick(_ currentTime: TimeInterval) {
        // Роби
        if let anim = robyAnim, robyAction != 0 || robyFrame > 0 {
            if currentTime >= robyDeadline {
                if robyFrame + 1 < anim.frames.count {
                    robyFrame += 1
                    showFrame(of: anim, index: robyFrame, on: robyNode, offset: robyOffset())
                    robyDeadline = currentTime
                        + TimeInterval(anim.frames[robyFrame].delayMs) / 1000
                } else if robyAction != 0 {
                    robyFrame = 0
                    finishAction(at: currentTime)
                }
            }
        }

        // Дама: образец мелодии, в покое — кадр 0
        if ladyPlaying, let anim = ladyAnim, currentTime >= ladyDeadline {
            if ladyFrame + 1 < anim.frames.count {
                ladyFrame += 1
                showFrame(of: anim, index: ladyFrame, on: ladyNode, offset: .zero)
                ladyDeadline = currentTime + TimeInterval(anim.frames[ladyFrame].delayMs) / 1000
            } else {
                ladyPlaying = false
                ladyFrame = 0
                showFrame(of: anim, index: 0, on: ladyNode, offset: .zero)
            }
        }

        // Вождь: качает воздух (однократно при подготовке, циклично при мелодии)
        if pumperPlaying, let anim = pumperAnim, currentTime >= pumperDeadline {
            if pumperFrame + 1 < anim.frames.count {
                pumperFrame += 1
            } else if pumperLooping {
                pumperFrame = 0
            } else {
                pumperPlaying = false
                pumperFrame = 0
                tryStartMelody(at: currentTime)
            }
            showFrame(of: anim, index: pumperFrame, on: pumperNode, offset: .zero)
            pumperDeadline = currentTime + TimeInterval(anim.frames[pumperFrame].delayMs) / 1000
        }

        // Мелодия по расписанию
        if let start = melodyStart {
            while melodyIndex < melodySchedule.count,
                  currentTime - start >= melodySchedule[melodyIndex].at {
                soundPlayer?(noteSounds[melodySchedule[melodyIndex].note])
                melodyIndex += 1
            }
            if currentTime >= melodyEndsAt {
                melodyFinished()
            }
        }
    }
}
