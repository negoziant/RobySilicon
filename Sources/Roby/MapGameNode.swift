import SpriteKit
import ResourceKit

/// Мини-игра №0 «Карта» (MAP.DAT + MiniGame.dll). Реверс: 12 кусков с 4
/// поворотами; идеальная раскладка — таблица @0x1002a250 (проверка укладки
/// ОТНОСИТЕЛЬНАЯ: разность позиций двух кусков должна совпасть с табличной,
/// собирать можно в любом месте стола); успех = выложены все 12 (cmp 0xc).
/// Доступны только найденные куски (MapParts).
final class MapGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480
    private static let layout: [(x: Int, y: Int)] = [
        (111, 121), (255, 79), (163, 0), (231, 0), (141, 182), (221, 161),
        (164, 283), (275, 243), (0, 167), (77, 185), (0, 0), (10, 0),
    ]
    private let saveButtonRect = CGRect(x: 556, y: 6, width: 78, height: 72)
    private let snapTolerance: CGFloat = 18

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

    init(gameDataPath: String, availableParts: Int) {
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../MAP.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name }) else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("PALETTE.COL") else { return }
            let pal = try COLPalette(data: colData)

            if let bgData = try resource("DESK.NGB"),
               let bg = MiniGameArt.decodeNGB(bgData, palette: pal, transparent: false) {
                let tex = SKTexture(cgImage: bg.image)
                tex.filteringMode = .nearest
                let bgNode = SKSpriteNode(texture: tex)
                bgNode.anchorPoint = CGPoint(x: 0, y: 0)
                addChild(bgNode)
            }

            let count = max(1, min(availableParts, 12))
            for i in 0..<count {
                let node = SKSpriteNode()
                node.anchorPoint = CGPoint(x: 0, y: 1)
                node.zPosition = 10
                let piece = Piece(index: i, node: node)
                for v in 1...4 {
                    guard let d = try resource("M\(i + 1)\(v).NGB"),
                          let img = MiniGameArt.decodeNGB(d, palette: pal, transparent: true) else { continue }
                    let tex = SKTexture(cgImage: img.image)
                    tex.filteringMode = .nearest
                    piece.textures.append(tex)
                    piece.sizes.append(CGSize(width: img.width, height: img.height))
                }
                guard piece.textures.count == 4 else { continue }
                piece.variant = Int.random(in: 0..<4)
                applyTexture(piece)
                let sz = piece.sizes[piece.variant]
                node.position = CGPoint(x: CGFloat.random(in: 20...(600 - sz.width)),
                                        y: CGFloat.random(in: 60...(400 - sz.height)) + sz.height)
                addChild(node)
                pieces.append(piece)
            }
        } catch {
            fputs("[Map] ошибка загрузки: \(error)\n", stderr)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTexture(_ p: Piece) {
        p.node.texture = p.textures[p.variant]
        p.node.size = p.sizes[p.variant]
    }

    private func piece(at point: CGPoint) -> Piece? {
        // выложенный кусок можно взять обратно
        for p in pieces.reversed() {
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
            if p.placed {
                p.placed = false
            }
            dragOffset = CGPoint(x: point.x - p.node.position.x, y: point.y - p.node.position.y)
            p.node.zPosition = 50
            soundPlayer?("m_take.wav")
        }
    }

    func handleMouseDragged(to point: CGPoint) {
        guard let p = dragging else { return }
        p.node.position = CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
    }

    func handleRightMouseDown(at point: CGPoint) {
        guard !finished else { return }
        let target = dragging ?? piece(at: point)
        guard let p = target, !p.placed else { return }
        p.variant = (p.variant + 1) % 4
        applyTexture(p)
        soundPlayer?("m_turn.wav")
    }

    func handleMouseUp(at point: CGPoint) {
        guard let p = dragging else { return }
        dragging = nil
        p.node.zPosition = 10
        tryPlace(p)
    }

    private func tryPlace(_ p: Piece) {
        guard p.variant == 0 else { return } // неверный поворот не стыкуется

        let placedOnes = pieces.filter { $0.placed && $0.index != p.index }
        if placedOnes.isEmpty {
            // первый кусок кладётся свободно (внутри стола)
            if p.node.position.x > 130 && p.node.position.x < 560 {
                p.placed = true
                p.node.zPosition = 5
                soundPlayer?("m_put.wav")
                checkCompletion()
            }
            return
        }

        let myTarget = Self.layout[p.index]
        for other in placedOnes {
            let otherTarget = Self.layout[other.index]
            let expected = CGPoint(
                x: other.node.position.x + CGFloat(myTarget.x - otherTarget.x),
                y: other.node.position.y - CGFloat(myTarget.y - otherTarget.y))
            if abs(p.node.position.x - expected.x) <= snapTolerance,
               abs(p.node.position.y - expected.y) <= snapTolerance {
                p.node.position = expected
                p.placed = true
                p.node.zPosition = 5
                soundPlayer?("m_put.wav")
                checkCompletion()
                return
            }
        }
    }

    private func checkCompletion() {
        guard pieces.count == 12, pieces.allSatisfy({ $0.placed }) else { return }
        finished = true
        soundPlayer?("m_good.wav")
        run(.sequence([
            .wait(forDuration: 0.6),
            .run { [weak self] in self?.soundPlayer?("final0.wav") },
            .wait(forDuration: 2.0),
            .run { [weak self] in self?.finish() },
        ]))
    }

    private func finish() {
        let success = pieces.count == 12 && pieces.allSatisfy { $0.placed }
        onFinish?(success)
    }
}
