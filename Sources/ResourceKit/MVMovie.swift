import Foundation
import CoreGraphics

public struct MVFrame {
    public let image: CGImage
    public let originX: Int
    public let originY: Int
}

public struct MVMovie {
    public let palette: COLPalette
    public let frames: [MVFrame]

    public init(path: String, decompressor: NGIDecompressor) throws {
        let container = try NLContainer(path: path)

        guard let colIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".COL") }) else {
            throw MVError.missingPalette(path)
        }
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)
        self.palette = try COLPalette(data: colData)

        var frames: [MVFrame] = []
        for (i, entry) in container.entries.enumerated() {
            guard entry.name.uppercased().hasSuffix(".NGB") else { continue }
            let data = try container.extractResource(at: i, decompressor: decompressor)
            if let frame = try MVMovie.decodeRLEFrame(data: data, palette: self.palette) {
                frames.append(frame)
            }
        }
        self.frames = frames
    }

    static func decodeRLEFrame(data: Data, palette: COLPalette) throws -> MVFrame? {
        guard data.count >= 16 else { return nil }

        let xLeft = Int(data.readInt16(at: 0))
        let yTop = Int(data.readInt16(at: 2))
        let xRight = Int(data.readInt16(at: 4))
        let yBottom = Int(data.readInt16(at: 6))

        let canvasW = xRight - xLeft + 1
        let canvasH = yBottom - yTop + 1
        guard canvasW > 0, canvasH > 0 else { return nil }

        let isRLE = data[9] != 0
        if !isRLE {
            return try decodeRawFrame(data: data, palette: palette)
        }

        let rowTableSize = canvasH * 4
        guard data.count >= 16 + rowTableSize else { return nil }

        var minX = canvasW, minY = canvasH, maxX = 0, maxY = 0
        var rowRuns: [(y: Int, runs: [(x: Int, pixels: [UInt8])])] = []

        for row in 0..<canvasH {
            let rowOffset = Int(data.readUInt32(at: 16 + row * 4))
            guard rowOffset < data.count else { continue }

            var pos = data.startIndex + rowOffset
            let end = data.startIndex + data.count

            guard pos + 1 < end else { continue }
            if data[pos] == 0xFF && data[pos + 1] == 0xFF { continue }

            var runs: [(x: Int, pixels: [UInt8])] = []
            var curX = 0
            var isFirst = true

            while pos + 3 < end {
                let skip = Int(UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8))
                pos += 2

                if skip == 0xFFFF { break }

                let count = Int(UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8))
                pos += 2

                if count == 0xFFFF { break }

                if isFirst {
                    curX = skip
                    isFirst = false
                } else {
                    curX += skip
                }

                guard count > 0, pos + count <= end else { break }

                var pixels: [UInt8] = []
                for j in 0..<count {
                    pixels.append(data[pos + j])
                }
                pos += count

                runs.append((x: curX, pixels: pixels))

                if curX < minX { minX = curX }
                if curX + count - 1 > maxX { maxX = curX + count - 1 }
                if row < minY { minY = row }
                if row > maxY { maxY = row }

                curX += count
            }

            if !runs.isEmpty {
                rowRuns.append((y: row, runs: runs))
            }
        }

        guard minX <= maxX, minY <= maxY else { return nil }

        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: cropW,
            height: cropH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = ctx.data else { return nil }

        let pixels = buffer.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * cropH)
        let rowBytes = ctx.bytesPerRow

        for rowData in rowRuns {
            let dy = rowData.y - minY
            for run in rowData.runs {
                for (i, idx) in run.pixels.enumerated() {
                    let dx = run.x + i - minX
                    guard dx >= 0, dx < cropW else { continue }
                    let dst = dy * rowBytes + dx * 4
                    let c = palette.rgba(forIndex: idx)
                    pixels[dst] = c.r
                    pixels[dst + 1] = c.g
                    pixels[dst + 2] = c.b
                    pixels[dst + 3] = c.a
                }
            }
        }

        guard let image = ctx.makeImage() else { return nil }

        return MVFrame(
            image: image,
            originX: xLeft + minX,
            originY: yTop + minY
        )
    }

    static func decodeRawFrame(data: Data, palette: COLPalette) throws -> MVFrame? {
        let ngb = try NGBImage(data: data)
        guard let image = PNGRenderer.render(ngb: ngb, palette: palette, transparentIndex: 0) else {
            return nil
        }
        return MVFrame(
            image: image,
            originX: Int(ngb.xLeft),
            originY: Int(ngb.yTop)
        )
    }
}

public enum MVError: Error, CustomStringConvertible {
    case missingPalette(String)

    public var description: String {
        switch self {
        case .missingPalette(let p): return "No COL palette in \(p)"
        }
    }
}
