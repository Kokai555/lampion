import SwiftUI
import AppKit

/// The update notice at the top of the main window.
struct UpdateCard: View {
    @EnvironmentObject var updater: Updater
    @State private var showingNotes = false

    var body: some View {
        card.onAppear {
            // `--preview-update notes` opens the release notes straight away.
            if let i = CommandLine.arguments.firstIndex(of: "--preview-update"), CommandLine.arguments.dropFirst(i + 1).first == "notes" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showingNotes = true }
            }
        }
    }

    private var card: some View {
        NoticeCard {
            switch updater.state {
            case .idle:
                EmptyView()

            case .checking:
                ProgressView().controlSize(.small).frame(width: 40)
                NoticeText(title: "Checking for updates…")
                Spacer()

            case .upToDate:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green).frame(width: 40)
                NoticeText(title: "Szerverpanel is up to date", detail: "Version \(updater.currentVersion) is the latest.")
                Spacer()

            case .available(let release):
                appIcon
                NoticeText(title: "Szerverpanel \(release.version) is available",
                           detail: "Version \(updater.currentVersion) is installed. Updating takes a few seconds and the servers keep running.")
                Spacer(minLength: 12)
                Button("Later") { updater.later() }
                    .help("Hide this until the next time Szerverpanel opens")
                Button("What’s New") { showingNotes = true }
                    .popover(isPresented: $showingNotes, arrowEdge: .bottom) { ReleaseNotes(release: release, isPresented: $showingNotes) }
                Button("Update Now") { updater.install(release) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)

            case .downloading(let release, let fraction):
                appIcon
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading Szerverpanel \(release.version)").font(.headline)
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 360)
                        .accessibilityLabel("Download progress")
                }
                Text("\(Int((fraction * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Spacer(minLength: 12)
                Button("Cancel") { updater.cancelDownload() }

            case .installing(let release):
                appIcon
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installing Szerverpanel \(release.version)").font(.headline)
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: 360)
                }
                Text("Szerverpanel reopens in a moment.").font(.callout).foregroundStyle(.secondary)
                Spacer()

            case .failed(let message):
                Image(systemName: "exclamationmark.circle").font(.system(size: 28)).foregroundStyle(.secondary).frame(width: 40)
                NoticeText(title: "The update could not be installed", detail: message)
                Spacer(minLength: 12)
                Button("Dismiss") { updater.later() }
                Button("Download Manually") { Shell.open([Updater.releasesPage]) }
                Button("Try Again") { updater.check(userInitiated: true) }
            }
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
    }
}

/// The release notes, shown in a popover from "What's New".
struct ReleaseNotes: View {
    @EnvironmentObject var updater: Updater
    let release: Updater.Release
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What’s New in \(release.version)").font(.headline).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text("No release notes were published for this version.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: 300)
            Divider()
            HStack {
                Button("Skip This Version") { isPresented = false; updater.skip(release) }
                    .help("Don’t offer \(release.version) again")
                Spacer()
                Button("View on GitHub") { Shell.open([release.page]) }
            }
            .padding(12)
        }
        .frame(width: 440)
    }

    private var lines: [String] {
        release.highlights.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.hasPrefix("#") {
            // The popover already has a title, so a leading "What's new" heading is dropped.
            let text = line.drop { $0 == "#" || $0 == " " }
            if text.lowercased().hasPrefix("what") { EmptyView() } else { Text(String(text)).font(.subheadline.weight(.semibold)) }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inline(line)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
