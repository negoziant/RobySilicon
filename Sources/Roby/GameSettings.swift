import Foundation

/// Настройки трёх ползунков меню «Опции» (Звук/Музыка/Скорость), 0..1.
/// Скорость мапится в множитель темпа анимаций 0.5..1.5.
enum GameSettings {
    private static let defaults = UserDefaults.standard

    static var effectsVolume: Float {
        get { value("effectsVolume", 0.6) }
        set { defaults.set(newValue, forKey: "effectsVolume") }
    }

    static var musicVolume: Float {
        get { value("musicVolume", 0.6) }
        set { defaults.set(newValue, forKey: "musicVolume") }
    }

    static var gameSpeed: Float {
        get { value("gameSpeed", 0.5) }
        set { defaults.set(newValue, forKey: "gameSpeed") }
    }

    /// Множитель темпа: задержки кадров делятся на него
    static var speedFactor: Double { 0.5 + Double(gameSpeed) }

    private static func value(_ key: String, _ def: Float) -> Float {
        defaults.object(forKey: key) == nil ? def : defaults.float(forKey: key)
    }
}
