import Foundation

public struct COLPalette {
    public let colors: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]

    public init(data: Data) throws {
        guard data.count >= 1024 else {
            throw COLError.dataTooShort(data.count)
        }

        var colors = [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]()
        colors.reserveCapacity(256)

        for i in 0..<256 {
            let base = data.startIndex + i * 4
            let b = data[base]
            let g = data[base + 1]
            let r = data[base + 2]
            // byte 3 is padding in Windows RGBQUAD, treat as opaque
            colors.append((r: r, g: g, b: b, a: 255))
        }

        self.colors = colors
    }

    public func rgba(forIndex idx: UInt8) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        colors[Int(idx)]
    }
}

public enum COLError: Error, CustomStringConvertible {
    case dataTooShort(Int)

    public var description: String {
        switch self {
        case .dataTooShort(let n): return "COL palette too short: \(n) bytes (need 1024)"
        }
    }
}
