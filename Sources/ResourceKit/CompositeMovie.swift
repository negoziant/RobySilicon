import Foundation
import CoreGraphics

public final class CompositeMovie {
    // COL внутри MV часто от чужой палитры (BEACH.MV: 240/256 отличий от
    // SCENA2.COL). Экран оригинала 8-битный с одной сценовой палитрой —
    // для внутрисценового рендера её подставляют через setPalette.
    public private(set) var palette: COLPalette
    public let scr: SCRScript
    public let canvasWidth: Int
    public let canvasHeight: Int

    private var canvas: [UInt8]
    private let ngbData: [Int: Data]

    public init(path: String, decompressor: NGIDecompressor) throws {
        let container = try NLContainer(path: path)

        guard let colIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".COL") }) else {
            throw MVError.missingPalette(path)
        }
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)
        self.palette = try COLPalette(data: colData)

        if let scrIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCR") }) {
            let scrData = try container.extractResource(at: scrIdx, decompressor: decompressor)
            self.scr = SCRScript(data: scrData)
        } else {
            self.scr = SCRScript(data: Data())
        }

        var ngbData: [Int: Data] = [:]
        var maxW = 0, maxH = 0

        for (i, entry) in container.entries.enumerated() {
            guard entry.name.uppercased().hasSuffix(".NGB") else { continue }
            let data = try container.extractResource(at: i, decompressor: decompressor)
            ngbData[i] = data

            if data.count >= 8 {
                let w = Int(data.readInt16(at: 4)) + 1
                let h = Int(data.readInt16(at: 6)) + 1
                if w > maxW { maxW = w }
                if h > maxH { maxH = h }
            }
        }

        self.ngbData = ngbData
        self.canvasWidth = max(maxW, 1)
        self.canvasHeight = max(maxH, 1)
        self.canvas = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)
    }

    public func setPalette(_ newPalette: COLPalette) {
        palette = newPalette
    }

    public func clearCanvas() {
        for i in canvas.indices { canvas[i] = 0 }
    }

    public func applyFrame(logicalIndex: Int) -> Bool {
        guard logicalIndex >= 0, logicalIndex < scr.entries.count else { return false }
        let entry = scr.entries[logicalIndex]
        if entry.isSkip { return false }

        guard let data = ngbData[entry.ngbResourceIndex] else { return false }
        overlayNGB(data: data)
        return true
    }

    public func canvasChecksum() -> UInt32 {
        var h: UInt32 = 0
        for b in canvas { h = h &* 31 &+ UInt32(b) }
        return h
    }

    /// Быстрый рендер только занятой области канвы (bbox непрозрачных пикселей).
    /// Возвращает картинку и её смещение внутри канвы — полный канвас 640×480
    /// на каждый кадр непозволительно дорог (память и время).
    public func renderCanvasCropped(transparentIndex: UInt8 = 0) -> (image: CGImage, x: Int, y: Int)? {
        var minX = canvasWidth, maxX = -1, minY = canvasHeight, maxY = -1
        for y in 0..<canvasHeight {
            let row = y * canvasWidth
            for x in 0..<canvasWidth where canvas[row + x] != transparentIndex {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1

        // LUT палитры: один UInt32 (RGBA premultiplied, alpha 255) на индекс
        var lut = [UInt32](repeating: 0, count: 256)
        for i in 1..<256 {
            let c = palette.rgba(forIndex: UInt8(i))
            lut[i] = UInt32(c.r) | (UInt32(c.g) << 8) | (UInt32(c.b) << 16) | 0xFF00_0000
        }
        lut[Int(transparentIndex)] = 0

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return nil }
        let stride32 = ctx.bytesPerRow / 4
        let px = buf.bindMemory(to: UInt32.self, capacity: stride32 * h)
        for y in 0..<h {
            let src = (minY + y) * canvasWidth + minX
            let dst = y * stride32
            for x in 0..<w {
                px[dst + x] = lut[Int(canvas[src + x])]
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, minX, minY)
    }

    public func renderCanvas(transparentIndex: UInt8? = nil) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = ctx.data else { return nil }

        let rowBytes = ctx.bytesPerRow
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: rowBytes * canvasHeight)

        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                let idx = canvas[y * canvasWidth + x]
                let dst = y * rowBytes + x * 4
                if let ti = transparentIndex, idx == ti {
                    pixels[dst] = 0
                    pixels[dst + 1] = 0
                    pixels[dst + 2] = 0
                    pixels[dst + 3] = 0
                } else {
                    let c = palette.rgba(forIndex: idx)
                    pixels[dst] = c.r
                    pixels[dst + 1] = c.g
                    pixels[dst + 2] = c.b
                    pixels[dst + 3] = c.a
                }
            }
        }

        return ctx.makeImage()
    }

    // MARK: - NGB overlay

    private func overlayNGB(data: Data) {
        guard data.count >= 16 else { return }

        let xLeft = Int(data.readInt16(at: 0))
        let yTop = Int(data.readInt16(at: 2))
        let xRight = Int(data.readInt16(at: 4))
        let yBottom = Int(data.readInt16(at: 6))

        let frameW = xRight - xLeft + 1
        let frameH = yBottom - yTop + 1
        guard frameW > 0, frameH > 0 else { return }

        let isRLE = data[data.startIndex + 9] != 0
        if isRLE {
            overlayRLE(data: data, xLeft: xLeft, yTop: yTop, frameH: frameH)
        } else {
            overlayRaw(data: data, xLeft: xLeft, yTop: yTop, frameW: frameW, frameH: frameH)
        }
    }

    private func overlayRaw(data: Data, xLeft: Int, yTop: Int, frameW: Int, frameH: Int) {
        let base = data.startIndex + 16
        for y in 0..<frameH {
            let dstY = yTop + y
            guard dstY >= 0, dstY < canvasHeight else { continue }
            let rowStart = dstY * canvasWidth
            for x in 0..<frameW {
                let dstX = xLeft + x
                guard dstX >= 0, dstX < canvasWidth else { continue }
                canvas[rowStart + dstX] = data[base + y * frameW + x]
            }
        }
    }

    private func overlayRLE(data: Data, xLeft: Int, yTop: Int, frameH: Int) {
        let rowTableSize = frameH * 4
        guard data.count >= 16 + rowTableSize else { return }

        for row in 0..<frameH {
            let rowOffset = Int(data.readUInt32(at: 16 + row * 4))
            guard rowOffset < data.count else { continue }

            var pos = data.startIndex + rowOffset
            let end = data.startIndex + data.count

            guard pos + 1 < end else { continue }
            if data[pos] == 0xFF && data[pos + 1] == 0xFF { continue }

            let dstY = yTop + row
            guard dstY >= 0, dstY < canvasHeight else { continue }
            let rowStart = dstY * canvasWidth

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

                for j in 0..<count {
                    let dstX = xLeft + curX + j
                    if dstX >= 0, dstX < canvasWidth {
                        canvas[rowStart + dstX] = data[pos + j]
                    }
                }
                pos += count
                curX += count
            }
        }
    }
}
