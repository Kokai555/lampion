import SwiftUI
import AppKit

/// Állapotjelző: az állapotot szimbólum és szöveg is jelzi, nem csak a szín.
struct StatusBadge: View {
    let title: String
    let on: Bool
    var onText = "Running"
    var offText = "Stopped"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "stop.circle")
                .font(.system(size: 17))
                .foregroundStyle(on ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(on ? onText : offText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, alignment: .leading)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: on)
    }
}
