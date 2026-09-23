import Foundation
import CoreGraphics
import ResourceKit

func listResources(path: String) {
    do {
        let container = try NLContainer(path: path)
        let filename = (path as NSString).lastPathComponent
        print("=== \(filename) === (\(container.resourceCount) resources, LFSR=0x\(String(container.lfsrKey, radix: 16, uppercase: true)))")

        for (i, entry) in container.entries.enumerated() {
            let compressed = entry.isHuffmanCompressed ? "HUFFLZSS" : entry.isLZSSCompressed ? "LZSS" : "raw"
            let name = entry.name.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("  \(String(format: "%3d", i))  \(name)  fl=0x\(String(format: "%04X", entry.flags))  key=0x\(String(format: "%04X", entry.key))  dec=\(String(format: "%-8d", entry.decompressedSize))  off=\(String(format: "%-8d", entry.offset))  cmp=\(String(format: "%-8d", entry.compressedSize))  \(compressed)")
        }
        print()
    } catch {
        print("ERROR: \(error)")
    }
}

func extractAll(datPath: String, outDir: String, maxCount: Int = Int.max) {
    do {
        let container = try NLContainer(path: datPath)
        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let decompressor = NGIDecompressor()
        let count = min(Int(container.resourceCount), maxCount)
        for i in 0..<count {
            let entry = container.entries[i]
            print("[\(i)/\(container.resourceCount)] \(entry.name) (\(entry.decompressedSize) bytes, \(entry.isCompressed ? "compressed" : "raw"))...", terminator: " ")
            fflush(stdout)

            let data = try container.extractResource(at: i, decompressor: decompressor)
            let outPath = (outDir as NSString).appendingPathComponent(entry.name)
            try data.write(to: URL(fileURLWithPath: outPath))

            var info = "\(data.count) bytes"
            if entry.name.uppercased().hasSuffix(".NGB") && data.count >= 9 {
                let xL = data.readInt16(at: 0), yT = data.readInt16(at: 2)
                let xR = data.readInt16(at: 4), yB = data.readInt16(at: 6)
                info += " (\(xR - xL + 1)x\(yB - yT + 1))"
            }
            if entry.name.uppercased().hasSuffix(".COL") {
                let r = data[2], g = data[1], b = data[0]
                info += " (color0: R=\(r) G=\(g) B=\(b))"
            }
            print(info)
        }
    } catch {
        print("\nERROR: \(error)")
    }
}

func renderAll(datPath: String, outDir: String) {
    do {
        let container = try NLContainer(path: datPath)
        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let decompressor = NGIDecompressor()

        // Find palette (.COL resource)
        guard let colIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".COL") }) else {
            print("ERROR: No .COL palette found in \(datPath)")
            exit(1)
        }
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)
        let palette = try COLPalette(data: colData)
        print("Palette: \(container.entries[colIdx].name) (256 colors)")

        var rendered = 0
        for i in 0..<Int(container.resourceCount) {
            let entry = container.entries[i]
            guard entry.name.uppercased().hasSuffix(".NGB") else { continue }

            print("[\(i)] \(entry.name)...", terminator: " ")
            fflush(stdout)

            let data = try container.extractResource(at: i, decompressor: decompressor)
            let ngb = try NGBImage(data: data)

            guard let image = PNGRenderer.render(ngb: ngb, palette: palette) else {
                print("render failed")
                continue
            }

            let baseName = (entry.name as NSString).deletingPathExtension
            let pngPath = (outDir as NSString).appendingPathComponent("\(baseName).png")
            try PNGRenderer.writePNG(image, to: pngPath)
            print("\(ngb.width)x\(ngb.height) at (\(ngb.xLeft),\(ngb.yTop)) → \(baseName).png")
            rendered += 1
        }
        print("\nRendered \(rendered) images to \(outDir)")
    } catch {
        print("\nERROR: \(error)")
    }
}

func dumpScene(datPath: String) {
    do {
        let container = try NLContainer(path: datPath)
        let decompressor = NGIDecompressor()
        let filename = (datPath as NSString).lastPathComponent
        let baseName = (filename as NSString).deletingPathExtension

        guard let scnIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCN") }) else {
            print("ERROR: No .SCN found in \(filename)"); exit(1)
        }
        let scnData = try container.extractResource(at: scnIdx, decompressor: decompressor)
        let scn = SceneConfig(data: scnData)

        print("=== \(baseName) — Scene Config ===")
        print("Scene: \(scn.sceneName)  Screen: \(scn.screenName)  Bar: \(scn.barName)")
        print("ScreenSize: \(scn.screenWidth)x\(scn.screenHeight)")
        print("Grid: \(scn.gridLength.0)x\(scn.gridLength.1)  CellSize: \(scn.gridSize.0)x\(scn.gridSize.1)  Origin: (\(scn.leftTopGrid.0),\(scn.leftTopGrid.1))  Shift: (\(scn.gridShift.0),\(scn.gridShift.1))  Z/grid: \(scn.zPerGrid)")
        print("Scroll: par=(\(scn.scrollPar.0),\(scn.scrollPar.1)) desc=(\(scn.scrollDesc.0),\(scn.scrollDesc.1))")
        if !scn.closedVerts.isEmpty {
            print("ClosedVerts: \(scn.closedVerts.map { "(\($0.0),\($0.1))" }.joined(separator: " "))")
        }
        if !scn.closedDirs.isEmpty {
            print("ClosedDirs: \(scn.closedDirs.map { "(\($0.x),\($0.y),\($0.dir))" }.joined(separator: " "))")
        }
        print("Music: \(scn.music)")
        print()

        print("Objects (\(scn.objects.count)):")
        for obj in scn.objects {
            print("  \(obj.name) at (\(obj.gridX),\(obj.gridY))\(obj.isActive ? " *active*" : "")")
        }
        print()

        print("Sounds (\(scn.sounds.count)):")
        for snd in scn.sounds {
            print("  \(snd.name) → \(snd.file) type=\(snd.type)\(snd.isActive ? " *active*" : "")")
        }
        print()

        if !scn.textVariables.isEmpty {
            print("TextVariables:")
            for tv in scn.textVariables { print("  \(tv.name) → idx \(tv.index)") }
            print()
        }

        // Dump OB files
        let obEntries = container.entries.enumerated().filter { $0.element.name.uppercased().hasSuffix(".OB") }
        if !obEntries.isEmpty {
            print("=== Object Definitions (\(obEntries.count)) ===")
            for (i, _) in obEntries {
                let obData = try container.extractResource(at: i, decompressor: decompressor)
                let ob = ObjectDef(data: obData)
                var line = "  \(ob.name): z=\(ob.zCoord) cursor=\(ob.cursor) text=\(ob.textIndex)"
                if let fon = ob.fonScript { line += " fon=\(fon)" }
                if let az = ob.activeZone { line += " zone=(\(az.x),\(az.y),\(az.width),\(az.height))" }
                if !ob.closedVerts.isEmpty { line += " cverts=\(ob.closedVerts.count)" }
                if !ob.closedDirs.isEmpty { line += " cdirs=\(ob.closedDirs.count)" }
                print(line)
            }
            print()
        }

        // Summary of FS files
        let fsEntries = container.entries.filter { $0.name.uppercased().hasSuffix(".FS") }
        print("Frame Sequences: \(fsEntries.count)")
        for entry in fsEntries.prefix(10) {
            print("  \(entry.name) (\(entry.decompressedSize) bytes)")
        }
        if fsEntries.count > 10 { print("  ... and \(fsEntries.count - 10) more") }

    } catch {
        print("ERROR: \(error)")
    }
}

func dumpCharacter(datPath: String) {
    do {
        let container = try NLContainer(path: datPath)
        let decompressor = NGIDecompressor()
        let filename = (datPath as NSString).lastPathComponent

        guard let chrIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".CHR") }) else {
            print("ERROR: No .CHR found in \(filename)"); exit(1)
        }
        let chrData = try container.extractResource(at: chrIdx, decompressor: decompressor)
        let chr = CharacterConfig(data: chrData)

        print("=== \(chr.name) — Character ===")
        print("MoveType: \(chr.moveType)")
        print("FonScripts: \(chr.fonScripts.joined(separator: ", "))")
        if let lb = chr.lookBox {
            print("LookBox: (\(lb.x),\(lb.y),\(lb.width),\(lb.height))")
        }
        if !chr.items.isEmpty { print("Items: \(chr.items.joined(separator: ", "))") }
        if !chr.gridToClose.isEmpty {
            print("GridToClose: \(chr.gridToClose.map { "(\($0.x),\($0.y),\($0.dir))" }.joined(separator: " "))")
        }
        print()

        // LST
        if let lstIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".LST") }) {
            let lstData = try container.extractResource(at: lstIdx, decompressor: decompressor)
            let lst = AnimationList(data: lstData)
            print("Animation List: pattern=\"\(lst.pattern)\" (\(lst.entries.count) entries)")
            for e in lst.entries { print("  \(e)") }
            print()
        }

        // FS summary
        let fsEntries = container.entries.filter { $0.name.uppercased().hasSuffix(".FS") }
        print("Frame Sequences: \(fsEntries.count)")
        for entry in fsEntries.prefix(10) {
            print("  \(entry.name) (\(entry.decompressedSize) bytes)")
        }
        if fsEntries.count > 10 { print("  ... and \(fsEntries.count - 10) more") }

    } catch {
        print("ERROR: \(error)")
    }
}

func dumpFS(datPath: String, fsName: String) {
    do {
        let container = try NLContainer(path: datPath)
        let decompressor = NGIDecompressor()

        let searchName = fsName.uppercased().hasSuffix(".FS") ? fsName.uppercased() : fsName.uppercased() + ".FS"
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == searchName }) else {
            print("ERROR: \(fsName) not found"); exit(1)
        }

        let data = try container.extractResource(at: idx, decompressor: decompressor)
        let fs = FrameSequence(data: data)

        print("=== \(container.entries[idx].name) ===")
        print("Script: \(fs.scriptName)  Movie: \(fs.movieName)")
        print("Shift: (\(fs.shiftX),\(fs.shiftY))  TotalFrames: \(fs.totalFrames)")
        print()

        var indent = 0
        for cmd in fs.commands {
            let pad = String(repeating: "  ", count: indent)
            switch cmd {
            case .frame(let i, let d):
                print("\(pad)Frame \(i), delta=\(d)")
            case .delay(let ms):
                print("\(pad)  Delay \(ms)ms")
            case .sound(let name, let params):
                print("\(pad)  Sound \(name) [\(params.joined(separator: ","))]")
            case .text(let i, let p):
                print("\(pad)  Text #\(i) param=\(p)")
            case .aproach(let ch, let obj, let x, let y):
                print("\(pad)  Aproach \(ch) → \(obj) (\(x),\(y))")
            case .createObject(let sc, let obj, let ch, let x, let y):
                print("\(pad)  CreateObject \(sc).\(obj) char=\(ch) (\(x),\(y))")
            case .delObject(let sc, let obj, let ch, let x, let y):
                print("\(pad)  DelObject \(sc).\(obj) char=\(ch) (\(x),\(y))")
            case .shift(let t, let a, let v):
                print("\(pad)  Shift \(t).\(a) \(v)")
            case .set(let t, let a, let v):
                print("\(pad)  Set \(t).\(a) = \(v)")
            case .setVar(let n, let v):
                print("\(pad)  SetVar \(n) = \(v)")
            case .setCharVar(let n, let v):
                print("\(pad)  SetCharVar \(n) = \(v)")
            case .setRest(let ch, let p, let s):
                print("\(pad)  SetRest \(ch) \(p) → \(s)")
            case .setActive(let n):
                print("\(pad)  SetActive \(n)")
            case .lockBar(let s):
                print("\(pad)  LockBar \(s)")
            case .setMap(let s):
                print("\(pad)  SetMap \(s)")
            case .startGame(let n, let rv, let sv):
                print("\(pad)  StartGame \(n) → \(rv)/\(sv)")
            case .setVert(let x, let y, let st):
                print("\(pad)  SetVert (\(x),\(y)) \(st)")
            case .addItem(let n, let ch):
                print("\(pad)  AddItem \(n)\(ch.isEmpty ? "" : " → \(ch)")")
            case .deleteItem(let n, let ch):
                print("\(pad)  DeleteItem \(n)\(ch.isEmpty ? "" : " ← \(ch)")")
            case .showChar(let n):
                print("\(pad)  ShowChar \(n)")
            case .hideChar(let n):
                print("\(pad)  HideChar \(n)")
            case .goScene(let p):
                print("\(pad)  GoScene \(p.joined(separator: ", "))")
            case .setBar(let s):
                print("\(pad)  SetBar \(s)")
            case .setMouse(let s):
                print("\(pad)  SetMouse \(s)")
            case .setMusic(let n):
                print("\(pad)  SetMusic \(n)")
            case .ifCondition(let v, let val):
                print("\(pad)  If \(v) == \(val)")
                indent += 1
            case .shiftScreen(let dx, let dy):
                print("\(pad)  ShiftScreen (\(dx),\(dy))")
            case .endIf:
                indent = max(0, indent - 1)
                print("\(pad)  EndIf")
            }
        }
    } catch {
        print("ERROR: \(error)")
    }
}

func dumpStartup(datPath: String) {
    do {
        let container = try NLContainer(path: datPath)
        let decompressor = NGIDecompressor()

        guard let infIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "STARTUP.INF" }) else {
            print("ERROR: No STARTUP.INF found"); exit(1)
        }
        guard let txtIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "TEXT.DAT" }) else {
            print("ERROR: No TEXT.DAT found"); exit(1)
        }

        let infData = try container.extractResource(at: infIdx, decompressor: decompressor)
        let config = StartupConfig(data: infData)

        print("=== STARTUP.INF ===")
        print("Directories:")
        print("  Scene: \(config.sceneDirectory)")
        print("  Movie: \(config.movieDirectory)")
        print("  Wave:  \(config.waveDirectory)")
        print("  Char:  \(config.characterDirectory)")
        print("  Bar:   \(config.barDirectory)")
        print("  Text:  \(config.textFile)")
        print()

        print("Scenes (\(config.scenes.count)):")
        for s in config.scenes {
            print("  \(s.name)\(s.isStart ? " *START*" : "")")
        }
        print()

        print("Characters (\(config.characters.count)):")
        for c in config.characters {
            print("  \(c.name): dir=\(c.direction) grid=(\(c.gridX),\(c.gridY))\(c.isStart ? " *START*" : "")")
        }
        print()

        print("IntVariables (\(config.intVariables.count)):")
        for v in config.intVariables {
            print("  \(v.name) = \(v.value)")
        }
        print()

        print("CharVariables (\(config.charVariables.count)):")
        for v in config.charVariables {
            print("  \(v.name) → \(v.value)")
        }
        print()

        let txtData = try container.extractResource(at: txtIdx, decompressor: decompressor)
        let texts = TextDatabase(data: txtData)
        print("=== TEXT.DAT === (\(texts.strings.count) strings)")
        for (i, s) in texts.strings.enumerated() {
            print("  [\(String(format: "%3d", i))] \(s)")
        }
    } catch {
        print("ERROR: \(error)")
    }
}

func compositeTest(danPath: String, fsName: String, outDir: String) {
    do {
        let container = try NLContainer(path: danPath)
        let decompressor = NGIDecompressor()

        let searchName = fsName.uppercased().hasSuffix(".FS") ? fsName.uppercased() : fsName.uppercased() + ".FS"
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == searchName }) else {
            print("ERROR: \(fsName) not found in \(danPath)"); exit(1)
        }

        let fsData = try container.extractResource(at: idx, decompressor: decompressor)
        let fs = FrameSequence(data: fsData)
        print("FS: movie=\(fs.movieName), totalFrames=\(fs.totalFrames), shift=(\(fs.shiftX),\(fs.shiftY))")

        let basePath = (danPath as NSString).deletingLastPathComponent
        var mvPath = "\(basePath)/\(fs.movieName.uppercased())"
        if !FileManager.default.fileExists(atPath: mvPath) {
            let movieDir = basePath.hasSuffix("SCEN") ?
                (basePath as NSString).deletingLastPathComponent + "/MOVIE" : basePath
            mvPath = "\(movieDir)/\(fs.movieName.uppercased())"
        }

        let movie = try CompositeMovie(path: mvPath, decompressor: decompressor)
        print("Movie: canvas=\(movie.canvasWidth)x\(movie.canvasHeight), SCR frames=\(movie.scr.frameCount)")

        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var framesSeen = 0
        for cmd in fs.commands {
            guard case .frame(let index, let delta) = cmd else { continue }
            if delta == 0 { movie.clearCanvas() }
            _ = movie.applyFrame(logicalIndex: index)
            framesSeen += 1

            let cksum = movie.canvasChecksum()
            if framesSeen <= 5 || framesSeen % 10 == 1 {
                print("  frame \(index) (delta=\(delta)) canvas=\(String(format:"%08X",cksum))")
            }

            if framesSeen <= 5 || framesSeen % 10 == 0 || index == fs.totalFrames - 1 {
                if let img = movie.renderCanvas() {
                    let path = "\(outDir)/frame_\(String(format: "%03d", index)).png"
                    try PNGRenderer.writePNG(img, to: path)
                }
            }
        }
        print("Rendered \(framesSeen) frames to \(outDir)")
    } catch {
        print("ERROR: \(error)")
    }
}

func sceneOverlay(danPath: String, outDir: String) {
    do {
        let decompressor = NGIDecompressor()
        let sceneName = ((danPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let sceneDir = (danPath as NSString).deletingLastPathComponent
        let movieDir = (sceneDir as NSString).deletingLastPathComponent + "/MOVIE"
        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let container = try NLContainer(path: danPath)
        guard let scnIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCN") }) else {
            print("ERROR: No SCN"); exit(1)
        }
        let scnData = try container.extractResource(at: scnIdx, decompressor: decompressor)
        let config = SceneConfig(data: scnData)

        // Load background
        let bgDatPath = "\(sceneDir)/\(sceneName).DAT"
        let bgContainer = try NLContainer(path: bgDatPath)
        guard let bgNgbIdx = bgContainer.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".NGB") }) else {
            print("ERROR: No BG NGB"); exit(1)
        }
        guard let bgColIdx = bgContainer.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".COL") }) else {
            print("ERROR: No BG COL"); exit(1)
        }
        let bgNgbData = try bgContainer.extractResource(at: bgNgbIdx, decompressor: decompressor)
        let bgColData = try bgContainer.extractResource(at: bgColIdx, decompressor: decompressor)
        let bgNgb = try NGBImage(data: bgNgbData)
        let bgPal = try COLPalette(data: bgColData)
        guard let bgImage = PNGRenderer.render(ngb: bgNgb, palette: bgPal) else {
            print("ERROR: BG render"); exit(1)
        }
        let bgW = bgNgb.width, bgH = bgNgb.height

        for obj in config.objects {
            let obName = obj.name.uppercased() + ".OB"
            guard let obIdx = container.entries.firstIndex(where: { $0.name.uppercased() == obName }) else { continue }
            let obData = try container.extractResource(at: obIdx, decompressor: decompressor)
            let ob = ObjectDef(data: obData)
            guard let fonScript = ob.fonScript else { continue }

            let fsFile = fonScript.uppercased() + ".FS"
            guard let fsIdx = container.entries.firstIndex(where: { $0.name.uppercased() == fsFile }) else { continue }
            let fsData = try container.extractResource(at: fsIdx, decompressor: decompressor)
            let fs = FrameSequence(data: fsData)
            guard !fs.movieName.isEmpty else { continue }

            let mvPath = "\(movieDir)/\(fs.movieName.uppercased())"
            guard let movie = try? CompositeMovie(path: mvPath, decompressor: decompressor) else { continue }

            movie.clearCanvas()
            for cmd in fs.commands {
                if case .frame(let idx, let delta) = cmd {
                    if delta == 0 { movie.clearCanvas() }
                    _ = movie.applyFrame(logicalIndex: idx)
                    break
                }
            }
            guard let frameImg = movie.renderCanvas(transparentIndex: 0) else { continue }

            // Render two versions for this object
            for useGridShift in [true, false] {
                let gx: Int, gy: Int
                if useGridShift {
                    gx = config.leftTopGrid.0 + obj.gridX * config.gridSize.0 + config.gridShift.0
                    gy = config.leftTopGrid.1 + obj.gridY * config.gridSize.1 + config.gridShift.1
                } else {
                    gx = config.leftTopGrid.0 + obj.gridX * config.gridSize.0
                    gy = config.leftTopGrid.1 + obj.gridY * config.gridSize.1
                }
                let ox = gx - fs.shiftX
                let oy = gy - fs.shiftY

                guard let ctx = CGContext(data: nil, width: bgW, height: bgH,
                                           bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.draw(bgImage, in: CGRect(x: 0, y: 0, width: bgW, height: bgH))
                let cgY = bgH - oy - movie.canvasHeight
                ctx.draw(frameImg, in: CGRect(x: ox, y: cgY, width: movie.canvasWidth, height: movie.canvasHeight))

                // Draw crosshair at grid pixel position
                ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                ctx.setLineWidth(2)
                let crossY = bgH - gy
                ctx.move(to: CGPoint(x: gx - 10, y: crossY))
                ctx.addLine(to: CGPoint(x: gx + 10, y: crossY))
                ctx.move(to: CGPoint(x: gx, y: crossY - 10))
                ctx.addLine(to: CGPoint(x: gx, y: crossY + 10))
                ctx.strokePath()

                if let result = ctx.makeImage() {
                    let suffix = useGridShift ? "WITH" : "NO"
                    let name = "\(sceneName)_\(obj.name)_\(suffix).png"
                    try PNGRenderer.writePNG(result, to: "\(outDir)/\(name)")
                    print("\(name): origin=(\(ox),\(oy)) gridPx=(\(gx),\(gy))")
                }
            }
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

func scenePositions(danPath: String) {
    do {
        let decompressor = NGIDecompressor()
        let sceneName = ((danPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let sceneDir = (danPath as NSString).deletingLastPathComponent
        let movieDir = (sceneDir as NSString).deletingLastPathComponent + "/MOVIE"

        let container = try NLContainer(path: danPath)
        guard let scnIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCN") }) else {
            print("ERROR: No SCN in \(danPath)"); exit(1)
        }
        let scnData = try container.extractResource(at: scnIdx, decompressor: decompressor)
        let config = SceneConfig(data: scnData)

        // Load background size
        let bgDatPath = "\(sceneDir)/\(sceneName).DAT"
        var bgW = 0, bgH = 0
        if let bgContainer = try? NLContainer(path: bgDatPath),
           let bgIdx = bgContainer.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".NGB") }) {
            let bgData = try bgContainer.extractResource(at: bgIdx, decompressor: decompressor)
            if bgData.count >= 8 {
                bgW = Int(bgData.readInt16(at: 4)) - Int(bgData.readInt16(at: 0)) + 1
                bgH = Int(bgData.readInt16(at: 6)) - Int(bgData.readInt16(at: 2)) + 1
            }
        }

        print("=== \(sceneName) ===")
        print("Background: \(bgW)x\(bgH)")
        print("LeftTopGrid: (\(config.leftTopGrid.0), \(config.leftTopGrid.1))")
        print("GridSize: (\(config.gridSize.0), \(config.gridSize.1))")
        print("GridShift: (\(config.gridShift.0), \(config.gridShift.1))")
        print("GridLength: (\(config.gridLength.0), \(config.gridLength.1))")
        print("ScrollPar: (\(config.scrollPar.0), \(config.scrollPar.1))")
        print("Objects: \(config.objects.count)")
        print()

        for obj in config.objects {
            let obName = obj.name.uppercased() + ".OB"
            guard let obIdx = container.entries.firstIndex(where: { $0.name.uppercased() == obName }) else {
                print("  \(obj.name) grid(\(obj.gridX),\(obj.gridY)) — NO OB FILE")
                continue
            }
            let obData = try container.extractResource(at: obIdx, decompressor: decompressor)
            let ob = ObjectDef(data: obData)

            guard let fonScript = ob.fonScript else {
                print("  \(obj.name) grid(\(obj.gridX),\(obj.gridY)) — FonScript: NULL")
                continue
            }

            let fsFile = fonScript.uppercased() + ".FS"
            guard let fsIdx = container.entries.firstIndex(where: { $0.name.uppercased() == fsFile }) else {
                print("  \(obj.name) grid(\(obj.gridX),\(obj.gridY)) — FS \(fonScript) NOT FOUND")
                continue
            }
            let fsData = try container.extractResource(at: fsIdx, decompressor: decompressor)
            let fs = FrameSequence(data: fsData)

            // Load movie to get canvas size and first frame NGB rect
            var canvasW = 0, canvasH = 0
            var firstFrameRect = ""
            let mvPath = "\(movieDir)/\(fs.movieName.uppercased())"
            if let mvContainer = try? NLContainer(path: mvPath) {
                if let firstNgb = mvContainer.entries.first(where: { $0.name.uppercased().hasSuffix(".NGB") }) {
                    let ngbIdx = mvContainer.entries.firstIndex(where: { $0.name == firstNgb.name })!
                    let ngbData = try mvContainer.extractResource(at: ngbIdx, decompressor: decompressor)
                    if ngbData.count >= 8 {
                        let xL = Int(ngbData.readInt16(at: 0))
                        let yT = Int(ngbData.readInt16(at: 2))
                        let xR = Int(ngbData.readInt16(at: 4))
                        let yB = Int(ngbData.readInt16(at: 6))
                        canvasW = xR + 1
                        canvasH = yB + 1
                        firstFrameRect = "(\(xL),\(yT))-(\(xR),\(yB))"
                    }
                }
                // Also check SCR for canvas size
                if let scrIdx = mvContainer.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCR") }) {
                    let scrData = try mvContainer.extractResource(at: scrIdx, decompressor: decompressor)
                    if scrData.count >= 8 {
                        let scrW = Int(scrData.readUInt16(at: 4))
                        let scrH = Int(scrData.readUInt16(at: 6))
                        canvasW = scrW; canvasH = scrH
                    }
                }
            }

            // Compute positions
            let gridPixelX = config.leftTopGrid.0 + obj.gridX * config.gridSize.0 + config.gridShift.0
            let gridPixelY = config.leftTopGrid.1 + obj.gridY * config.gridSize.1 + config.gridShift.1
            let originWithX = gridPixelX - fs.shiftX
            let originWithY = gridPixelY - fs.shiftY

            let gridPixelNoShiftX = config.leftTopGrid.0 + obj.gridX * config.gridSize.0
            let gridPixelNoShiftY = config.leftTopGrid.1 + obj.gridY * config.gridSize.1
            let originNoX = gridPixelNoShiftX - fs.shiftX
            let originNoY = gridPixelNoShiftY - fs.shiftY

            print("  \(obj.name) grid(\(obj.gridX),\(obj.gridY)) active=\(obj.isActive)")
            print("    FonScript: \(fonScript)  Movie: \(fs.movieName) \(canvasW)x\(canvasH)")
            print("    FS Shift: (\(fs.shiftX), \(fs.shiftY))  FirstFrameRect: \(firstFrameRect)")
            print("    WITH gridShift: gridPx=(\(gridPixelX),\(gridPixelY)) origin=(\(originWithX),\(originWithY))")
            print("    NO   gridShift: gridPx=(\(gridPixelNoShiftX),\(gridPixelNoShiftY)) origin=(\(originNoX),\(originNoY))")
            if ob.activeZone != nil {
                let az = ob.activeZone!
                print("    ActiveZone: (\(az.x),\(az.y),\(az.width),\(az.height))")
            }
            print()
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

func ngbDiag(mvPath: String) {
    do {
        let container = try NLContainer(path: mvPath)
        let decompressor = NGIDecompressor()

        for (i, entry) in container.entries.enumerated() {
            guard entry.name.uppercased().hasSuffix(".NGB") else { continue }
            let data = try container.extractResource(at: i, decompressor: decompressor)
            guard data.count >= 8 else { continue }

            let xL = Int(data.readInt16(at: 0))
            let yT = Int(data.readInt16(at: 2))
            let xR = Int(data.readInt16(at: 4))
            let yB = Int(data.readInt16(at: 6))
            let w = xR - xL + 1
            let h = yB - yT + 1

            let rawPixels = w * h
            let rawSize8 = 8 + rawPixels
            let rawSize16 = 16 + rawPixels

            var hexDump = ""
            for b in 0..<min(24, data.count) {
                hexDump += String(format: "%02X ", data[data.startIndex + b])
            }

            var encoding = "?"
            if data.count == rawSize8 { encoding = "RAW(hdr=8)" }
            else if data.count == rawSize16 { encoding = "RAW(hdr=16)" }
            else if data.count > rawSize16 { encoding = "RAW?(surplus=\(data.count - rawSize16))" }
            else if data.count >= 8 + h * 4 { encoding = "RLE(rowTbl=\(h*4)b data=\(data.count)b)" }
            else { encoding = "UNKNOWN" }

            print("[\(i)] \(entry.name) size=\(data.count) rect=(\(xL),\(yT))-(\(xR),\(yB)) \(w)x\(h) raw8=\(rawSize8) raw16=\(rawSize16) → \(encoding)")
            if i < 5 || encoding.contains("surplus") || encoding.contains("UNKNOWN") {
                print("     hex: \(hexDump)")
            }
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

func cutsceneTest(danPath: String, fsName: String, outDir: String) {
    do {
        let container = try NLContainer(path: danPath)
        let decompressor = NGIDecompressor()

        let searchName = fsName.uppercased().hasSuffix(".FS") ? fsName.uppercased() : fsName.uppercased() + ".FS"
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == searchName }) else {
            print("ERROR: \(fsName) not found in \(danPath)"); exit(1)
        }

        let fsData = try container.extractResource(at: idx, decompressor: decompressor)
        let fs = FrameSequence(data: fsData)
        print("FS: script=\(fs.scriptName) movie=\(fs.movieName) totalFrames=\(fs.totalFrames) shift=(\(fs.shiftX),\(fs.shiftY))")
        print("Commands: \(fs.commands.count) total")

        let basePath = (danPath as NSString).deletingLastPathComponent
        var mvPath = "\(basePath)/\(fs.movieName.uppercased())"
        if !FileManager.default.fileExists(atPath: mvPath) {
            let movieDir = basePath.hasSuffix("SCEN") ?
                (basePath as NSString).deletingLastPathComponent + "/MOVIE" : basePath
            mvPath = "\(movieDir)/\(fs.movieName.uppercased())"
        }

        let movie = try CompositeMovie(path: mvPath, decompressor: decompressor)
        print("Movie: canvas=\(movie.canvasWidth)x\(movie.canvasHeight) SCR frames=\(movie.scr.frameCount)")
        print("SCR: delay=\(movie.scr.defaultDelayMs)ms screen=\(movie.scr.screenWidth)x\(movie.scr.screenHeight) shift=(\(movie.scr.shiftX),\(movie.scr.shiftY))")

        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var frameNum = 0
        var cmdNum = 0
        movie.clearCanvas()

        for cmd in fs.commands {
            cmdNum += 1
            switch cmd {
            case .frame(let index, let delta):
                if delta == 0 {
                    movie.clearCanvas()
                }
                let applied = movie.applyFrame(logicalIndex: index)

                guard let imgTransparent = movie.renderCanvas(transparentIndex: 0) else {
                    print("  [!] frame \(index) renderCanvas(transparent) returned nil")
                    frameNum += 1
                    continue
                }
                guard let imgOpaque = movie.renderCanvas() else {
                    print("  [!] frame \(index) renderCanvas(opaque) returned nil")
                    frameNum += 1
                    continue
                }

                let cksum = movie.canvasChecksum()
                let w = imgTransparent.width
                let h = imgTransparent.height
                let bpr = imgTransparent.bytesPerRow
                let bpp = imgTransparent.bitsPerPixel
                let expectedBpr = w * 4

                var status = "OK"
                if bpr != expectedBpr {
                    status = "STRIDE_MISMATCH(expected=\(expectedBpr) actual=\(bpr))"
                }
                if !applied {
                    status += " NGB_MISS"
                }

                let pathT = "\(outDir)/frame_\(String(format: "%04d", frameNum))_t.png"
                try PNGRenderer.writePNG(imgTransparent, to: pathT)

                if frameNum < 5 || frameNum % 50 == 0 || status != "OK" {
                    let pathO = "\(outDir)/frame_\(String(format: "%04d", frameNum))_o.png"
                    try PNGRenderer.writePNG(imgOpaque, to: pathO)
                }

                print("  frame[\(frameNum)] idx=\(index) delta=\(delta) \(w)x\(h) bpr=\(bpr) bpp=\(bpp) cksum=\(String(format:"%08X",cksum)) \(status)")
                frameNum += 1

            case .delay(let ms):
                break

            default:
                break
            }
        }
        print("\nTotal: \(frameNum) frames rendered to \(outDir)")
        print("Canvas size: \(movie.canvasWidth)x\(movie.canvasHeight)")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: RobyTool <command> [args...]")
    print("  list <path.DAT>")
    print("  extractall <path.DAT> <outdir> [maxcount]")
    print("  render <path.DAT> <outdir>")
    print("  dump startup <STARTUP.DAN>")
    print("  dump scene <SCENA*.DAN>")
    print("  dump character <ROBY.DAN|FRID.DAN>")
    print("  dump fs <path.DAN> <NAME.FS>")
    print("  composite <path.DAN> <NAME.FS> <outdir>")
    print("  cutscenetest <path.DAN> <NAME.FS> <outdir>")
    exit(1)
}

switch args[1] {
case "list":
    guard args.count >= 3 else { print("Usage: list <path>"); exit(1) }
    listResources(path: args[2])

case "extractall":
    guard args.count >= 4 else { print("Usage: extractall <dat> <outdir> [max]"); exit(1) }
    let max = args.count >= 5 ? (Int(args[4]) ?? Int.max) : Int.max
    extractAll(datPath: args[2], outDir: args[3], maxCount: max)

case "render":
    guard args.count >= 4 else { print("Usage: render <dat> <outdir>"); exit(1) }
    renderAll(datPath: args[2], outDir: args[3])

case "dump":
    guard args.count >= 4 else { print("Usage: dump <type> <path>"); exit(1) }
    switch args[2] {
    case "startup":
        dumpStartup(datPath: args[3])
    case "scene":
        dumpScene(datPath: args[3])
    case "character":
        dumpCharacter(datPath: args[3])
    case "fs":
        guard args.count >= 5 else { print("Usage: dump fs <path.DAN> <NAME.FS>"); exit(1) }
        dumpFS(datPath: args[3], fsName: args[4])
    default:
        print("Unknown dump type: \(args[2]). Available: startup, scene, character, fs")
        exit(1)
    }

case "composite":
    guard args.count >= 5 else { print("Usage: composite <path.DAN> <NAME.FS> <outdir>"); exit(1) }
    compositeTest(danPath: args[2], fsName: args[3], outDir: args[4])

case "cutscenetest":
    guard args.count >= 5 else { print("Usage: cutscenetest <path.DAN> <NAME.FS> <outdir>"); exit(1) }
    cutsceneTest(danPath: args[2], fsName: args[3], outDir: args[4])

case "ngbdiag":
    guard args.count >= 3 else { print("Usage: ngbdiag <path.MV>"); exit(1) }
    ngbDiag(mvPath: args[2])

case "scenepos":
    guard args.count >= 3 else { print("Usage: scenepos <path.DAN>"); exit(1) }
    scenePositions(danPath: args[2])

case "overlay":
    guard args.count >= 4 else { print("Usage: overlay <path.DAN> <outdir>"); exit(1) }
    sceneOverlay(danPath: args[2], outDir: args[3])

default:
    print("Unknown command: \(args[1])")
    exit(1)
}
