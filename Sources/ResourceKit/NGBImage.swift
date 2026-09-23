import Foundation

public struct NGBImage {
    public let xLeft: Int16
    public let yTop: Int16
    public let xRight: Int16
    public let yBottom: Int16
    public let flags: UInt8
    public let pixels: Data

    public var width: Int { Int(xRight) - Int(xLeft) + 1 }
    public var height: Int { Int(yBottom) - Int(yTop) + 1 }

    public init(data: Data) throws {
        guard data.count >= 16 else {
            throw NGBError.headerTooShort(data.count)
        }

        xLeft = data.readInt16(at: 0)
        yTop = data.readInt16(at: 2)
        xRight = data.readInt16(at: 4)
        yBottom = data.readInt16(at: 6)
        flags = data[data.startIndex + 8]

        let w = Int(xRight) - Int(xLeft) + 1
        let h = Int(yBottom) - Int(yTop) + 1
        guard w > 0, h > 0 else {
            throw NGBError.invalidDimensions(w, h)
        }

        let expected = 16 + w * h
        guard data.count >= expected else {
            throw NGBError.dataTooShort(expected: expected, got: data.count)
        }

        pixels = data[data.startIndex + 16 ..< data.startIndex + expected]
    }
}

public enum NGBError: Error, CustomStringConvertible {
    case headerTooShort(Int)
    case invalidDimensions(Int, Int)
    case dataTooShort(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .headerTooShort(let n): return "NGB header too short: \(n) bytes"
        case .invalidDimensions(let w, let h): return "NGB invalid dimensions: \(w)x\(h)"
        case .dataTooShort(let e, let g): return "NGB data too short: expected \(e), got \(g)"
        }
    }
}
