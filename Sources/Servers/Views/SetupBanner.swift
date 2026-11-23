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
                    Text("Setting up…").fontWeight(.semibold)
                    Text("Progress appears in the log below. This can take several minutes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            case .needsHomebrew:
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text("Homebrew is required").fontWeight(.semibold)
                    Text("Szerverpanel installs Apache, PHP and MariaDB with Homebrew. The installer opens in Terminal and asks for your password.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Install Homebrew…") { panel.installHomebrew() }.buttonStyle(.borderedProminent)
            case .needsPackages(let missing):
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing.isEmpty ? "Apache is not configured for PHP yet" : "Server software is not installed yet")
                        .fontWeight(.semibold)
                    Text(missing.isEmpty
                         ? "Set Up enables PHP and phpMyAdmin in Apache's configuration."
                         : "Set Up downloads \(missing.joined(separator: ", ")) with Homebrew and configures them.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Set Up") { panel.runSetup() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.orange.opacity(0.12))
    }

    private var icon: some View {
        Image(systemName: "shippingbox").font(.system(size: 22)).foregroundStyle(.orange)
    }
}
