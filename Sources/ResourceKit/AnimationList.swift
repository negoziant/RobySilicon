import Foundation

public struct AnimationList {
    public let pattern: String
    public let entries: [String]

    public init(data: Data) {
        let raw = String(data: data, encoding: .ascii) ?? ""
        let lines = raw.components(separatedBy: "\r\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            self.pattern = ""
            self.entries = []
        } else {
            self.pattern = lines[0]
            self.entries = Array(lines.dropFirst())
        }
    }
}
