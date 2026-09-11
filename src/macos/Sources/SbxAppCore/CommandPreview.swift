import SbxKit

/// Ports src/electron/public/app.js's refreshCommand (360-392): a rendered
/// command, or the single message reachable in practice — "At least one
/// editable workspace is required." — since overlap is prevented at click
/// time and buildArgs never validates the template.
public enum CommandPreview: Sendable, Equatable {
    case ready(display: String)
    case unavailable(message: String)
}
