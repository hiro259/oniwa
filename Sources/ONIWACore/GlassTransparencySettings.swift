import Foundation

/// Controls how much of the wallpaper is visible through the macOS Native
/// palette's ultra-thin material. This affects visuals only, never switching.
public enum GlassTransparencySettings {
    public static let settingsKey = "oniwa.nativeGlassTransparencyPercent"
    // A 20% transparency setting closely matches the legible glass look
    // tested on real Macs in both Light and Dark appearances.
    public static let defaultPercent = 20

    public static func clamped(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    public static func selected(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: settingsKey) != nil else {
            return defaultPercent
        }
        return clamped(defaults.integer(forKey: settingsKey))
    }

    public static func persist(_ value: Int, in defaults: UserDefaults = .standard) {
        defaults.set(clamped(value), forKey: settingsKey)
    }

    /// The semantic system background covers the material in inverse
    /// proportion to the chosen transparency; 0% is opaque, 100% is raw glass.
    /// When Increased Contrast is enabled, readability always takes priority.
    public static func backgroundOpacity(percent: Int, increasedContrast: Bool) -> Double {
        let opacity = 1.0 - Double(clamped(percent)) / 100.0
        return increasedContrast ? max(0.94, opacity) : opacity
    }
}
