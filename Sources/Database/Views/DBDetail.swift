import SwiftUI
import AppKit

/// The detail column: a header for the selection, then the content of the chosen tab.
/// The tab switch itself lives in the window toolbar (DatabaseWindow).
struct DBDetail: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // The query editor gets the full height; it names its own database.
            if m.selection != nil && m.tab != .query {
                DBSelectionHeader()
                    .transition(.opacity)
            }
            // Tabs cross-fade instead of swapping in a single frame. The animation is tied to the tab
            // only, so data loads and selection changes inside a tab are not animated by it.
            ZStack {
                switch m.tab {
                case .tables: DBOverview().transition(.opacity)
                case .designer: DesignerView().transition(.opacity)
                case .data: DataView().transition(.opacity)
                case .structure: StructureView().transition(.opacity)
                case .query: QueryView().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(DBMotion.fade(reduceMotion), value: m.tab)
    }
}
