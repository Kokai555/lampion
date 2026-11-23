import SwiftUI
import AppKit

// MARK: - Colours

extension Module {
    var tint: Color { self == .apache ? Color(red: 0.91, green: 0.36, blue: 0.20) : Color(red: 0.13, green: 0.55, blue: 0.68) }
}

enum Tint {
    static let php = Color(red: 0.42, green: 0.42, blue: 0.80)
    static let general = Color.gray
    static let logs = Color(red: 0.85, green: 0.60, blue: 0.10)
    static let overview = Color(red: 0.22, green: 0.47, blue: 0.95)
}

// MARK: - Icons

// One place for the main window's symbols, so they stay consistent:
// filled glyphs on tiles and for status, outlined glyphs for buttons and toolbar actions.

extension Module {
    /// Identity glyph, drawn white on the module's tile.
    var icon: String { self == .apache ? "server.rack" : "cylinder.split.1x2.fill" }
}

extension Pane {
    /// Glyph for the sidebar tile and the settings header.
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .apache: return Module.apache.icon
        case .php: return "chevron.left.forwardslash.chevron.right"
        case .mariadb: return Module.mysql.icon
        case .general: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return Tint.overview
        case .logs: return Tint.logs
        case .apache: return Module.apache.tint
        case .php: return Tint.php
        case .mariadb: return Module.mysql.tint
        case .general: return Tint.general
        }
    }
}

extension LogSource {
    /// Outlined glyph for the source picker; the selected source shows the filled variant where one exists.
    var icon: String {
        switch self {
        case .activity: return "clock.arrow.circlepath"
        case .apacheError: return "exclamationmark.octagon"
        case .apacheAccess: return "arrow.left.arrow.right"
        case .php: return Pane.php.icon
        case .mariadb: return "cylinder.split.1x2"
        case .mariadbSlow: return "tortoise"
        case .mariadbGeneral: return "list.bullet.rectangle"
        }
    }
}

// MARK: - Motion

/// The window's motion: short, interruptible springs for movement and a quick fade when Reduce Motion is on.
enum Motion {
    static let spring = Animation.snappy(duration: 0.28)
    static let fade = Animation.easeOut(duration: 0.18)

    /// Spring normally; a plain fade with Reduce Motion.
    static func standard(_ reduceMotion: Bool) -> Animation { reduceMotion ? fade : spring }

    /// Slide-and-fade for things that appear from an edge; only a fade with Reduce Motion.
    static func appear(from edge: Edge, _ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

// MARK: - Card

/// A rounded, slightly raised panel used on the overview.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// A symbol on a tinted rounded square, like System Settings uses.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36
    /// Glyph size relative to the tile; small tiles (sidebar) read better with a larger glyph.
    var glyphScale: CGFloat = 0.46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * glyphScale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

// MARK: - Status

enum ServerState: Equatable {
    case running, stopped, busy, notInstalled

    var title: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .busy: return "Working…"
        case .notInstalled: return "Not installed"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .secondary
        case .busy: return .orange
        case .notInstalled: return .red
        }
    }
}

extension Panel {
    func state(_ m: Module) -> ServerState {
        if busy.contains(m) { return .busy }
        let s = status[m] ?? ModuleStatus()
        if !s.installed { return .notInstalled }
        return s.running ? .running : .stopped
    }
}

/// A small coloured dot for a server state (sidebar rows and footer).
struct StatusDot: View {
    let state: ServerState

    var body: some View {
        Circle()
            .fill(state == .running ? Color.green : state == .busy ? .orange : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .animation(Motion.fade, value: state)
    }
}

/// Coloured dot plus text, so the state never relies on colour alone.
struct StatusPill: View {
    let state: ServerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if state == .busy {
                ProgressView().controlSize(.mini).transition(.opacity)
            } else {
                Circle().fill(state.color).frame(width: 7, height: 7)
                    .shadow(color: state == .running ? Color.green.opacity(0.6) : .clear, radius: 3)
                    .transition(.opacity)
            }
            Text(state.title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(state.color.opacity(state == .stopped ? 0.10 : 0.14)))
        .foregroundStyle(state == .stopped ? Color.secondary : state.color)
        .animation(Motion.standard(reduceMotion), value: state)
    }
}

/// Small grey label above a value.
struct Fact: View {
    let label: String
    let value: String
    var mono = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary).kerning(0.4)
            Text(value).font(mono ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings pages

/// Header at the top of a settings form: icon, title, the file it edits and file actions.
struct SettingsHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let file: String?
    var onRestore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let file {
                Menu {
                    Button("Open in Text Editor") { Shell.open(["-t", file]) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file, forType: .string)
                    }
                    if let onRestore {
                        Divider()
                        Button("Restore Original File…", action: onRestore)
                    }
                } label: {
                    Label((file as NSString).lastPathComponent, systemImage: "doc.text")
                }
                .menuStyle(.button)
                .fixedSize()
                .help(file)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Field label with a line of explanation under it.
struct FieldLabel: View {
    let title: String
    var detail: String? = nil

    init(_ title: String, _ detail: String? = nil) { self.title = title; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A short text field for sizes and numbers, outlined in red when the value is not valid.
struct ValueField: View {
    let placeholder: String
    @Binding var text: String
    var valid = true
    var width: CGFloat = 110

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .frame(width: width)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.red, lineWidth: valid ? 0 : 1.5))
            .labelsHidden()
    }
}

/// Int binding shown as text.
extension Binding where Value == Int {
    var text: Binding<String> {
        Binding<String>(get: { String(wrappedValue) }, set: { if let v = Int($0.trimmed) { wrappedValue = v } })
    }
}

/// The bar at the bottom of a settings page while there are unsaved changes.
/// It animates only itself: the form above resizes once instead of being animated with it.
struct SaveBar: View {
    let dirty: Bool
    let problems: [String]
    let saving: Bool
    let restartName: String?        // server to restart after saving, if it is running
    let message: (text: String, ok: Bool)?
    let onRevert: () -> Void
    let onSave: (_ restart: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visible: Bool { dirty || message != nil }

    var body: some View {
        VStack(spacing: 0) {
            if visible {
                bar.transition(Motion.appear(from: .bottom, reduceMotion))
            }
        }
        .animation(Motion.standard(reduceMotion), value: visible)
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let problem = problems.first, dirty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.callout).lineLimit(2)
                } else if dirty {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary)
                    Text(restartName.map { "Unsaved changes. \($0) restarts to apply them." } ?? "Unsaved changes.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let message {
                    Image(systemName: message.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(message.ok ? .green : .red)
                    Text(message.text).font(.callout).lineLimit(2)
                }
                Spacer(minLength: 12)
                if saving { ProgressView().controlSize(.small) }
                if dirty {
                    Button("Revert", action: onRevert).disabled(saving)
                        .help("Discard the unsaved changes on this page")
                    if restartName != nil {
                        Button("Save Only") { onSave(false) }.disabled(saving || !problems.isEmpty)
                    }
                    Button(restartName.map { "Save & Restart \($0)" } ?? "Save") { onSave(restartName != nil) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(saving || !problems.isEmpty)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.bar)
    }
}
