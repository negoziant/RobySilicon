import SpriteKit
import ResourceKit

protocol MiniGameNodeProtocol: SKNode {
    func handleMouseDown(at point: CGPoint)
    func handleMouseDragged(to point: CGPoint)
    func handleMouseUp(at point: CGPoint)
    func handleRightMouseDown(at point: CGPoint)
    func handleKeyDown(keyCode: UInt16)
    func tick(_ currentTime: TimeInterval)
}

extension MiniGameNodeProtocol {
    func handleKeyDown(keyCode: UInt16) {}
    func tick(_ currentTime: TimeInterval) {}
}

enum MiniGameArt {
    // NGB мини-игр: RAW если size==16+w*h, иначе RLE (байт 9 здесь не показатель).
    // origin (xLeft,yTop) ненулевой у спрайтов PIPE.DAT — это их экранная позиция.
    static func decodeNGB(_ data: Data, palette: COLPalette, transparent: Bool)
        -> (image: CGImage, width: Int, height: Int, x: Int, y: Int)? {
        guard data.count >= 16 else { return nil }
        let x0 = Int(data.readInt16(at: 0)), y0 = Int(data.readInt16(at: 2))
        let x1 = Int(data.readInt16(at: 4)), y1 = Int(data.readInt16(at: 6))
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard w > 0, h > 0 else { return nil }
        var canvas = [UInt8](repeating: 0, count: w * h)
        // RLE: прозрачность = НЕпокрытые данными пиксели; покрытый индекс 0 —
        // валидный цвет (ALT.NGB шара — чёрная лента с дырками-цифрами).
        // RAW такой маски не имеет — там прозрачным считается индекс 0.
        var covered: [Bool]?
        if data.count == 16 + w * h {
            for i in 0..<(w * h) { canvas[i] = data[data.startIndex + 16 + i] }
        } else {
            covered = [Bool](repeating: false, count: w * h)
            let start = data.startIndex
            for row in 0..<h {
                let off = Int(data.readUInt32(at: 16 + row * 4))
                guard off + 2 <= data.count else { continue }
                if data[start + off] == 0xFF && data[start + off + 1] == 0xFF { continue }
                var pos = start + off
                let end = start + data.count
                var x = 0
                var first = true
                while pos + 3 < end {
                    let skip = Int(data[pos]) | (Int(data[pos + 1]) << 8)
                    pos += 2
                    if skip == 0xFFFF { break }
                    let cnt = Int(data[pos]) | (Int(data[pos + 1]) << 8)
                    pos += 2
                    x = first ? skip : x + skip
                    first = false
                    guard cnt > 0, pos + cnt <= end else { break }
                    for j in 0..<cnt where x + j < w {
                        canvas[row * w + x + j] = data[pos + j]
                        covered?[row * w + x + j] = true
                    }
                    pos += cnt
                    x += cnt
                }
            }
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let px = buf.bindMemory(to: UInt8.self, capacity: stride * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = canvas[y * w + x]
                let dst = y * stride + x * 4
                let clear = covered.map { !$0[y * w + x] } ?? (v == 0)
                if transparent && clear {
                    px[dst] = 0; px[dst + 1] = 0; px[dst + 2] = 0; px[dst + 3] = 0
                } else {
                    let c = palette.rgba(forIndex: v)
                    px[dst] = c.r; px[dst + 1] = c.g; px[dst + 2] = c.b; px[dst + 3] = 255
                }
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, w, h, x0, y0)
    }
}
