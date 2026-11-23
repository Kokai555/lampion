import SwiftUI
import AppKit

struct LogPane: View {
    @EnvironmentObject var panel: Panel
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(panel.log) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Self.fmt.string(from: e.time)).foregroundStyle(.secondary)
                            Text("[\(e.module)]").foregroundStyle(.blue).frame(width: 72, alignment: .leading)
                            Text(e.text).foregroundStyle(color(e.level))
                        }
                        .id(e.id)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: panel.log.count) {
                if let last = panel.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func color(_ l: LogEntry.Level) -> Color {
        switch l {
        case .info: return .primary
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}
