import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import ONIWACore

/// The Accessibility and Core Graphics posting checks are intentionally separate.
/// A macOS privacy row can appear enabled while keyboard-event posting is still denied,
/// especially after switching between development and Developer ID-signed copies.
@MainActor
final class PermissionSetupModel: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postingGranted = false

    var ready: Bool { accessibilityGranted && postingGranted }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        postingGranted = CGPreflightPostEventAccess()
    }
}

@MainActor
final class PermissionSetupController: NSObject, NSWindowDelegate {
    private let model = PermissionSetupModel()
    private var window: NSWindow?

    static var needsSetup: Bool {
        !AXIsProcessTrusted() || !CGPreflightPostEventAccess()
    }

    func show() {
        model.refresh()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PermissionSetupView(
            model: model,
            onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
            onRecheck: { [weak self] in self?.model.refresh() },
            onClose: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLanguage.ui("ONIWAの権限設定", "ONIWA permissions")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible() {
        if window?.isVisible == true {
            model.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func openAccessibilitySettings() {
        // This deep link opens Privacy & Security > Accessibility on current macOS.
        // The visible instructions remain usable if macOS changes the deep link.
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionSetupView: View {
    @ObservedObject var model: PermissionSetupModel
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void
    let onClose: () -> Void

    private func t(_ ja: String, _ en: String) -> String {
        AppLanguage.ui(ja, en)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: model.ready ? "checkmark.shield" : "keyboard.badge.ellipsis")
                    .font(.system(size: 30))
                    .foregroundStyle(model.ready ? Color.green : Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("ONIWAを使うための準備", "Set up ONIWA"))
                        .font(.title2.weight(.semibold))
                    Text(t("Space切替に必要なmacOSの許可を確認します。",
                           "Check the macOS permissions needed to switch Spaces."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            permissionRow(
                t("アクセシビリティ", "Accessibility"),
                granted: model.accessibilityGranted
            )
            permissionRow(
                t("キー操作の送信", "Keyboard event posting"),
                granted: model.postingGranted
            )

            if model.ready {
                Text(t("準備完了です。ONIWAでSpaceを切り替えられます。",
                       "Permissions granted. ONIWA is ready to switch Spaces."))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("1.「システム設定を開く」を押します。",
                           "1. Click Open System Settings."))
                    Text(t("2.「プライバシーとセキュリティ → アクセシビリティ」でONIWAをONにします。",
                           "2. In Privacy & Security → Accessibility, enable ONIWA."))
                    Text(t("3. ONIWAに戻り「再確認」を押します。反映されない場合は再起動してください。",
                           "3. Return to ONIWA and click Recheck. Restart ONIWA if needed."))
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t("現在起動しているONIWA", "Current ONIWA application"))
                    .font(.caption.weight(.semibold))
                Text(Bundle.main.bundlePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text(t("以前の開発版などが登録されている場合、古いONIWAをアクセシビリティの一覧から削除し、上記のアプリを登録してください。許可が残っているように見えても、新しいアプリでは使えない場合があります。",
                       "If an older development copy remains in Accessibility settings, remove the old ONIWA entry and add the app shown above. An existing approval may not apply to this copy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button(t("閉じる", "Close"), action: onClose)
                Spacer()
                Button(t("再確認", "Recheck"), action: onRecheck)
                Button(t("システム設定を開く", "Open System Settings"), action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.ready)
            }
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
    }

    private func permissionRow(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(label)
            Spacer()
            Text(granted ? t("許可済み", "Granted") : t("未許可", "Not granted"))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.subheadline.weight(.medium))
        }
    }
}
