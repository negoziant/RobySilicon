import Foundation

/// BAR.BAR из BAR.DAN — конфигурация инвентарной панели.
/// Порядок Items канонический: предмет i → спрайты BAR(6+i*2)/BAR(7+i*2).
public struct BarConfig {
    public struct Item {
        public let name: String
        public let title: String // русское название (CP1251)
    }

    public let items: [Item]
    public let itemWidth: Int
    public let itemHeight: Int
    public let itemsDisplayed: Int
    public let textDelayMs: Int

    public var itemIndex: [String: Int] {
        var map: [String: Int] = [:]
        for (i, item) in items.enumerated() { map[item.name.lowercased()] = i }
        return map
    }

    public init(data: Data) {
        let raw = String(data: data, encoding: .windowsCP1251) ?? ""
        let lines = raw.components(separatedBy: "\r\n")

        var items: [Item] = []
        var itemWidth = 48, itemHeight = 60
        var itemsDisplayed = 3
        var textDelayMs = 5000
        var currentSection = ""

        func parseItem(_ s: String) {
            var clean = s.trimmingCharacters(in: .whitespaces)
            if clean.hasSuffix(";") { clean = String(clean.dropLast()) }
            guard !clean.isEmpty else { return }
            let parts = clean.split(separator: ",", maxSplits: 1).map { String($0) }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            var title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !name.isEmpty else { return }
            items.append(Item(name: name, title: title))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "End;" { continue }

            let isKeywordLine = !(line.first?.isWhitespace ?? true)
            if isKeywordLine {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: true).map { String($0) }
                let keyword = parts.first ?? ""
                let value = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
                currentSection = keyword
                switch keyword {
                case "Items":
                    parseItem(value)
                case "ItemWH":
                    let wh = value.replacingOccurrences(of: ";", with: "").split(separator: ",")
                    if wh.count >= 2 {
                        itemWidth = Int(wh[0].trimmingCharacters(in: .whitespaces)) ?? itemWidth
                        itemHeight = Int(wh[1].trimmingCharacters(in: .whitespaces)) ?? itemHeight
                    }
                case "ItemsDisplayed":
                    itemsDisplayed = Int(value.replacingOccurrences(of: ";", with: "")
                        .trimmingCharacters(in: .whitespaces)) ?? itemsDisplayed
                case "TextDelay":
                    textDelayMs = Int(value.replacingOccurrences(of: ";", with: "")
                        .trimmingCharacters(in: .whitespaces)) ?? textDelayMs
                default:
                    break
                }
            } else if currentSection == "Items" {
                parseItem(trimmed)
            }
        }

        self.items = items
        self.itemWidth = itemWidth
        self.itemHeight = itemHeight
        self.itemsDisplayed = itemsDisplayed
        self.textDelayMs = textDelayMs
    }
}
