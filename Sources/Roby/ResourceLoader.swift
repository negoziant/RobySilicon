import Foundation
import CoreGraphics
import ResourceKit
import SpriteKit

final class ResourceLoader {
    let gameDataPath: String
    private let decompressor = NGIDecompressor()

    struct RenderedFrame {
        let texture: SKTexture
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    // Кэш пре-рендеренных анимаций: ходьба гоняет одни и те же rg_* MV на
    // каждый шаг — без кэша каждый шаг распаковывал Huffman и рисовал кадры
    private var frameCache: [String: [RenderedFrame]] = [:]

    func renderedFrames(fs: FrameSequence, cacheKey: String, palette: COLPalette?) throws -> [RenderedFrame] {
        if let cached = frameCache[cacheKey] { return cached }
        let movie = try loadCompositeMovie(named: fs.movieName)
        if let pal = palette { movie.setPalette(pal) }
        var frames: [RenderedFrame] = []
        for cmd in fs.commands {
            if case .frame(let index, _) = cmd {
                movie.clearCanvas()
                if movie.applyFrame(logicalIndex: index),
                   let r = movie.renderCanvasCropped() {
                    let tex = SKTexture(cgImage: r.image)
                    tex.filteringMode = .nearest
                    frames.append(RenderedFrame(texture: tex, offsetX: CGFloat(r.x), offsetY: CGFloat(r.y)))
                } else if let last = frames.last {
                    frames.append(last) // пропуск SCR — удержание кадра
                }
            }
        }
        frameCache[cacheKey] = frames
        return frames
    }

    func clearFrameCache() {
        frameCache.removeAll()
    }

    init() {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/GameData/DATA",
            Bundle.main.bundlePath + "/../GameData/DATA",
            NSString(string: "~/Desktop/Develop/Roby/GameData/DATA").expandingTildeInPath,
        ]
        let found = candidates.first { FileManager.default.fileExists(atPath: $0) }
        gameDataPath = found ?? candidates[0]
        if found == nil {
            fputs("[ResourceLoader] WARNING: GameData not found at any candidate path\n", stderr)
        }
    }

    func loadScene(named name: String) throws -> (ngb: NGBImage, palette: COLPalette, fad: FADTable) {
        let datPath = "\(gameDataPath)/SCEN/\(name).DAT"
        let container = try NLContainer(path: datPath)

        guard let ngbIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".NGB") }),
              let colIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".COL") }),
              let fadIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".FAD") })
        else {
            throw LoaderError.missingResource("NGB/COL/FAD in \(name).DAT")
        }

        let ngbData = try container.extractResource(at: ngbIdx, decompressor: decompressor)
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)
        let fadData = try container.extractResource(at: fadIdx, decompressor: decompressor)

        let ngb = try NGBImage(data: ngbData)
        let palette = try COLPalette(data: colData)
        let fad = try FADTable(data: fadData)

        return (ngb, palette, fad)
    }

    func loadSceneConfig(named name: String) throws -> SceneConfig {
        let danPath = "\(gameDataPath)/SCEN/\(name).DAN"
        let container = try NLContainer(path: danPath)
        guard let scnIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".SCN") }) else {
            throw LoaderError.missingResource("SCN in \(name).DAN")
        }
        let data = try container.extractResource(at: scnIdx, decompressor: decompressor)
        return SceneConfig(data: data)
    }

    func loadStartup() throws -> (config: StartupConfig, texts: TextDatabase) {
        let danPath = "\(gameDataPath)/STARTUP.DAN"
        let container = try NLContainer(path: danPath)

        guard let infIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "STARTUP.INF" }),
              let txtIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "TEXT.DAT" })
        else {
            throw LoaderError.missingResource("STARTUP.INF/TEXT.DAT")
        }

        let infData = try container.extractResource(at: infIdx, decompressor: decompressor)
        let txtData = try container.extractResource(at: txtIdx, decompressor: decompressor)

        return (StartupConfig(data: infData), TextDatabase(data: txtData))
    }

    func loadBarBackground() throws -> (ngb: NGBImage, palette: COLPalette) {
        let datPath = "\(gameDataPath)/BAR/BAR.DAT"
        let container = try NLContainer(path: datPath)

        guard let ngbIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "BAR0.NGB" }),
              let colIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "BAR.COL" })
        else {
            throw LoaderError.missingResource("BAR0.NGB/BAR.COL in BAR.DAT")
        }

        let ngbData = try container.extractResource(at: ngbIdx, decompressor: decompressor)
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)

        return (try NGBImage(data: ngbData), try COLPalette(data: colData))
    }

    func loadBarSprite(index: Int) throws -> (ngb: NGBImage, palette: COLPalette) {
        let datPath = "\(gameDataPath)/BAR/BAR.DAT"
        let container = try NLContainer(path: datPath)

        let name = "BAR\(index).NGB"
        guard let ngbIdx = container.entries.firstIndex(where: { $0.name.uppercased() == name.uppercased() }),
              let colIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "BAR.COL" })
        else {
            throw LoaderError.missingResource("\(name) in BAR.DAT")
        }

        let ngbData = try container.extractResource(at: ngbIdx, decompressor: decompressor)
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)

        return (try NGBImage(data: ngbData), try COLPalette(data: colData))
    }

    func loadBarConfig() throws -> BarConfig {
        let danPath = "\(gameDataPath)/BAR/BAR.DAN"
        let container = try NLContainer(path: danPath)
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == "BAR.BAR" }) else {
            throw LoaderError.missingResource("BAR.BAR in BAR.DAN")
        }
        let data = try container.extractResource(at: idx, decompressor: decompressor)
        return BarConfig(data: data)
    }

    func loadObjectDefs(forScene name: String) throws -> [String: ObjectDef] {
        let danPath = "\(gameDataPath)/SCEN/\(name).DAN"
        let container = try NLContainer(path: danPath)
        var defs: [String: ObjectDef] = [:]
        for (i, entry) in container.entries.enumerated() {
            guard entry.name.uppercased().hasSuffix(".OB") else { continue }
            let data = try container.extractResource(at: i, decompressor: decompressor)
            let ob = ObjectDef(data: data)
            let key = entry.name.uppercased().replacingOccurrences(of: ".OB", with: "").lowercased()
            defs[key] = ob
        }
        return defs
    }

    func loadFrameSequence(named fsName: String, forScene sceneName: String) throws -> FrameSequence? {
        let danPath = "\(gameDataPath)/SCEN/\(sceneName).DAN"
        let container = try NLContainer(path: danPath)
        let target = fsName.uppercased() + ".FS"
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == target }) else {
            return nil
        }
        let data = try container.extractResource(at: idx, decompressor: decompressor)
        return FrameSequence(data: data)
    }

    func loadMVMovie(named mvName: String) throws -> MVMovie {
        var name = mvName
        if !name.uppercased().hasSuffix(".MV") { name += ".MV" }
        let path = "\(gameDataPath)/MOVIE/\(name.uppercased())"
        return try MVMovie(path: path, decompressor: decompressor)
    }

    func loadCompositeMovie(named mvName: String) throws -> CompositeMovie {
        var name = mvName
        if !name.uppercased().hasSuffix(".MV") { name += ".MV" }
        let path = "\(gameDataPath)/MOVIE/\(name.uppercased())"
        return try CompositeMovie(path: path, decompressor: decompressor)
    }

    func loadCharacterConfig(name: String) throws -> CharacterConfig {
        let danPath = "\(gameDataPath)/CHAR/\(name.uppercased()).DAN"
        let container = try NLContainer(path: danPath)
        guard let chrIdx = container.entries.firstIndex(where: { $0.name.uppercased().hasSuffix(".CHR") }) else {
            throw LoaderError.missingResource("CHR in \(name).DAN")
        }
        let data = try container.extractResource(at: chrIdx, decompressor: decompressor)
        return CharacterConfig(data: data)
    }

    func loadWalkingMap(name: String) throws -> WalkingAnimationMap {
        let danPath = "\(gameDataPath)/CHAR/\(name.uppercased()).DAN"
        let container = try NLContainer(path: danPath)
        guard let lstIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "DO.LST" }) else {
            throw LoaderError.missingResource("DO.LST in \(name).DAN")
        }
        let data = try container.extractResource(at: lstIdx, decompressor: decompressor)
        let list = AnimationList(data: data)
        return WalkingAnimationMap(animationList: list)
    }

    // Idle-скрипты: сцена может переопределять fon-анимацию персонажа
    // файлом "D"+имя в своём DAN (DROBY1.FS в SCENA0 — «Я пить хочу...»),
    // иначе играется базовая из CHAR DAN
    func loadIdleFS(named fsName: String, charName: String, sceneName: String) throws -> FrameSequence? {
        if !sceneName.isEmpty,
           let sceneFS = (try? loadFrameSequence(named: "D" + fsName, forScene: sceneName)) ?? nil {
            return sceneFS
        }
        return try loadCharacterFS(named: fsName, charName: charName)
    }

    func loadCharacterFS(named fsName: String, charName: String) throws -> FrameSequence? {
        let danPath = "\(gameDataPath)/CHAR/\(charName.uppercased()).DAN"
        let container = try NLContainer(path: danPath)
        let target = fsName.uppercased() + ".FS"
        guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == target }) else {
            return nil
        }
        let data = try container.extractResource(at: idx, decompressor: decompressor)
        return FrameSequence(data: data)
    }

    func loadAllBarSprites() throws -> (sprites: [Int: CGImage], palette: COLPalette) {
        let datPath = "\(gameDataPath)/BAR/BAR.DAT"
        let container = try NLContainer(path: datPath)

        guard let colIdx = container.entries.firstIndex(where: { $0.name.uppercased() == "BAR.COL" }) else {
            throw LoaderError.missingResource("BAR.COL in BAR.DAT")
        }
        let colData = try container.extractResource(at: colIdx, decompressor: decompressor)
        let palette = try COLPalette(data: colData)

        var sprites: [Int: CGImage] = [:]
        for i in 0...82 {
            let name = "BAR\(i).NGB"
            guard let idx = container.entries.firstIndex(where: { $0.name.uppercased() == name.uppercased() }) else { continue }
            let data = try container.extractResource(at: idx, decompressor: decompressor)
            let ngb = try NGBImage(data: data)
            if let img = PNGRenderer.render(ngb: ngb, palette: palette, transparentIndex: 0) {
                sprites[i] = img
            }
        }

        return (sprites, palette)
    }
}

enum LoaderError: Error, CustomStringConvertible {
    case missingResource(String)

    var description: String {
        switch self {
        case .missingResource(let s): return "Missing resource: \(s)"
        }
    }
}
