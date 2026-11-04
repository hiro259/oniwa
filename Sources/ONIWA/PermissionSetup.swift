import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import ONIWACore

/// Two system checks, but only one user-facing permission to configure.
/// A previously approved copy can have Accessibility access while keyboard
/// posting is denied after the executable's path or signature changes.
@MainActor
final class PermissionSetupModel: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postingPermissionGranted = false
    @Published private(set) var verifiedActualSwitch = false

    /// Both checks must pass before switching is expected to work.
    var ready: Bool { accessibilityGranted && postingPermissionGranted }

    /// Not an additional permission: records a *successful* Space transition.
    func markSuccessfulSwitch() {
        verifiedActualSwitch = true
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        postingPermissionGranted = CGPreflightPostEventAccess()
    }
}

@MainActor
final class PermissionSetupController: NSObject, NSWindowDelegate {
    private let model = PermissionSetupModel()
    private var window: NSWindow?

    static var needsSetup: Bool {
        !AXIsProcessTrusted() || !CGPreflightPostEventAccess()
    }

    /// An app launched from Downloads/build is more likely to be replaced or
    /// confused with an old copy in macOS Privacy & Security settings.
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(userApplications + "/")
    }

    func recordSuccessfulSwitch() {
        model.markSuccessfulSwitch()
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
            isInApplications: Self.isInApplications,
            onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
            onRecheck: { [weak self] in self?.model.refresh() },
            onRevealApp: { [weak self] in self?.revealRunningApp() },
            onOpenApplications: { [weak self] in self?.openApplicationsFolder() },
            onClose: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 465),
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
        // Deep link opens Privacy & Security > Accessibility. Instructions
        // remain visible in case a future macOS version changes this URL.
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }
}

private struct PermissionSetupView: View {
    @ObservedObject var model: PermissionSetupModel
    let isInApplications: Bool
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void
    let onRevealApp: () -> Void
    let onOpenApplications: () -> Void
    let onClose: () -> Void

    private func t(_ ja: String, _ en: String) -> String {
        AppLanguage.ui(ja, en)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: model.ready ? "checkmark.shield" : "keyboard.badge.ellipsis")
                    .font(.system(size: 28))
                    .foregroundStyle(model.ready ? Color.green : Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("ONIWAを使うための準備", "Set up ONIWA"))
                        .font(.title2.weight(.semibold))
                    Text(t("Space切替のためにアクセシビリティを許可してください。",
                           "Allow Accessibility so ONIWA can switch Spaces."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            permissionRow(t("アクセシビリティ", "Accessibility"),
                          granted: model.accessibilityGranted)

            if model.verifiedActualSwitch {
                Label(t("キー操作の送信：OK（Space切替を確認済み）",
                        "Keyboard event posting: OK (Space switch confirmed)"),
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if model.ready {
                Text(t("必要な許可を確認しました。Space切替をお試しください。",
                       "Permission confirmed. Try switching a Space."))
                    .foregroundStyle(.green)
            } else if model.accessibilityGranted {
                Text(t("アクセシビリティは許可済みですが、macOSがキー操作を許可していません。古いONIWAの許可を削除し、現在のアプリを登録し直してから再確認してください。",
                       "Accessibility is enabled, but macOS is blocking keyboard events. Remove the old ONIWA approval, authorize the current copy, then recheck."))
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("1.「システム設定を開く」を押します。",
                           "1. Click Open System Settings."))
                    Text(t("2.「プライバシーとセキュリティ → アクセシビリティ」でONIWAをONにします。",
                           "2. In Privacy & Security → Accessibility, enable ONIWA."))
                    Text(t("3. ONIWAに戻って「再確認」を押します。",
                           "3. Return to ONIWA and click Recheck."))
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !isInApplications {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("「アプリケーション」への移動をおすすめします",
                            "Move ONIWA to Applications (recommended)"),
                          systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                    Text(t("ONIWAを終了してから、Finderでこのアプリを「アプリケーション」へドラッグし、移動先から再起動してください。古い許可が残っている場合は新しい場所で登録し直します。",
                           "Quit ONIWA, drag this app to Applications in Finder, then reopen it from there. Reauthorize the new location if an old approval remains."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(t("今のアプリをFinderで表示", "Show this app in Finder"),
                               action: onRevealApp)
                        Button(t("アプリケーションを開く", "Open Applications"),
                               action: onOpenApplications)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(t("現在起動しているONIWA", "Current ONIWA application"))
                    .font(.caption.weight(.semibold))
                Text(Bundle.main.bundlePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
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
        .padding(22)
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
