import SwiftUI
import AppKit

struct QueryView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SQLEditor(text: $m.queryText, error: m.queryError, errorVersion: m.queryVersion, completions: { m.completions(prefix: $0, qualifier: $1) })
                    .background(Color(nsColor: .textBackgroundColor))
                Divider()
                HStack(spacing: 10) {
                    Button { m.runQuery() } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Run (⌘R)")
                    Text("Database: \(m.currentDB ?? "none selected")  ·  Tab accepts a suggestion").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if m.queryResults.count > 1 {
                        Picker("", selection: $m.shownResult) {
                            ForEach(m.queryResults.indices, id: \.self) { Text("Result \($0 + 1)").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text(m.queryMessage).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minHeight: 120)

            Group {
                if let e = m.queryError {
                    ScrollView {
                        Text(e).foregroundStyle(.red).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else if m.shownResult < m.queryResults.count {
                    let set = m.queryResults[m.shownResult]
                    GridView(columns: set.columns, rows: set.rows, version: m.queryVersion &* 100 &+ m.shownResult)
                } else {
                    Text("Type an SQL statement and press ⌘R.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 140)
        }
    }
}
