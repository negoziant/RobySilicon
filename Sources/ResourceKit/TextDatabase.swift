import Foundation

public struct TextDatabase {
    public let strings: [String]

    public init(data: Data) {
        let raw = String(data: data, encoding: .windowsCP1251) ?? String(data: data, encoding: .ascii) ?? ""
        var result: [String] = []
        for line in raw.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
                let inner = String(trimmed.dropFirst().dropLast())
                result.append(inner)
            }
        }
        self.strings = result
    }

    public subscript(index: Int) -> String? {
        guard index >= 0, index < strings.count else { return nil }
        return strings[index]
    }
}
