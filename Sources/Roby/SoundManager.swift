import AVFoundation
import Foundation
import ResourceKit

/// Все звуки игры лежат в WAVE.DAN несжатыми (fl=0x0000): 1050 WAV,
/// включая музыку MUSIC0-2.WAV. Загрузка — прямое извлечение по имени.
final class SoundManager {
    private var waveContainer: NLContainer?
    private var miniGameWaves: NLContainer? // MINIGAME.WDT — банк звуков мини-игр
    private let decompressor = NGIDecompressor()
    private var dataCache: [String: Data] = [:]

    private var effectPlayers: [AVAudioPlayer] = []
    private var musicPlayer: AVAudioPlayer?
    private var ambientPlayer: AVAudioPlayer?
    private(set) var currentMusicName = ""

    init(gameDataPath: String) {
        do {
            waveContainer = try NLContainer(path: gameDataPath + "/WAVE/WAVE.DAN")
            fputs("[Sound] WAVE.DAN: \(waveContainer?.entries.count ?? 0) ресурсов\n", stderr)
        } catch {
            fputs("[Sound] WAVE.DAN не открылся: \(error)\n", stderr)
        }
        miniGameWaves = try? NLContainer(path: gameDataPath + "/../MINIGAME.WDT")
        fputs("[Sound] MINIGAME.WDT: \(miniGameWaves?.entries.count ?? 0) ресурсов\n", stderr)
        sliderPath = gameDataPath + "/SLIDER.WAV"
    }

    private func waveData(file: String) -> Data? {
        var key = file.uppercased()
        if !key.hasSuffix(".WAV") { key += ".WAV" }
        if let d = dataCache[key] { return d }
        for c in [waveContainer, miniGameWaves].compactMap({ $0 }) {
            if let idx = c.entries.firstIndex(where: { $0.name.uppercased() == key }),
               let d = try? c.extractResource(at: idx, decompressor: decompressor) {
                dataCache[key] = d
                return d
            }
        }
        return nil
    }

    func playEffect(file: String) {
        guard let d = waveData(file: file) else {
            fputs("[Sound] не найден: \(file)\n", stderr)
            return
        }
        guard let p = try? AVAudioPlayer(data: d) else { return }
        p.volume = GameSettings.effectsVolume
        effectPlayers.removeAll { !$0.isPlaying }
        effectPlayers.append(p)
        p.play()
    }

    // Звук ползунка настроек — отдельный файл DATA/SLIDER.WAV (не в контейнере)
    private var sliderPlayer: AVAudioPlayer?
    private var sliderPath: String?

    func playSlider() {
        if sliderPlayer == nil, let path = sliderPath {
            sliderPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        }
        guard let p = sliderPlayer, !p.isPlaying else { return }
        p.volume = GameSettings.effectsVolume
        p.play()
    }

    // Ползунки меню: применить громкость к уже играющим дорожкам
    func refreshVolumes() {
        musicPlayer?.volume = GameSettings.musicVolume
        ambientPlayer?.volume = GameSettings.musicVolume * 0.7
    }

    func playMusic(name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.lowercased() != "continue" else { return }
        if clean.lowercased() == "none" {
            stopMusic()
            return
        }
        guard currentMusicName.lowercased() != clean.lowercased() else { return }
        guard let d = waveData(file: clean), let p = try? AVAudioPlayer(data: d) else {
            fputs("[Sound] музыка не найдена: \(clean)\n", stderr)
            return
        }
        musicPlayer?.stop()
        p.numberOfLoops = -1
        p.volume = GameSettings.musicVolume
        p.play()
        musicPlayer = p
        currentMusicName = clean
        fputs("[Sound] музыка → \(clean)\n", stderr)
    }

    func stopMusic() {
        musicPlayer?.stop()
        musicPlayer = nil
        currentMusicName = ""
    }

    // Фоновый звук сцены (SoundVariables type=5 *active*)
    func playAmbient(file: String) {
        ambientPlayer?.stop()
        guard let d = waveData(file: file), let p = try? AVAudioPlayer(data: d) else { return }
        p.numberOfLoops = -1
        p.volume = GameSettings.musicVolume * 0.7
        p.play()
        ambientPlayer = p
    }

    func stopAmbient() {
        ambientPlayer?.stop()
        ambientPlayer = nil
    }
}
