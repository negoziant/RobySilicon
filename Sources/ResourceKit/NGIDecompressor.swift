import Foundation

public final class NGIDecompressor {
    private static let N_CHAR = 314
    private static let TN = 627
    private static let ROOT = 626
    private static let MAX_FREQ: UInt16 = 0x8000
    private static let RING_SIZE = 4096
    private static let RING_MASK = 0xFFF

    private var freq = [UInt16](repeating: 0, count: 628)
    private var prnt = [Int](repeating: 0, count: 942)
    private var son  = [Int](repeating: 0, count: 627)
    private var ring = [UInt8](repeating: 0, count: 4096)
    private var ringPos = 0xFC4

    // Generated at init from source tables extracted from NGI32.DLL (RVA 0x43210, 0x43216)
    private var posTable = [UInt32](repeating: 0, count: 256)
    private var posLenTable = [UInt8](repeating: 0, count: 256)

    private static let posTableSrc: [UInt8] = [0x01, 0x03, 0x08, 0x0C, 0x18, 0x10]
    private static let posLenSrc: [UInt8] = [0x20, 0x30, 0x40, 0x30, 0x30, 0x10]

    public init() {
        initTree()
    }

    private func initTree() {
        generatePositionTables()

        for i in 0..<Self.N_CHAR {
            freq[i] = 1
            son[i] = i + Self.TN
            prnt[i + Self.TN] = i
        }

        var i = 0
        var j = Self.N_CHAR
        while j <= Self.ROOT {
            freq[j] = freq[i] &+ freq[i + 1]
            son[j] = i
            prnt[i] = j
            prnt[i + 1] = j
            i += 2
            j += 1
        }

        freq[Self.TN] = 0xFFFF
        prnt[Self.ROOT] = 0
    }

    private func generatePositionTables() {
        var value: UInt32 = 0
        var idx = 0
        var srcIdx = 0
        var groupSize: UInt32 = 0x20

        while groupSize != 0 {
            let count = Int(Self.posTableSrc[srcIdx])
            srcIdx += 1
            for _ in 0..<count {
                for _ in 0..<Int(groupSize) {
                    if idx < 256 { posTable[idx] = value }
                    idx += 1
                }
                value &+= 0x400000
            }
            groupSize >>= 1
        }

        var lenVal: UInt8 = 1
        idx = 0
        for si in 0..<6 {
            let count = Int(Self.posLenSrc[si])
            for _ in 0..<count {
                if idx < 256 { posLenTable[idx] = lenVal }
                idx += 1
            }
            lenVal += 1
        }
    }

    // MARK: - Decompress

    public func decompress(src: Data, decompressedSize: Int) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(decompressedSize)

        let srcBytes = [UInt8](src)
        let srcEnd = srcBytes.count
        var srcPos = 0

        // DLL uses ebp as 32-bit bit buffer, cl as signed bit counter
        var bitBuf: UInt32 = 0
        var bitCnt: Int = 8

        ringPos = 0xFC4
        ring = [UInt8](repeating: 0, count: Self.RING_SIZE)
        for i in 0..<ringPos {
            ring[i] = 0x20
        }

        initTree()

        func readByte() -> UInt32 {
            if srcPos < srcEnd {
                let b = UInt32(srcBytes[srcPos])
                srcPos += 1
                return b
            }
            return 0
        }

        // Load bytes into bit buffer while bitCnt >= 0
        // Matches DLL: shl eax, cl; or ebp, eax; sub cl, 8; jns loop
        func fillBits() {
            while bitCnt >= 0 {
                let byte = readByte()
                let shifted = byte << UInt32(bitCnt & 0x1F)
                bitBuf |= shifted
                bitCnt -= 8
            }
        }

        while output.count < decompressedSize {
            // --- Decode Huffman character ---
            var node = son[Self.ROOT]
            bitCnt -= 1

            while node < Self.TN {
                bitCnt += 1
                if bitCnt >= 0 { fillBits() }
                // shl bp, 1 — 16-bit shift only! Upper 16 bits of bitBuf untouched.
                let carry = Int((bitBuf >> 15) & 1)
                bitBuf = (bitBuf & 0xFFFF0000) | ((bitBuf << 1) & 0xFFFF)
                node += carry
                node = son[node]
            }

            bitCnt += 1
            let char = node - Self.TN
            update(char)

            if char < 256 {
                let byte = UInt8(char)
                output.append(byte)
                ring[ringPos] = byte
                ringPos = (ringPos + 1) & Self.RING_MASK
            } else {
                // --- Decode position ---
                if bitCnt >= 0 { fillBits() }

                // shl ebp, 8 — full 32-bit shift
                bitBuf = bitBuf << 8
                let prefix = Int((bitBuf >> 16) & 0xFF)

                let extraBits = Int(posLenTable[prefix])
                let basePos = posTable[prefix]
                bitCnt += 8

                // Read extraBits extra bits with shl ebp, 1 (32-bit)
                var remaining = extraBits
                while remaining > 0 {
                    if bitCnt >= 0 { fillBits() }
                    bitBuf = bitBuf << 1
                    remaining -= 1
                    if remaining > 0 {
                        bitCnt += 1
                    }
                }
                bitCnt += 1

                let position = Int(((bitBuf & 0x3F0000) | basePos) >> 16)
                let matchLen = char - 253

                var src2 = (ringPos - 1 - position) & Self.RING_MASK
                for _ in 0..<matchLen {
                    let byte = ring[src2]
                    output.append(byte)
                    ring[ringPos] = byte
                    ringPos = (ringPos + 1) & Self.RING_MASK
                    src2 = (src2 + 1) & Self.RING_MASK
                }
            }
        }

        if output.count > decompressedSize {
            return Data(output.prefix(decompressedSize))
        }
        return Data(output)
    }

    // MARK: - Plain LZSS (flag 0x0040, no Huffman)

    public static func decompressLZSS(src: Data, decompressedSize: Int) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(decompressedSize)

        let srcBytes = [UInt8](src)
        let srcEnd = srcBytes.count
        var srcPos = 0

        var ring = [UInt8](repeating: 0, count: RING_SIZE)
        for i in 0..<0xFEE { ring[i] = 0x20 }
        var ringPos = 0xFEE

        var flagByte: UInt8 = 0
        var flagBits: UInt8 = 0

        while output.count < decompressedSize {
            if flagBits == 0 {
                guard srcPos < srcEnd else { break }
                flagByte = srcBytes[srcPos]; srcPos += 1
                flagBits = 8
            }

            guard srcPos < srcEnd else { break }
            let bit = flagByte & 1
            flagByte >>= 1
            flagBits -= 1

            if bit == 1 {
                let byte = srcBytes[srcPos]; srcPos += 1
                output.append(byte)
                ring[ringPos] = byte
                ringPos = (ringPos + 1) & RING_MASK
            } else {
                guard srcPos + 1 < srcEnd else { break }
                let b0 = UInt16(srcBytes[srcPos])
                let b1 = UInt16(srcBytes[srcPos + 1])
                srcPos += 2

                let matchPos = Int((b1 >> 4) << 8 | b0)
                let matchLen = Int(b1 & 0x0F) + 3

                var pos = matchPos
                for _ in 0..<matchLen {
                    let byte = ring[pos]
                    output.append(byte)
                    ring[ringPos] = byte
                    ringPos = (ringPos + 1) & RING_MASK
                    pos = (pos + 1) & RING_MASK
                    if output.count >= decompressedSize { break }
                }
            }
        }

        if output.count > decompressedSize {
            return Data(output.prefix(decompressedSize))
        }
        return Data(output)
    }

    // MARK: - Adaptive Huffman tree

    private func update(_ c: Int) {
        if freq[Self.ROOT] == Self.MAX_FREQ {
            reconst()
        }

        var ci = prnt[c + Self.TN]
        repeat {
            freq[ci] &+= 1
            let k = freq[ci]

            var l = ci + 1
            if l > Self.ROOT { break }
            if k > freq[l] {
                while l + 1 <= Self.TN && k > freq[l + 1] { l += 1 }

                freq[ci] = freq[l]
                freq[l] = k

                let sonI = son[ci]
                prnt[sonI] = l
                if sonI < Self.TN { prnt[sonI + 1] = l }

                let sonJ = son[l]
                son[l] = sonI

                prnt[sonJ] = ci
                if sonJ < Self.TN { prnt[sonJ + 1] = ci }
                son[ci] = sonJ

                ci = l
            }

            ci = prnt[ci]
        } while ci != 0
    }

    private func reconst() {
        var j = 0
        for i in 0..<Self.TN {
            if son[i] >= Self.TN {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
        }

        var i2 = 0
        j = Self.N_CHAR
        while j < Self.TN {
            let f = freq[i2] &+ freq[i2 + 1]

            var k = j - 1
            while k >= 0 && f < freq[k] { k -= 1 }
            k += 1

            var m = j
            while m > k {
                freq[m] = freq[m - 1]
                son[m] = son[m - 1]
                m -= 1
            }

            freq[k] = f
            son[k] = i2
            i2 += 2
            j += 1
        }

        for i in 0..<Self.TN {
            let k = son[i]
            prnt[k] = i
            if k < Self.TN {
                prnt[k + 1] = i
            }
        }
    }
}
