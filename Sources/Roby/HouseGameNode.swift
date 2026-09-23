import SpriteKit
import ResourceKit

/// Мини-игра №1 «Строительство дома» (HOUSE.DAT + логика из MiniGame.dll).
/// Реверс: детали H1..H17 (4 поворота), целевые позиции — таблица @0x10029f10,
/// правильная ориентация — вариант 1 (индекс 0); допуск укладки |dx|≤20,
/// бросать выше цели (≤280px) — деталь «падает» на место; очерёдность — DAG
/// (снизу вверх, jump table @0x1000a974); неудача — деталь падает в кучу.
final class HouseGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480

    // Реверс MiniGame.dll: целевые позиции (левый-верх, NGB-координаты, y вниз)
    private static let targets: [(x: Int, y: Int)] = [
        (150, 61), (129, 97), (77, 138), (45, 185), (186, 182), (41, 231),
        (174, 222), (257, 210), (38, 257), (39, 285), (80, 289), (40, 328),
        (41, 379), (272, 348), (273, 285), (11, 22), (175, 50),
    ]
    // Зависимости укладки: деталь i кладётся только после этих (0-based)
    private static let deps: [[Int]] = [
        [1], [2], [3, 4], [5, 6], [6, 7], [8], [8], [14],
        [9, 10], [11], [11, 9], [12], [], [12], [13], [0], [0],
    ]
    private let saveButtonRect = CGRect(x: 556, y: 6, width: 78, height: 72) // дискета (y вверх)

    private final class Piece {
        let index: Int
        var textures: [SKTexture] = []
        var sizes: [CGSize] = []
        var variant = 0
        var placed = false
        let node: SKSpriteNode
        init(index: Int, node: SKSpriteNode) {
            self.index = index
            self.node = node
        }
    }

    private var pieces: [Piece] = []
    private var dragging: Piece?
    private var dragOffset: CGPoint = .zero
    private var finished = false
    private var placedCount = 0

    init(gameDataPath: String) {
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../HOUSE.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name }) else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("PALETTE.COL") else { return }
            let pal = try COLPalette(data: colData)

            if let bgData = try resource("BACK.NGB"),
               let bg = MiniGameArt.decodeNGB(bgData, palette: pal, transparent: false) {
                let tex = SKTexture(cgImage: bg.image)
                tex.filteringMode = .nearest
                let bgNode = SKSpriteNode(texture: tex)
                bgNode.anchorPoint = CGPoint(x: 0, y: 0)
                bgNode.position = .zero
                addChild(bgNode)
            }

            for i in 0..<17 {
                let node = SKSpriteNode()
                node.anchorPoint = CGPoint(x: 0, y: 1) // левый-верх как в NGB
                node.zPosition = 10
                let piece = Piece(index: i, node: node)
                for v in 1...4 {
                    guard let d = try resource("H\(i + 1)\(v).NGB"),
                          let img = MiniGameArt.decodeNGB(d, palette: pal, transparent: true) else { continue }
                    let tex = SKTexture(cgImage: img.image)
                    tex.filteringMode = .nearest
                    piece.textures.append(tex)
                    piece.sizes.append(CGSize(width: img.width, height: img.height))
                }
                guard piece.textures.count == 4 else { continue }
                // старт: случайная ориентация, куча внизу экрана
                piece.variant = Int.random(in: 0..<4)
                applyTexture(piece)
                let w = piece.sizes[piece.variant].width
                node.position = CGPoint(x: CGFloat.random(in: 20...(620 - w)),
                                        y: CGFloat.random(in: 10...70) + piece.sizes[piece.variant].height)
                addChild(node)
                pieces.append(piece)
            }
        } catch {
            fputs("[House] ошибка загрузки: \(error)\n", stderr)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTexture(_ p: Piece) {
        p.node.texture = p.textures[p.variant]
        p.node.size = p.sizes[p.variant]
    }

    // MARK: - Ввод (точки в локальных координатах ноды, y вверх)

    private func piece(at point: CGPoint) -> Piece? {
        for p in pieces.reversed() where !p.placed {
            let sz = p.sizes[p.variant]
            let rect = CGRect(x: p.node.position.x, y: p.node.position.y - sz.height,
                              width: sz.width, height: sz.height)
            if rect.contains(point) { return p }
        }
        return nil
    }

    func handleMouseDown(at point: CGPoint) {
        guard !finished else { return }
        if saveButtonRect.contains(point) {
            finish()
            return
        }
        if let p = piece(at: point) {
            dragging = p
            dragOffset = CGPoint(x: point.x - p.node.position.x, y: point.y - p.node.position.y)
            p.node.zPosition = 50
            soundPlayer?("h_take.wav")
        }
    }

    func handleMouseDragged(to point: CGPoint) {
        guard let p = dragging else { return }
        p.node.position = CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
    }

    func handleRightMouseDown(at point: CGPoint) {
        guard !finished else { return }
        let target = dragging ?? piece(at: point)
        guard let p = target else { return }
        p.variant = (p.variant + 1) % 4
        applyTexture(p)
        soundPlayer?("h_turn.wav")
    }

    func handleMouseUp(at point: CGPoint) {
        guard let p = dragging else { return }
        dragging = nil
        p.node.zPosition = 10
        tryPlace(p)
    }

    private func tryPlace(_ p: Piece) {
        let t = Self.targets[p.index]
        let sz = p.sizes[0]
        // центры в NGB-координатах (y вниз)
        let targetCX = CGFloat(t.x) + sz.width / 2
        let targetCY = CGFloat(t.y) + sz.height / 2
        let curSz = p.sizes[p.variant]
        let curCX = p.node.position.x + curSz.width / 2
        let curCY = (screenH - p.node.position.y) + curSz.height / 2

        let depsOK = Self.deps[p.index].allSatisfy { pieces[$0].placed }
        let fits = p.variant == 0
            && abs(curCX - targetCX) <= 20
            && curCY <= targetCY
            && targetCY - curCY <= 280

        if depsOK && fits {
            p.placed = true
            placedCount += 1
            // уложенные — часть дома: под свободными деталями, в порядке укладки
            p.node.zPosition = 1 + CGFloat(placedCount) * 0.01
            let dest = CGPoint(x: CGFloat(t.x), y: screenH - CGFloat(t.y))
            p.node.run(.sequence([
                .move(to: dest, duration: 0.25),
                .run { [weak self] in
                    self?.soundPlayer?("h_good.wav")
                    self?.checkCompletion()
                },
            ]))
        } else if curCX < 420 && curCY < 400 {
            // Неудачная попытка вставить в зону дома: звук ошибки, деталь
            // падает в кучу (в оригинале y := 400 + rand(50)); вне зоны дома
            // деталь просто остаётся, где положили (PtInRect в обработчике)
            soundPlayer?("h_error.wav")
            let dropY = CGFloat(Int.random(in: 0...50)) + (screenH - 400 - 60)
            let dest = CGPoint(x: max(4, min(p.node.position.x, 640 - curSz.width - 4)),
                               y: dropY + curSz.height)
            p.node.run(.move(to: dest, duration: 0.3))
        }
    }

    private func checkCompletion() {
        guard pieces.allSatisfy({ $0.placed }) else { return }
        finished = true
        soundPlayer?("final1.wav")
        run(.sequence([.wait(forDuration: 2.5), .run { [weak self] in self?.finish() }]))
    }

    private func finish() {
        let success = pieces.allSatisfy { $0.placed }
        onFinish?(success)
    }
}
