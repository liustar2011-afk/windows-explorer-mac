import SwiftUI
import AppKit

struct SystemIntegrationView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var integration = SystemIntegration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Default folder app")).font(Win.body(13, weight: .semibold)).foregroundStyle(Win.text)
            SettingsRow(title: integration.currentName,
                        subtitle: integration.isDefault ? L("This app opens ordinary folders by default.")
                            : L("The current system association for ordinary folders."), icon: .folderOutline) {
                WinButton(tooltip: L("Refresh"), padding: 8, height: 28) { integration.refresh() } content: {
                    Glyph(icon: .refresh, size: 14, color: Win.textSecondary)
                }
            }
            HStack(spacing: 8) {
                WinDialogButton(title: integration.changing ? L("Applying…") : L("Set as default"),
                                primary: true, enabled: !integration.changing && !integration.isDefault) {
                    integration.useFileExplorer()
                }
                WinDialogButton(title: L("Restore Finder"), enabled: !integration.changing) {
                    integration.restoreFinder()
                }
            }
            if let error = integration.error {
                Text(error).font(Win.body(12)).foregroundStyle(Win.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if integration.succeeded {
                Text(L("Folder association updated.")).font(Win.body(12)).foregroundStyle(Win.accent)
            }
            Text(L("Only folder opening is changed. Documents and apps keep their existing associations. macOS may ask you to confirm the change."))
                .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Win.divider)
            Text(L("External open and reveal")).font(Win.body(13, weight: .semibold)).foregroundStyle(Win.text)
            Text(L("Other apps can pass a folder to open it, or a file to select it in its folder. Multiple files in the same folder share one tab."))
                .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Apps that explicitly call Finder may still open Finder. This setting cannot replace the system Open and Save dialogs."))
                .font(Win.body(12)).foregroundStyle(Win.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { integration.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            integration.refresh()
        }
    }
}
