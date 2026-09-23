import SpriteKit
import ResourceKit

protocol BarPanelDelegate: AnyObject {
    func barPanel(_ bar: BarPanel, didClickInventoryItem index: Int)
    func barPanel(_ bar: BarPanel, didClickPortrait character: Int)
    func barPanelDidClickMap(_ bar: BarPanel)
    func barPanelDidClickSave(_ bar: BarPanel)
    func barPanelDidScrollInventory(_ bar: BarPanel, direction: Int)
}

final class BarPanel: SKNode {

    weak var delegate: BarPanelDelegate?

    private var barSprites: [Int: CGImage] = [:]
    private var barPalette: COLPalette?

    private let barWidth: CGFloat = 640
    private let barHeight: CGFloat = 80

    // Zone rects relative to the bar (origin bottom-left, y-up)
    private let portraitRect = CGRect(x: 5, y: 8, width: 68, height: 66)
    private let textRect = CGRect(x: 96, y: 10, width: 149, height: 60)
    private let inventoryRect = CGRect(x: 301, y: 10, width: 148, height: 60)
    private let buttonRect1 = CGRect(x: 490, y: 7, width: 68, height: 66)
    private let buttonRect2 = CGRect(x: 565, y: 7, width: 69, height: 66)
    private let scrollLeftRect = CGRect(x: 280, y: 10, width: 20, height: 60)
    private let scrollRightRect = CGRect(x: 450, y: 10, width: 20, height: 60)

    private let inventorySlotWidth: CGFloat = 48
    private let inventorySlotCount = 3

    private var inventoryItems: [Int] = []
    private var inventoryScrollOffset = 0
    private var currentCharacter = 0
    private var bothCharactersAvailable = false
    private var mapAvailable = false
    private var selectedBarIndex: Int? = nil

    private var portraitNode: SKSpriteNode?
    private var itemSlotNodes: [SKSpriteNode] = []
    private var mapButtonNode: SKSpriteNode?
    private var saveButtonNode: SKSpriteNode?
    private var textLabelNode: SKLabelNode?

    func setup(sprites: [Int: CGImage], palette: COLPalette) {
        barSprites = sprites
        barPalette = palette

        setupPortrait()
        setupInventorySlots()
        setupMapButton()
        setupSaveButton()
        setupTextLabel()
    }

    private func setupPortrait() {
        let node = SKSpriteNode()
        node.anchorPoint = CGPoint(x: 0, y: 0)
        node.position = CGPoint(x: portraitRect.minX, y: portraitRect.minY)
        node.zPosition = 10
        addChild(node)
        portraitNode = node
        updatePortrait()
    }

    // BAR3 — один Роби (Пятница недоступен); BAR1/BAR2 — оба, активен Роби/Пятница
    private func updatePortrait() {
        let spriteIdx = bothCharactersAvailable ? (1 + currentCharacter) : 3
        guard let img = barSprites[spriteIdx] else { return }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        portraitNode?.texture = tex
        portraitNode?.size = CGSize(width: CGFloat(img.width), height: CGFloat(img.height))
    }

    func setCharacters(bothAvailable: Bool, active: Int) {
        bothCharactersAvailable = bothAvailable
        currentCharacter = active
        updatePortrait()
    }

    // BAR72 — карта есть, BAR74 — пустая рамка (карта не найдена)
    func setMapAvailable(_ available: Bool) {
        mapAvailable = available
        guard let img = barSprites[available ? 72 : 74] else { return }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        mapButtonNode?.texture = tex
        mapButtonNode?.size = CGSize(width: CGFloat(img.width), height: CGFloat(img.height))
    }

    private func setupInventorySlots() {
        for i in 0..<inventorySlotCount {
            let node = SKSpriteNode()
            node.anchorPoint = CGPoint(x: 0, y: 0)
            let x = inventoryRect.minX + CGFloat(i) * inventorySlotWidth + 2
            node.position = CGPoint(x: x, y: inventoryRect.minY)
            node.zPosition = 10
            addChild(node)
            itemSlotNodes.append(node)
        }
    }

    private func setupMapButton() {
        let node = SKSpriteNode()
        node.anchorPoint = CGPoint(x: 0, y: 0)
        node.position = CGPoint(x: buttonRect1.minX, y: buttonRect1.minY)
        node.zPosition = 10
        addChild(node)
        mapButtonNode = node
        setMapAvailable(false)
    }

    private func setupSaveButton() {
        guard let img = barSprites[75] else { return }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        let node = SKSpriteNode(texture: tex)
        node.anchorPoint = CGPoint(x: 0, y: 0)
        node.position = CGPoint(x: buttonRect2.minX, y: buttonRect2.minY)
        node.zPosition = 10
        addChild(node)
        saveButtonNode = node
    }

    private func setupTextLabel() {
        let label = SKLabelNode(fontNamed: "Helvetica")
        label.fontSize = 11
        label.fontColor = .black
        label.numberOfLines = 4
        label.preferredMaxLayoutWidth = textRect.width - 8
        label.verticalAlignmentMode = .top
        label.horizontalAlignmentMode = .left
        label.position = CGPoint(x: textRect.minX + 4, y: textRect.maxY - 4)
        label.zPosition = 10
        addChild(label)
        textLabelNode = label
    }

    func setText(_ text: String) {
        textLabelNode?.text = text
    }

    func setInventory(_ items: [Int]) {
        inventoryItems = items
        inventoryScrollOffset = 0
        updateInventoryDisplay()
    }

    func scrollInventory(by delta: Int) {
        let maxOffset = max(0, inventoryItems.count - inventorySlotCount)
        inventoryScrollOffset = max(0, min(inventoryScrollOffset + delta, maxOffset))
        updateInventoryDisplay()
    }

    private func updateInventoryDisplay() {
        for (i, node) in itemSlotNodes.enumerated() {
            let itemIdx = inventoryScrollOffset + i
            if itemIdx < inventoryItems.count {
                let isSelected = (selectedBarIndex == inventoryItems[itemIdx])
                let barSpriteIdx = 6 + inventoryItems[itemIdx] * 2 + (isSelected ? 1 : 0)
                if let img = barSprites[barSpriteIdx] {
                    let tex = SKTexture(cgImage: img)
                    tex.filteringMode = .nearest
                    node.texture = tex
                    node.size = CGSize(width: CGFloat(img.width), height: CGFloat(img.height))
                    node.isHidden = false
                } else {
                    node.isHidden = true
                }
            } else {
                node.isHidden = true
            }
        }
    }

    func handleClick(at point: CGPoint) {
        if portraitRect.contains(point) {
            guard bothCharactersAvailable else { return }
            let next = (currentCharacter + 1) % 2
            delegate?.barPanel(self, didClickPortrait: next)
        } else if scrollLeftRect.contains(point) {
            scrollInventory(by: -1)
            delegate?.barPanelDidScrollInventory(self, direction: -1)
        } else if scrollRightRect.contains(point) {
            scrollInventory(by: 1)
            delegate?.barPanelDidScrollInventory(self, direction: 1)
        } else if inventoryRect.contains(point) {
            let slotX = point.x - inventoryRect.minX
            let slot = Int(slotX / inventorySlotWidth)
            let itemIdx = inventoryScrollOffset + slot
            if itemIdx < inventoryItems.count {
                let barIdx = inventoryItems[itemIdx]
                if selectedBarIndex == barIdx {
                    selectItem(nil)
                } else {
                    selectItem(barIdx)
                }
                delegate?.barPanel(self, didClickInventoryItem: barIdx)
            }
        } else if buttonRect1.contains(point) {
            guard mapAvailable else { return }
            delegate?.barPanelDidClickMap(self)
        } else if buttonRect2.contains(point) {
            delegate?.barPanelDidClickSave(self)
        }
    }

    func selectItem(_ barIndex: Int?) {
        selectedBarIndex = barIndex
        updateInventoryDisplay()
    }
}
