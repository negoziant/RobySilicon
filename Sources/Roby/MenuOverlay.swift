import SpriteKit
import ResourceKit

/// Меню «Опции» из OPTIONS.DAT: фон OPTIONS.NGB, подсветка кнопок OPTS0-4
/// (их NGB-заголовки задают точные позиции кнопок на экране 640×480).
/// Три ползунка (Звук/Музыка/Скорость): дорожки нарисованы на фоне на
/// y=293/353/414 (сняты с OPTIONS.NGB), бегунок OPTS5 29×29, ход x=225..419.
final class MenuOverlay: SKNode {
    var onNewGame: (() -> Void)?
    var onContinue: (() -> Void)?
    var onLoad: (() -> Void)?
    var onSave: (() -> Void)?
    var onQuit: (() -> Void)?
    /// (индекс 0=звук/1=музыка/2=скорость, значение 0..1)
    var onSliderChanged: ((Int, Float) -> Void)?
    var onSliderTick: (() -> Void)?

    private let screenH: CGFloat = 480
    // Rect'ы кнопок в координатах сцены (y вверх), индекс = OPTS номер
    private var buttonRects: [CGRect] = []
    private var highlightNodes: [SKSpriteNode?] = []

    // Ползунки: экранные (y вниз) дорожки; бегунок ходит x 225..419 (лево)
    private let sliderTopY: [CGFloat] = [294, 354, 415]
    private let sliderMinX: CGFloat = 225
    private let sliderMaxX: CGFloat = 419
    private var sliderKnobs: [SKSpriteNode?] = [nil, nil, nil]
    private var sliderValues: [Float] = [0.5, 0.5, 0.5]
    private var draggingSlider: Int?

    init(loader: ResourceLoader) {
        super.init()
        do {
            let datPath = "\(loader.gameDataPath)/OPTIONS.DAT"
            let container = try NLContainer(path: datPath)
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name }) else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("OPTIONS.COL"),
                  let bgData = try resource("OPTIONS.NGB") else { return }
            let palette = try COLPalette(data: colData)
            let bgNgb = try NGBImage(data: bgData)

            if let bgImage = PNGRenderer.render(ngb: bgNgb, palette: palette, transparentIndex: nil) {
                let tex = SKTexture(cgImage: bgImage)
                tex.filteringMode = .nearest
                let bg = SKSpriteNode(texture: tex)
                bg.anchorPoint = CGPoint(x: 0, y: 0)
                bg.position = .zero
                addChild(bg)
            }

            // OPTS5 — бегунок ползунка (29×29): три экземпляра
            sliderValues = [GameSettings.effectsVolume, GameSettings.musicVolume,
                            GameSettings.gameSpeed]
            if let d = try resource("OPTS5.NGB") {
                let ngb = try NGBImage(data: d)
                if let img = PNGRenderer.render(ngb: ngb, palette: palette, transparentIndex: 0) {
                    let tex = SKTexture(cgImage: img)
                    tex.filteringMode = .nearest
                    for i in 0..<3 {
                        let knob = SKSpriteNode(texture: tex)
                        knob.anchorPoint = CGPoint(x: 0, y: 1)
                        knob.size = tex.size()
                        knob.zPosition = 2
                        addChild(knob)
                        sliderKnobs[i] = knob
                        positionKnob(i)
                    }
                }
            }

            // OPTS0-4 — подсвеченные кнопки; их NGB rect = позиция кнопки
            for i in 0...4 {
                guard let d = try resource("OPTS\(i).NGB") else {
                    buttonRects.append(.zero)
                    highlightNodes.append(nil)
                    continue
                }
                let ngb = try NGBImage(data: d)
                let rect = CGRect(x: CGFloat(ngb.xLeft),
                                  y: screenH - CGFloat(ngb.yBottom) - 1,
                                  width: CGFloat(ngb.width),
                                  height: CGFloat(ngb.height))
                buttonRects.append(rect)
                if let img = PNGRenderer.render(ngb: ngb, palette: palette, transparentIndex: 0) {
                    let tex = SKTexture(cgImage: img)
                    tex.filteringMode = .nearest
                    let node = SKSpriteNode(texture: tex)
                    node.anchorPoint = CGPoint(x: 0, y: 0)
                    node.position = rect.origin
                    node.zPosition = 1
                    node.isHidden = true
                    addChild(node)
                    highlightNodes.append(node)
                } else {
                    highlightNodes.append(nil)
                }
            }
        } catch {
            fputs("[Menu] ошибка загрузки OPTIONS.DAT: \(error)\n", stderr)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buttonIndex(at point: CGPoint) -> Int? {
        for (i, rect) in buttonRects.enumerated() where rect.contains(point) {
            return i
        }
        return nil
    }

    func handleHover(at point: CGPoint) {
        let hit = buttonIndex(at: point)
        for (i, node) in highlightNodes.enumerated() {
            node?.isHidden = (i != hit)
        }
    }

    func handleClick(at point: CGPoint) {
        if let slider = sliderIndex(at: point) {
            draggingSlider = slider
            dragSlider(to: point)
            return
        }
        switch buttonIndex(at: point) {
        case 0: onNewGame?()
        case 1: onContinue?()
        case 2: onLoad?()
        case 3: onSave?()
        case 4: onQuit?()
        default: break
        }
    }

    // MARK: - Ползунки

    private func positionKnob(_ i: Int) {
        let x = sliderMinX + (sliderMaxX - sliderMinX) * CGFloat(sliderValues[i])
        sliderKnobs[i]?.position = CGPoint(x: x, y: screenH - sliderTopY[i])
    }

    private func sliderIndex(at point: CGPoint) -> Int? {
        let y = screenH - point.y // экранная (вниз)
        for i in 0..<3 {
            if point.x >= sliderMinX - 10, point.x <= sliderMaxX + 39,
               y >= sliderTopY[i] - 2, y <= sliderTopY[i] + 31 {
                return i
            }
        }
        return nil
    }

    func handleDrag(at point: CGPoint) {
        guard draggingSlider != nil else { return }
        dragSlider(to: point)
    }

    func handleMouseUp() {
        draggingSlider = nil
    }

    private func dragSlider(to point: CGPoint) {
        guard let i = draggingSlider else { return }
        // центр бегунка под курсором
        let x = max(sliderMinX, min(sliderMaxX, point.x - 14.5))
        let value = Float((x - sliderMinX) / (sliderMaxX - sliderMinX))
        guard abs(value - sliderValues[i]) > 0.001 else { return }
        sliderValues[i] = value
        positionKnob(i)
        onSliderTick?()
        onSliderChanged?(i, value)
    }
}
