import SwiftUI
import AppKit

struct SQLLogView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(m.sqlLog) { line in
                        Text(line.text)
                            .foregroundStyle(line.isError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: m.sqlLog.count) {
                if let last = m.sqlLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
