import Foundation

public struct FADTable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count >= 4096 else {
            throw FADError.dataTooShort(data.count)
        }
        self.data = data.prefix(4096)
    }

    public func fadedIndex(_ paletteIndex: UInt8, level: Int) -> UInt8 {
        let lvl = max(0, min(level, 15))
        return data[data.startIndex + lvl * 256 + Int(paletteIndex)]
    }
}

public enum FADError: Error, CustomStringConvertible {
    case dataTooShort(Int)

    public var description: String {
        switch self {
        case .dataTooShort(let n): return "FAD data too short: \(n) bytes (need 4096)"
        }
    }
}
