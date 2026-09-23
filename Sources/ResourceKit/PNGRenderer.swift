import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct PNGRenderer {
    public static func render(ngb: NGBImage, palette: COLPalette, transparentIndex: UInt8? = 0, fad: FADTable? = nil, fadeLevel: Int = 0) -> CGImage? {
        let w = ngb.width
        let h = ngb.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = ctx.data else { return nil }

        let rowBytes = ctx.bytesPerRow
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        let pixelBase = ngb.pixels.startIndex
        let useFad = fad != nil && fadeLevel > 0

        for y in 0..<h {
            for x in 0..<w {
                var idx = ngb.pixels[pixelBase + y * w + x]
                let dst = y * rowBytes + x * 4
                if let ti = transparentIndex, idx == ti {
                    pixels[dst] = 0
                    pixels[dst + 1] = 0
                    pixels[dst + 2] = 0
                    pixels[dst + 3] = 0
                } else {
                    if useFad {
                        idx = fad!.fadedIndex(idx, level: fadeLevel)
                    }
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

    public static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            throw PNGError.cannotCreateDestination(path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PNGError.finalizeFailed(path)
        }
    }
}

public enum PNGError: Error, CustomStringConvertible {
    case cannotCreateDestination(String)
    case finalizeFailed(String)

    public var description: String {
        switch self {
        case .cannotCreateDestination(let p): return "Cannot create PNG at \(p)"
        case .finalizeFailed(let p): return "Failed to write PNG at \(p)"
        }
    }
}
