import SwiftUI
import AppKit

struct SystemIntegrationView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var integration = SystemIntegration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Finder replacement"))
                .font(Win.body(13, weight: .semibold))
                .foregroundStyle(Win.text)

            SettingsRow(title: L("Open folders"),
                        subtitle: integration.currentName,
                        icon: .folderOutline) {
                routingState(active: integration.folderHandlerIsFileExplorer)
            }

            SettingsRow(title: L("Reveal / Show in Finder"),
                        subtitle: integration.revealViewerName,
                        icon: .openWith) {
                routingState(active: integration.revealHandlerIsFileExplorer)
            }

            HStack(spacing: 8) {
                WinDialogButton(
                    title: integration.changing ? L("Applying…") : L("Replace Finder"),
                    primary: true,
                    enabled: !integration.changing && !integration.isDefault
                ) {
                    integration.useFileExplorer()
                }
                WinDialogButton(title: L("Restore Finder"), enabled: !integration.changing) {
                    integration.restoreFinder()
                }
            }

            if let error = integration.error {
                Text(error)
                    .font(Win.body(12))
                    .foregroundStyle(Win.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if integration.succeeded {
                Text(integration.isDefault ? L("Finder routing updated.") : L("Finder routing restored."))
                    .font(Win.body(12))
                    .foregroundStyle(Win.accent)
            }

            Text(L("Replace Finder registers File Explorer as the macOS folder handler and as the global file viewer used by many Reveal/Show in Finder actions. Already-running apps may need to be restarted."))
                .font(Win.body(12))
                .foregroundStyle(Win.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Win.divider)

            Text(L("External open and reveal"))
                .font(Win.body(13, weight: .semibold))
                .foregroundStyle(Win.text)

            Text(L("Other apps can pass a folder to open it, or a file to select it in its folder. Multiple files in the same folder share one tab."))
                .font(Win.body(12))
                .foregroundStyle(Win.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("Hard-coded Finder launches, the Desktop, drive mounting, and the system Open/Save dialogs still belong to macOS and may continue to use Finder."))
                .font(Win.body(12))
                .foregroundStyle(Win.textTertiary)
                .fixedSize(horizontal: false, vertical: true)


            Divider().overlay(Win.divider)

            FinderDockInterceptionSettings()
        }
        .onAppear { integration.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            integration.refresh()
        }
    }

    @ViewBuilder
    private func routingState(active: Bool) -> some View {
        if active {
            HStack(spacing: 5) {
                Glyph(icon: .checkmark, size: 12, color: Win.accent, weight: 1.5)
                Text(L("Active"))
                    .font(Win.body(11))
                    .foregroundStyle(Win.accent)
            }
        } else {
            Text(L("Not active"))
                .font(Win.body(11))
                .foregroundStyle(Win.textTertiary)
        }
    }
}


private struct FinderDockInterceptionSettings: View {
    @ObservedObject private var interceptor = FinderDockInterceptor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Dock Finder icon"))
                .font(Win.body(13, weight: .semibold))
                .foregroundStyle(Win.text)

            SettingsRow(
                title: L("Open File Explorer when Finder is clicked in the Dock"),
                subtitle: interceptor.running
                    ? L("Finder Dock clicks are being intercepted.")
                    : (interceptor.enabled
                        ? L("Waiting for Accessibility permission.")
                        : L("Off. Finder keeps its normal Dock behavior.")),
                icon: .folderOutline
            ) {
                WinToggle(isOn: Binding(
                    get: { interceptor.enabled },
                    set: { interceptor.setEnabled($0) }
                ))
            }

            if interceptor.enabled && !interceptor.accessibilityTrusted {
                HStack(spacing: 8) {
                    WinDialogButton(title: L("Request Accessibility Access"), primary: true) {
                        interceptor.requestAccessibilityAndStart()
                    }
                    WinDialogButton(title: L("Open Accessibility Settings")) {
                        interceptor.openAccessibilitySettings()
                    }
                }
            }

            if let error = interceptor.error {
                Text(error)
                    .font(Win.body(11))
                    .foregroundStyle(Win.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L("This only changes clicks on Finder's Dock icon. It does not remove Finder or alter the Desktop."))
                .font(Win.body(11))
                .foregroundStyle(Win.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { interceptor.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            interceptor.refreshPermission()
        }
    }
}
