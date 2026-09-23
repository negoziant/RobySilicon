import Foundation

public struct SCRScript {
    public struct FrameEntry {
        public let flags: UInt32
        public let ngbResourceIndex: Int
        public var isSkip: Bool { ngbResourceIndex == 0 }
    }

    public let frameCount: Int
    public let defaultDelayMs: Int
    public let screenWidth: Int
    public let screenHeight: Int
    public let shiftX: Int
    public let shiftY: Int
    public let entries: [FrameEntry]

    public init(data: Data) {
        guard data.count >= 32 else {
            frameCount = 0; defaultDelayMs = 0; screenWidth = 0; screenHeight = 0
            shiftX = 0; shiftY = 0; entries = []
            return
        }

        // Заголовок переменного размера: обычно 32, но бывает 36 с тегом
        // "Movi" в поле 4 (REST0/REST1.SCR). Записи начинаются с headerSize.
        let headerSize = max(32, min(Int(data.readUInt32(at: 0)), data.count))
        frameCount = Int(data.readUInt32(at: 8))
        defaultDelayMs = Int(data.readUInt32(at: 12))
        screenWidth = Int(data.readUInt32(at: 16))
        screenHeight = Int(data.readUInt32(at: 20))
        shiftX = Int(data.readUInt32(at: 24))
        shiftY = Int(data.readUInt32(at: 28))

        var entries: [FrameEntry] = []
        entries.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let off = headerSize + i * 8
            guard off + 7 < data.count else { break }
            entries.append(FrameEntry(
                flags: data.readUInt32(at: off),
                ngbResourceIndex: Int(data.readUInt32(at: off + 4))
            ))
        }
        self.entries = entries
    }
}
