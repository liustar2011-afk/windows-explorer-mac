import SwiftUI
import AppKit

// MARK: - Windows 11 toggle switch

struct WinToggle: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(isOn ? Win.accent : Win.controlFill)
            .overlay(Capsule().stroke(isOn ? .clear : Win.strokeStrong, lineWidth: 1))
            .frame(width: 40, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Win.textOnAccent : Win.textSecondary)
                    .frame(width: hovering ? 14 : 12, height: hovering ? 14 : 12)
                    .padding(.horizontal, 4)
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } }
    }
}

struct SettingsRow<Trailing: View>: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let title: String
    var subtitle: String? = nil
    var icon: Icon? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon { Glyph(icon: icon, size: 16, color: Win.textSecondary, weight: 1.15) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Win.body(12)).foregroundStyle(Win.text)
                if let subtitle {
                    Text(subtitle).font(Win.body(11)).foregroundStyle(Win.textTertiary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WinRR(radius: 5).fill(Win.controlFill.opacity(0.5)))
    }
}

// MARK: - Settings

struct SettingsDialog: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var settings = Settings.shared
    @ObservedObject var prefs = Prefs.shared
    var maxHeight: CGFloat = 400
    let onClose: () -> Void

    /// Lets the snapshot helper open a specific tab.
    static var initialTab = 0
    static let aboutTabIndex = 6
    @State private var tab = SettingsDialog.initialTab
    @State private var capturing: Command?
    @State private var conflictNote: String?

    private var tabs: [String] { [L("Appearance"), L("Shortcuts"), L("Quick access"), L("Folder icons"), L("Commands"), L("Integration"), L("About")] }

    var body: some View {
        WinDialog(title: L("File Explorer Settings"), width: 680, onClose: onClose) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, name in
                        VStack(spacing: 4) {
                            Text(name)
                                .font(Win.body(12))
                                .foregroundStyle(tab == i ? Win.text : Win.textSecondary)
                            Capsule().fill(tab == i ? Win.accent : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                        .onTapGesture { tab = i; capturing = nil }
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)

                Divider().overlay(Win.divider)

                ScrollView {
                    Group {
                        switch tab {
                        case 0: appearance
                        case 1: shortcuts
                        case 2: quickAccess
                        case 3: folderIcons
                        case 4: CustomCommandsSettings()
                        case 5: SystemIntegrationView()
                        default: about
                        }
                    }
                    .padding(18)
                }
                .frame(height: min(400, maxHeight))
            }
        } footer: {
            WinDialogButton(title: L("Done"), primary: true, action: onClose)
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Language")).font(Win.body(13, weight: .semibold)).foregroundStyle(Win.text)
            ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                SettingsRow(title: language.title) {
                    RadioDot(selected: settings.language == language)
                }
                .contentShape(Rectangle())
                .onTapGesture { settings.language = language }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(settings.language == language ? [.isButton, .isSelected] : .isButton)
            }
            Text(L("Language changes take effect immediately."))
                .font(Win.body(11)).foregroundStyle(Win.textSecondary).padding(.bottom, 10)

            Text(L("Theme")).font(Win.body(12, weight: .semibold)).foregroundStyle(Win.text)
            ForEach(ThemeMode.allCases, id: \.self) { mode in
                SettingsRow(title: L(mode.rawValue)) {
                    RadioDot(selected: settings.theme == mode)
                }
                .contentShape(Rectangle())
                .onTapGesture { settings.theme = mode }
            }

            Text(L("Accent colour")).font(Win.body(12, weight: .semibold))
                .foregroundStyle(Win.text).padding(.top, 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                ForEach(Settings.accents) { option in
                    let color = Win.isDark ? Color(hex: option.dark) : Color(hex: option.light)
                    Circle()
                        .fill(color)
                        .frame(width: 34, height: 34)
                        .overlay {
                            if settings.accentID == option.id {
                                Circle().stroke(Win.text, lineWidth: 2).padding(-3)
                                Glyph(icon: .checkmark, size: 14, color: Win.textOnAccent, weight: 1.7)
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture { settings.accentID = option.id }
                        .help(L(option.name))
                }
            }
            .padding(.horizontal, 2)

            Text(L("Layout")).font(Win.body(12, weight: .semibold))
                .foregroundStyle(Win.text).padding(.top, 14)
            SettingsRow(title: L("Window button position")) {
                Picker(L("Window button position"), selection: $settings.windowButtonsOnLeft) {
                    Text(L("Left")).tag(true)
                    Text(L("Right")).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            SettingsRow(title: L("Compact view"), subtitle: L("Comfortable spacing with Compact view off")) {
                WinToggle(isOn: $prefs.compactMode)
            }
            SettingsRow(title: L("Alternating row backgrounds"),
                        subtitle: L("Subtle alternating colours in Details view")) {
                WinToggle(isOn: $prefs.alternatingRowBackgrounds)
            }
            SettingsRow(title: L("Navigation pane")) { WinToggle(isOn: $prefs.showNavPane) }
            SettingsRow(title: L("Details pane")) { WinToggle(isOn: $prefs.showDetailsPane) }
            SettingsRow(title: L("Preview pane")) { WinToggle(isOn: $prefs.showPreviewPane) }
            SettingsRow(title: L("Item check boxes")) { WinToggle(isOn: $prefs.itemCheckBoxes) }
            SettingsRow(title: L("File name extensions")) { WinToggle(isOn: $prefs.showExtensions) }
            SettingsRow(title: L("Hidden items")) {
                WinToggle(isOn: Binding(get: { prefs.showHidden },
                                        set: { prefs.showHidden = $0; ex.reload() }))
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Click a shortcut, then press the keys you want."))
                    .font(Win.body(11)).foregroundStyle(Win.textTertiary)
                Spacer()
                WinButton(padding: 10, height: 26) {
                    settings.resetAllChords(); capturing = nil
                } content: {
                    Text(L("Restore defaults")).font(Win.body(11)).foregroundStyle(Win.text)
                }
                .overlay(WinRR(radius: 4).stroke(Win.stroke, lineWidth: 1))
            }
            if let note = conflictNote {
                Text(note).font(Win.body(11)).foregroundStyle(Win.accent)
            }

            ForEach(Command.groups, id: \.self) { group in
                let commands = Command.allCases.filter { $0.group == group }
                if !commands.isEmpty {
                    Text(L(group)).font(Win.body(12, weight: .semibold))
                        .foregroundStyle(Win.text).padding(.top, 10)
                    ForEach(commands, id: \.self) { command in
                        SettingsRow(title: command.title,
                                    subtitle: settings.chords(for: command).count > 1
                                        ? L("Also: ") + settings.chords(for: command).dropFirst()
                                            .map(\.display).joined(separator: ", ")
                                        : nil) {
                            HStack(spacing: 6) {
                                ShortcutChip(text: capturing == command
                                                ? L("Press a key…")
                                                : (settings.display(for: command) ?? L("None")),
                                             active: capturing == command) {
                                    beginCapture(command)
                                }
                                if settings.bindings[command.rawValue] != nil {
                                    WinButton(tooltip: L("Restore default"), padding: 5, height: 26) {
                                        settings.resetChords(for: command)
                                    } content: {
                                        Glyph(icon: .undo, size: 13, color: Win.textSecondary, weight: 1.2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func beginCapture(_ command: Command) {
        capturing = command
        conflictNote = nil
        KeyCapture.shared.pending = { chord in
            if let other = settings.conflict(for: chord, excluding: command) {
                conflictNote = LF("{0} was used by “{1}”, so it has been reassigned.", chord.display, other.title)
            }
            settings.setChord(chord, for: command)
            capturing = nil
        }
    }

    // MARK: Quick access

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Pinned folders")).font(Win.body(12, weight: .semibold)).foregroundStyle(Win.text)
                Spacer()
                WinButton(padding: 10, height: 26) { addFolder() } content: {
                    HStack(spacing: 6) {
                        Glyph(icon: .plus, size: 11, color: Win.text, weight: 1.4)
                        Text(L("Add folder…")).font(Win.body(11)).foregroundStyle(Win.text)
                    }
                }
                .overlay(WinRR(radius: 4).stroke(Win.stroke, lineWidth: 1))
            }

            ForEach(Places.quickAccess) { place in
                SettingsRow(title: place.title,
                            subtitle: place.url?.path,
                            icon: place.icon) {
                    WinButton(tooltip: L("Unpin"), padding: 6, height: 26) {
                        if let u = place.url { settings.unpin(u) }
                    } content: {
                        Glyph(icon: .unpin, size: 14, color: Win.textSecondary, weight: 1.2)
                    }
                }
            }

            let hidden = Array(settings.hiddenPlaces)
            if !hidden.isEmpty {
                Text(L("Unpinned")).font(Win.body(12, weight: .semibold))
                    .foregroundStyle(Win.text).padding(.top, 12)
                ForEach(hidden, id: \.self) { path in
                    SettingsRow(title: Places.displayName(for: URL(fileURLWithPath: path)),
                                subtitle: path, icon: .folderOutline) {
                        WinButton(tooltip: L("Pin again"), padding: 6, height: 26) {
                            settings.hiddenPlaces.remove(path)
                        } content: {
                            Glyph(icon: .pin, size: 14, color: Win.textSecondary, weight: 1.2)
                        }
                    }
                }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Pin")
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { settings.pin(url) }
        }
    }

    // MARK: Folder icons

    private var folderIcons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Right-click any folder and choose “Change icon” to customise it."))
                .font(Win.body(11)).foregroundStyle(Win.textTertiary)

            if settings.folderStyles.isEmpty {
                Text(L("No customised folders yet."))
                    .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                    .padding(.top, 12)
            } else {
                ForEach(settings.folderStyles.keys.sorted(), id: \.self) { path in
                    let style = settings.folderStyles[path]!
                    HStack(spacing: 12) {
                        CustomFolderIcon(style: style, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Places.displayName(for: URL(fileURLWithPath: path)))
                                .font(Win.body(12)).foregroundStyle(Win.text)
                            Text(path).font(Win.body(11)).foregroundStyle(Win.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        WinButton(tooltip: L("Reset to the default folder icon"), padding: 6, height: 26) {
                            settings.setStyle(nil, for: URL(fileURLWithPath: path))
                        } content: {
                            Glyph(icon: .undo, size: 14, color: Win.textSecondary, weight: 1.2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(WinRR(radius: 5).fill(Win.controlFill.opacity(0.5)))
                }
            }
        }
    }
}

extension SettingsDialog {

    // MARK: About

    var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("File Explorer"))
                        .font(Win.body(16, weight: .semibold)).foregroundStyle(Win.text)
                    Text(LF("Version {0}", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
                        .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                    Text(L("The Windows 11 File Explorer, rebuilt natively for macOS."))
                        .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            Divider().overlay(Win.divider)

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Created by Alex Degryse"))
                    .font(Win.body(13, weight: .semibold))
                    .foregroundStyle(Win.text)
                LinkRow(title: "linkedin.com/in/alexdegryse",
                        subtitle: L("Connect on LinkedIn"),
                        icon: .people,
                        url: "https://www.linkedin.com/in/alexdegryse")
                LinkRow(title: "github.com/gmazaratti/windows-explorer-mac",
                        subtitle: L("Source code"),
                        icon: .code,
                        url: "https://github.com/gmazaratti/windows-explorer-mac")
            }
            .padding(.vertical, 18)

            Divider().overlay(Win.divider)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Colophon")).font(Win.body(12, weight: .semibold)).foregroundStyle(Win.text)
                Text(Localization.isChinese ? L("About implementation") : """
                     Written in Swift with AppKit and SwiftUI. The Fluent icons are \
                     redrawn as vector geometry on Windows' own 16pt design grid, \
                     because the Segoe Fluent Icons font isn't available on macOS. \
                     Licensed under Apache 2.0: redistribute it freely, but keep the \
                     credit with it. Not affiliated with Microsoft.
                     """)
                    .font(Win.body(11))
                    .foregroundStyle(Win.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
        }
    }
}

struct LinkRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let title: String
    let subtitle: String
    let icon: Icon
    let url: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Glyph(icon: icon, size: 16, color: Win.accent, weight: 1.2)
            VStack(alignment: .leading, spacing: 1) {
                Text(subtitle).font(Win.body(12)).foregroundStyle(Win.text)
                Text(title)
                    .font(Win.body(11))
                    .foregroundStyle(Win.accent)
                    .underline(hovering)
            }
            Spacer(minLength: 12)
            Glyph(icon: .openWith, size: 14, color: Win.textSecondary, weight: 1.15)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WinRR(radius: 5).fill(hovering ? Win.subtleHover : Win.controlFill.opacity(0.5)))
        .contentShape(Rectangle())
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .onTapGesture {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }
}

struct RadioDot: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let selected: Bool
    var body: some View {
        Circle()
            .stroke(selected ? Win.accent : Win.strokeStrong, lineWidth: selected ? 5 : 1.4)
            .frame(width: 18, height: 18)
            .overlay { if selected { Circle().fill(Win.textOnAccent).frame(width: 7, height: 7) } }
    }
}

struct ShortcutChip: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let text: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(Win.body(11))
            .foregroundStyle(active ? Win.accent : Win.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(WinRR(radius: 4).fill(hovering ? Win.fieldHover : Win.field))
            .overlay(WinRR(radius: 4).stroke(active ? Win.accent : Win.stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

// MARK: - Folder icon picker

struct CustomFolderIcon: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let style: FolderStyle
    var size: CGFloat = 16

    var body: some View {
        if let icon = style.iconCase {
            Glyph(icon: icon, size: size, color: style.color ?? Win.accent, weight: 1.25, twoTone: false)
        } else if let color = style.color {
            TintedFolderIcon(size: size, color: color)
        } else {
            FolderIcon(size: size)
        }
    }
}

struct TintedFolderIcon: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    var size: CGFloat = 16
    var color: Color

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let r = w * 0.085
            var tab = Path()
            let tabTop = h * 0.115, tabBottom = h * 0.46
            tab.move(to: CGPoint(x: 0, y: tabTop + r))
            tab.addQuadCurve(to: CGPoint(x: r, y: tabTop), control: CGPoint(x: 0, y: tabTop))
            tab.addLine(to: CGPoint(x: w * 0.355, y: tabTop))
            tab.addLine(to: CGPoint(x: w * 0.475, y: h * 0.245))
            tab.addLine(to: CGPoint(x: w, y: h * 0.245))
            tab.addLine(to: CGPoint(x: w, y: tabBottom))
            tab.addLine(to: CGPoint(x: 0, y: tabBottom))
            tab.closeSubpath()
            ctx.fill(tab, with: .color(color.opacity(0.75)))

            let bodyTop = h * 0.245
            let body = Path(roundedRect: CGRect(x: 0, y: bodyTop, width: w, height: h - bodyTop - h * 0.09),
                            cornerRadius: r, style: .continuous)
            ctx.fill(body, with: .linearGradient(
                Gradient(colors: [color.opacity(0.95), color]),
                startPoint: CGPoint(x: w * 0.2, y: bodyTop), endPoint: CGPoint(x: w * 0.9, y: h)))
        }
        .frame(width: size, height: size)
    }
}

struct FolderIconDialog: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let item: FileItem
    @ObservedObject var settings = Settings.shared
    let onClose: () -> Void

    @State private var style: FolderStyle = FolderStyle()

    private let choices: [Icon] = [
        .folderOutline, .home, .desktop, .download, .document, .picture, .music, .video,
        .gallery, .cloud, .star, .pin, .clock, .people, .shield, .terminal,
        .network, .thisPC, .drive, .compress, .link, .eye, .settings, .recycleBin,
    ]

    private let palette: [String] = [
        "FFCE44", "4CC2FF", "5FD9CF", "6CCB5F", "FFB556", "FF8A80",
        "FF9DC4", "C9A2FF", "9AA5B1", "FFFFFF",
    ]

    var body: some View {
        WinDialog(title: LF("Change icon: {0}", item.displayName), width: 440, onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    CustomFolderIcon(style: style, size: 48)
                    Text(item.displayName).font(Win.body(13)).foregroundStyle(Win.text)
                    Spacer()
                }

                Text(L("Icon")).font(Win.body(12, weight: .semibold)).foregroundStyle(Win.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 6)], spacing: 6) {
                    IconChoice(selected: style.icon == "folder") {
                        FolderIcon(size: 22)
                    } action: { style.icon = "folder" }

                    ForEach(choices, id: \.self) { icon in
                        IconChoice(selected: style.icon == icon.rawValue) {
                            Glyph(icon: icon, size: 20,
                                  color: style.color ?? Win.text, weight: 1.2, twoTone: false)
                        } action: { style.icon = icon.rawValue }
                    }
                }

                Text(L("Colour")).font(Win.body(12, weight: .semibold)).foregroundStyle(Win.text)
                HStack(spacing: 8) {
                    ForEach(palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay {
                                if style.tint == hex { Circle().stroke(Win.text, lineWidth: 2).padding(-3) }
                            }
                            .contentShape(Circle())
                            .onTapGesture { style.tint = hex }
                    }
                    Circle()
                        .fill(Win.controlFill)
                        .overlay(Circle().stroke(Win.strokeStrong, lineWidth: 1))
                        .frame(width: 26, height: 26)
                        .overlay { Glyph(icon: .close, size: 10, color: Win.textSecondary, weight: 1.3) }
                        .contentShape(Circle())
                        .onTapGesture { style.tint = "" }
                        .help(L("No tint"))
                }
            }
            .padding(20)
        } footer: {
            WinDialogButton(title: L("Reset")) {
                settings.setStyle(nil, for: item.url); onClose()
            }
            WinDialogButton(title: L("OK"), primary: true) {
                settings.setStyle(style, for: item.url); onClose()
            }
        }
        .onAppear { style = settings.style(for: item.url) ?? FolderStyle() }
    }
}

struct IconChoice<Content: View>: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let selected: Bool
    @ViewBuilder var content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        content()
            .frame(width: 38, height: 38)
            .background(WinRR(radius: 5).fill(selected ? Win.selected : (hovering ? Win.subtleHover : .clear)))
            .overlay(WinRR(radius: 5).stroke(selected ? Win.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}
