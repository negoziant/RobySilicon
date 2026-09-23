import SpriteKit
import ResourceKit

/// Мини-игра №5 «Криптограмма» (CRYPT.DAT). CRYPT.TXT: строка 1 — алфавит из
/// 30 букв (Find6=30!), дальше — текст письма Пятницы (до «~»). Глифы C1-30 ↔
/// буквы R1-30 (по индексу в алфавите), S1-5 — пунктуация «,.-!?».
/// Перетащи букву с панели на глиф: верно — заменяются все вхождения (r_put),
/// неверно — r_error. Ластик — сброс. Всё переведено → r_all + final5.
final class CryptGameNode: SKNode, MiniGameNodeProtocol {
    var onFinish: ((Bool) -> Void)?
    var soundPlayer: ((String) -> Void)?

    private let screenH: CGFloat = 480
    private let eraseRect = CGRect(x: 0, y: 2, width: 82, height: 80)
    private let exitRect = CGRect(x: 556, y: 6, width: 80, height: 72)

    private var alphabet: [Character] = []
    private var glyphTextures: [SKTexture] = []   // C1-30
    private var letterTextures: [SKTexture] = []  // R1-30

    private final class Cell {
        let letterIndex: Int // индекс буквы в алфавите
        var solved = false
        let node: SKSpriteNode
        init(letterIndex: Int, node: SKSpriteNode) {
            self.letterIndex = letterIndex
            self.node = node
        }
    }

    private final class PanelLetter {
        let letterIndex: Int
        let node: SKSpriteNode
        let home: CGPoint
        init(letterIndex: Int, node: SKSpriteNode, home: CGPoint) {
            self.letterIndex = letterIndex
            self.node = node
            self.home = home
        }
    }

    private var cells: [Cell] = []
    private var panel: [PanelLetter] = []
    private var dragging: PanelLetter?
    private var finished = false

    init(gameDataPath: String) {
        super.init()
        do {
            let container = try NLContainer(path: gameDataPath + "/../CRYPT.DAT")
            let decompressor = NGIDecompressor()

            func resource(_ name: String) throws -> Data? {
                guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name }) else { return nil }
                return try container.extractResource(at: idx, decompressor: decompressor)
            }

            guard let colData = try resource("PALETTE.COL") else { return }
            let pal = try COLPalette(data: colData)

            if let bgData = try resource("CRYPT.NGB"),
               let bg = MiniGameArt.decodeNGB(bgData, palette: pal, transparent: false) {
                let tex = SKTexture(cgImage: bg.image)
                tex.filteringMode = .nearest
                let bgNode = SKSpriteNode(texture: tex)
                bgNode.anchorPoint = CGPoint(x: 0, y: 0)
                addChild(bgNode)
            }

            func textures(_ prefix: String, _ count: Int) throws -> [SKTexture] {
                var out: [SKTexture] = []
                for i in 1...count {
                    guard let d = try resource("\(prefix)\(i).NGB"),
                          let img = MiniGameArt.decodeNGB(d, palette: pal, transparent: true) else { break }
                    let tex = SKTexture(cgImage: img.image)
                    tex.filteringMode = .nearest
                    out.append(tex)
                }
                return out
            }
            glyphTextures = try textures("C", 30)
            letterTextures = try textures("R", 30)
            let punctTextures = try textures("S", 5)

            guard let txtData = try resource("CRYPT.TXT"),
                  let raw = String(data: txtData, encoding: .windowsCP1251) else { return }
            let lines = raw.components(separatedBy: "\r\n")
            guard lines.count > 2 else { return }
            alphabet = Array(lines[0])
            let message = lines[2...].joined(separator: " ")
                .replacingOccurrences(of: "~", with: "")
                .trimmingCharacters(in: .whitespaces)

            layoutMessage(message, punct: punctTextures)
            layoutPanel()
        } catch {
            fputs("[Crypt] ошибка загрузки: \(error)\n", stderr)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func letterIndex(of ch: Character) -> Int? {
        let lower = Character(ch.lowercased())
        return alphabet.firstIndex(of: lower)
    }

    private func layoutMessage(_ message: String, punct: [SKTexture]) {
        // перенос по словам, ~26 знаков в строке, глиф 21px
        let punctMap: [Character: Int] = [",": 0, ".": 1, "-": 2, "!": 3, "?": 4]
        var rows: [[Character]] = [[]]
        for word in message.split(separator: " ") {
            if rows[rows.count - 1].count + word.count + 1 > 26 {
                rows.append([])
            }
            if !rows[rows.count - 1].isEmpty { rows[rows.count - 1].append(" ") }
            rows[rows.count - 1].append(contentsOf: word)
        }

        let step: CGFloat = 21
        let lineH: CGFloat = 30
        let topY: CGFloat = 46
        for (r, row) in rows.enumerated() {
            let width = CGFloat(row.count) * step
            var x = (640 - width) / 2
            let y = screenH - topY - CGFloat(r) * lineH
            for ch in row {
                defer { x += step }
                if ch == " " { continue }
                if let li = letterIndex(of: ch), li < glyphTextures.count {
                    let node = SKSpriteNode(texture: glyphTextures[li])
                    node.anchorPoint = CGPoint(x: 0, y: 1)
                    node.size = glyphTextures[li].size()
                    node.position = CGPoint(x: x, y: y)
                    node.zPosition = 5
                    addChild(node)
                    cells.append(Cell(letterIndex: li, node: node))
                } else if let pi = punctMap[ch], pi < punct.count {
                    let node = SKSpriteNode(texture: punct[pi])
                    node.anchorPoint = CGPoint(x: 0, y: 1)
                    node.size = punct[pi].size()
                    node.position = CGPoint(x: x, y: y)
                    node.zPosition = 5
                    addChild(node)
                }
            }
        }
    }

    private func layoutPanel() {
        // алфавит в два ряда по 15 внизу, между ластиком и дискетой
        let step: CGFloat = 30
        for i in 0..<min(30, letterTextures.count) {
            let row = i / 15
            let colIdx = i % 15
            let x = 105 + CGFloat(colIdx) * step
            let y: CGFloat = 74 - CGFloat(row) * 34
            let node = SKSpriteNode(texture: letterTextures[i])
            node.anchorPoint = CGPoint(x: 0, y: 1)
            node.size = letterTextures[i].size()
            node.position = CGPoint(x: x, y: y)
            node.zPosition = 10
            addChild(node)
            panel.append(PanelLetter(letterIndex: i, node: node, home: node.position))
        }
    }

    // MARK: - Ввод

    func handleMouseDown(at point: CGPoint) {
        guard !finished else { return }
        if exitRect.contains(point) {
            finish()
            return
        }
        if eraseRect.contains(point) {
            eraseAll()
            return
        }
        for l in panel.reversed() {
            let sz = l.node.size
            let rect = CGRect(x: l.node.position.x - 4, y: l.node.position.y - sz.height - 4,
                              width: sz.width + 8, height: sz.height + 8)
            if rect.contains(point) {
                dragging = l
                l.node.zPosition = 50
                soundPlayer?("r_take.wav")
                return
            }
        }
    }

    func handleMouseDragged(to point: CGPoint) {
        guard let l = dragging else { return }
        l.node.position = CGPoint(x: point.x - l.node.size.width / 2,
                                  y: point.y + l.node.size.height / 2)
    }

    func handleRightMouseDown(at point: CGPoint) {}

    func handleMouseUp(at point: CGPoint) {
        guard let l = dragging else { return }
        dragging = nil
        l.node.zPosition = 10
        defer {
            l.node.position = l.home // буква возвращается на панель
        }
        // на какой глиф уронили?
        for cell in cells where !cell.solved {
            let sz = cell.node.size
            let rect = CGRect(x: cell.node.position.x - 6, y: cell.node.position.y - sz.height - 6,
                              width: sz.width + 12, height: sz.height + 12)
            guard rect.contains(point) else { continue }
            if cell.letterIndex == l.letterIndex {
                // верно: открываются все вхождения этой буквы
                for c in cells where c.letterIndex == l.letterIndex && !c.solved {
                    c.solved = true
                    c.node.texture = letterTextures[c.letterIndex]
                    c.node.size = letterTextures[c.letterIndex].size()
                }
                soundPlayer?("r_put.wav")
                checkCompletion()
            } else {
                soundPlayer?("r_error.wav")
            }
            return
        }
    }

    private func eraseAll() {
        guard cells.contains(where: { $0.solved }) else { return }
        for c in cells where c.solved {
            c.solved = false
            c.node.texture = glyphTextures[c.letterIndex]
            c.node.size = glyphTextures[c.letterIndex].size()
        }
        soundPlayer?("r_back.wav")
    }

    private func checkCompletion() {
        guard cells.allSatisfy({ $0.solved }) else { return }
        finished = true
        soundPlayer?("r_all.wav")
        run(.sequence([
            .wait(forDuration: 1.0),
            .run { [weak self] in self?.soundPlayer?("final5.wav") },
            .wait(forDuration: 2.0),
            .run { [weak self] in self?.finish() },
        ]))
    }

    private func finish() {
        onFinish?(cells.allSatisfy { $0.solved })
    }
}
