import SwiftUI
import AppKit

/// Shown at the top of the main window while something the panel needs is missing.
struct SetupBanner: View {
    @EnvironmentObject var panel: Panel

    var body: some View {
        HStack(spacing: 12) {
            switch panel.setupState {
            case .ready:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading and setting up Apache, PHP and MariaDB…").fontWeight(.semibold)
                    Text("Progress appears in the log below. This can take several minutes; the servers start when it finishes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            case .needsHomebrew:
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text("Homebrew is required").fontWeight(.semibold)
                    Text("Szerverpanel installs Apache, PHP and MariaDB with Homebrew. Finish Homebrew's installer in the Terminal window (it asks for your password); the download continues here by itself.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Installer Again") { panel.installHomebrew() }
            case .needsPackages(let missing):
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing.isEmpty ? "Apache is not configured for PHP yet" : "Server software is not installed yet")
                        .fontWeight(.semibold)
                    Text(missing.isEmpty
                         ? "Set Up enables PHP and phpMyAdmin in Apache's configuration."
                         : "The download did not finish. Try Again downloads \(missing.joined(separator: ", ")) with Homebrew and configures them.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(missing.isEmpty ? "Set Up" : "Try Again") { panel.runSetup() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.orange.opacity(0.12))
    }

    private var icon: some View {
        Image(systemName: "shippingbox").font(.system(size: 22)).foregroundStyle(.orange)
    }
}
