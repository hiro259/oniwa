/// Focus restoration is only valid for the visible, key search palette.
/// In particular, it must never pull keyboard input out of an editor sheet.
public enum PaletteFocusPolicy {
    public static func shouldRestoreSearchFocus(
        isVisible: Bool,
        isKeyWindow: Bool,
        isEditingSpace: Bool,
        isEditingPair: Bool
    ) -> Bool {
        isVisible && isKeyWindow && !isEditingSpace && !isEditingPair
    }
}
