import Foundation
import Compression

public struct NLResourceEntry {
    public let name: String
    public let flags: UInt16
    public let key: UInt16
    public let decompressedSize: UInt32
    public let offset: UInt32
    public let compressedSize: UInt32

    public var isHuffmanCompressed: Bool { flags & 0x0080 != 0 }
    public var isLZSSCompressed: Bool { flags & 0x0040 != 0 }
    public var isDeflateCompressed: Bool { flags & 0x0100 != 0 }
    public var isCompressed: Bool { isHuffmanCompressed || isLZSSCompressed }
}

public struct NLContainer {
    public let version: UInt16
    public let resourceCount: UInt16
    public let lfsrKey: UInt32
    public let entries: [NLResourceEntry]

    private let fileHandle: FileHandle
    private let filePath: String

    public init(path: String) throws {
        self.filePath = path
        self.fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))

        let headerData = fileHandle.readData(ofLength: 0x20)
        guard headerData.count == 0x20 else {
            throw NLError.invalidHeader("File too short for NL header")
        }

        let magic = headerData[0..<2]
        guard magic[0] == 0x4E, magic[1] == 0x4C else {
            throw NLError.invalidHeader("Bad magic: expected 'NL'")
        }

        self.version = headerData.readUInt16(at: 2)
        self.resourceCount = headerData.readUInt16(at: 4)
        self.lfsrKey = headerData.readUInt32(at: 0x14)

        let tableSize = Int(resourceCount) * 32
        let encryptedTable = fileHandle.readData(ofLength: tableSize)
        guard encryptedTable.count == tableSize else {
            throw NLError.invalidHeader("File too short for resource table")
        }

        let decryptedTable = NLContainer.lfsrDecrypt(data: encryptedTable, keyDword: lfsrKey)

        var entries: [NLResourceEntry] = []
        for i in 0..<Int(resourceCount) {
            let base = i * 32
            let nameData = decryptedTable[base..<(base + 12)]
            let name = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""

            let flags = decryptedTable.readUInt16(at: base + 16)
            let key = decryptedTable.readUInt16(at: base + 18)
            let decompressedSize = decryptedTable.readUInt32(at: base + 20)
            let offset = decryptedTable.readUInt32(at: base + 24)
            let compressedSize = decryptedTable.readUInt32(at: base + 28)

            entries.append(NLResourceEntry(
                name: name,
                flags: flags,
                key: key,
                decompressedSize: decompressedSize,
                offset: offset,
                compressedSize: compressedSize
            ))
        }

        self.entries = entries
    }

    public func readRawResource(at index: Int) throws -> Data {
        guard index >= 0, index < entries.count else {
            throw NLError.indexOutOfBounds(index, entries.count)
        }
        let entry = entries[index]
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        handle.seek(toFileOffset: UInt64(entry.offset))
        let data = handle.readData(ofLength: Int(entry.compressedSize))
        handle.closeFile()
        return data
    }

    public func extractResource(at index: Int, decompressor: NGIDecompressor) throws -> Data {
        let entry = entries[index]
        let rawData = try readRawResource(at: index)

        if entry.isHuffmanCompressed {
            return decompressor.decompress(src: rawData, decompressedSize: Int(entry.decompressedSize))
        } else if entry.isLZSSCompressed {
            return NGIDecompressor.decompressLZSS(src: rawData, decompressedSize: Int(entry.decompressedSize))
        } else if entry.isDeflateCompressed {
            // Флаг 0x0100 — сырой deflate (мини-игры: HOUSE/CHESS/MAP/BALOON/CRYPT).
            // Путь в NGI32: диспетчер flags&0x1E0==0x100 → инфлятор 0x10026c30
            // (1 бит BFINAL + 2 бита BTYPE — классический deflate).
            guard let out = Self.inflate(rawData, decompressedSize: Int(entry.decompressedSize)) else {
                throw NLError.decompressionFailed(entry.name)
            }
            return out
        } else {
            return rawData
        }
    }

    public static func inflate(_ data: Data, decompressedSize: Int) -> Data? {
        var dst = Data(count: decompressedSize)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dp = d.bindMemory(to: UInt8.self).baseAddress,
                      let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dp, decompressedSize, sp, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == decompressedSize else { return nil }
        return dst
    }

    public static func lfsrDecrypt(data: Data, keyDword: UInt32) -> Data {
        var al = UInt8(keyDword & 0xFF)
        var dl = UInt8((keyDword >> 8) & 0xFF)
        var out = Data(capacity: data.count)
        for b in data {
            al = (al &<< 1) & 0xFF
            al ^= dl
            dl >>= 1
            out.append(b ^ al)
            dl ^= al
        }
        return out
    }
}

public enum NLError: Error, CustomStringConvertible {
    case invalidHeader(String)
    case indexOutOfBounds(Int, Int)
    case decompressionFailed(String)

    public var description: String {
        switch self {
        case .invalidHeader(let msg): return "NL Header Error: \(msg)"
        case .indexOutOfBounds(let idx, let count): return "Index \(idx) out of bounds (count: \(count))"
        case .decompressionFailed(let msg): return "Decompression Error: \(msg)"
        }
    }
}

public extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let idx = self.startIndex + offset
        return UInt16(self[idx]) | (UInt16(self[idx + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let idx = self.startIndex + offset
        return UInt32(self[idx])
            | (UInt32(self[idx + 1]) << 8)
            | (UInt32(self[idx + 2]) << 16)
            | (UInt32(self[idx + 3]) << 24)
    }

    func readInt16(at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(at: offset))
    }
}
