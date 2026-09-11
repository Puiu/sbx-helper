/// The two states a Builder-tree folder can carry when selected — the third
/// state (unselected) is the absence of an entry in `BuilderModel.selection`,
/// mirroring src/electron/public/app.js's `Map<path, 'editable'|'readonly'>`
/// (there is no stored value for "off").
public enum SelectionKind: String, Sendable, Equatable, CaseIterable {
    case editable
    case readOnly
}
