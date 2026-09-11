/// A user-facing banner message for a degraded config load, or nil when the
/// config loaded cleanly. Composed from `ConfigStore`'s three degradation
/// signals (`loadError`, `droppedPresets`, `hadUnrecoverableFieldShape`).
///
/// Note: the Electron app has no equivalent of this banner (`app.js`,
/// `index.html`, `styles.css`, `config.mjs` and `server.mjs` all lack any
/// `configError`/banner surface) — this is a new UI element PLAN.md asks
/// for, not a straight port.
public func configBannerMessage(
    loadError: String?, droppedPresets: Int, hadUnrecoverableFieldShape: Bool
) -> String? {
    var parts: [String] = []
    if let loadError {
        parts.append("Config file could not be read (\(loadError)) — using defaults.")
    }
    if hadUnrecoverableFieldShape {
        parts.append("Some config fields had an unexpected shape and were reset to defaults.")
    }
    if droppedPresets > 0 {
        let noun = droppedPresets == 1 ? "preset" : "presets"
        let verb = droppedPresets == 1 ? "was" : "were"
        parts.append("\(droppedPresets) \(noun) \(verb) dropped as malformed.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
