import SpriteKit
import ResourceKit

/// Экраны сохранения/загрузки из OPTIONS.DAT (SAVE.NGB/LOAD.NGB):
/// 12 слотов сеткой 4×3, в слоте — превью-скриншот сейва, внизу кнопка отмены.
final class SaveLoadOverlay: SKNode {
    enum Mode { case save, load }

    struct SlotInfo {
        let exists: Bool
        let label: String
        let thumbnail: CGImage?
    }

    var onSlot: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    private let screenH: CGFloat = 480
    private var slotRects: [CGRect] = [] // координаты сцены (y вверх)
    private let cancelRect = CGRect(x: 362, y: 480 - 471, width: 240, height: 36)
    private let okRect = CGRect(x: 41, y: 480 - 471, width: 239, height: 36)

    init(loader: ResourceLoader, mode: Mode, slots: [SlotInfo]) {
        super.init()
        do {
            let container = try NLContainer(path: loader.gameDataPath + "/OPTIONS.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name }) else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            let bgName = mode == .save ? "SAVE.NGB" : "LOAD.NGB"
            let colName = mode == .save ? "SAVE.COL" : "LOAD.COL"
            if let colData = try resource(colName),
               let bgData = try resource(bgName) {
                let palette = try COLPalette(data: colData)
                let ngb = try NGBImage(data: bgData)
                if let img = PNGRenderer.render(ngb: ngb, palette: palette, transparentIndex: nil) {
                    let tex = SKTexture(cgImage: img)
                    tex.filteringMode = .nearest
                    let bg = SKSpriteNode(texture: tex)
                    bg.anchorPoint = CGPoint(x: 0, y: 0)
                    addChild(bg)
                }
            }
        } catch {
            fputs("[SaveLoad] ошибка загрузки OPTIONS.DAT: \(error)\n", stderr)
        }

        // Сетка слотов 4×3 (по разметке SAVE.NGB)
        for row in 0..<3 {
            for col in 0..<4 {
                let ngbX = 10 + col * 160
                let ngbY = 44 + row * 132
                let rect = CGRect(x: CGFloat(ngbX), y: screenH - CGFloat(ngbY) - 106,
                                  width: 144, height: 106)
                slotRects.append(rect)
                let index = row * 4 + col
                guard index < slots.count else { continue }
                let info = slots[index]

                if let thumb = info.thumbnail {
                    let tex = SKTexture(cgImage: thumb)
                    tex.filteringMode = .linear
                    let node = SKSpriteNode(texture: tex)
                    node.size = CGSize(width: rect.width - 10, height: rect.height - 12)
                    node.position = CGPoint(x: rect.midX, y: rect.midY + 2)
                    node.zPosition = 1
                    addChild(node)
                }

                let label = SKLabelNode(fontNamed: "Helvetica-Bold")
                label.fontSize = 10
                label.fontColor = info.exists ? .black : SKColor(white: 0.25, alpha: 0.8)
                label.text = info.label
                label.horizontalAlignmentMode = .center
                label.verticalAlignmentMode = .bottom
                label.position = CGPoint(x: rect.midX, y: rect.minY + 3)
                label.zPosition = 2
                addChild(label)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func handleClick(at point: CGPoint) {
        for (i, rect) in slotRects.enumerated() where rect.contains(point) {
            onSlot?(i)
            return
        }
        if cancelRect.contains(point) || okRect.contains(point) {
            onCancel?()
        }
    }
}
