import SwiftUI
import AppKit

/// Shown at the top of the main window when a newer release is on GitHub.
struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        HStack(spacing: 12) {
            switch updater.state {
            case .idle, .checking:
                EmptyView()
            case .available(let release):
                Image(systemName: "arrow.down.circle").font(.system(size: 22)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Szerverpanel \(release.version) is available").fontWeight(.semibold)
                    Text("You have \(updater.currentVersion). The update takes a few seconds and reopens the app; your servers keep running.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Release Notes") { Shell.open([release.page]) }
                Button("Update") { updater.install(release) }.buttonStyle(.borderedProminent)
            case .installing(let step):
                ProgressView().controlSize(.small)
                Text(step).fontWeight(.semibold)
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The update could not be installed").fontWeight(.semibold)
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Downloads Page") { Shell.open([Updater.releasesPage]) }
                Button("Try Again") { updater.check(userInitiated: true) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.blue.opacity(0.10))
    }
}
