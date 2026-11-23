import SwiftUI
import AppKit

struct SheetFrame<Content: View>: View {
    let title: String
    let confirm: String
    let canConfirm: Bool
    let action: () -> Void
    var width: CGFloat = 440
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: action).keyboardShortcut(.defaultAction).disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

struct NewDatabaseSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var collation = "utf8mb4_general_ci"

    var body: some View {
        SheetFrame(title: "New Database", confirm: "Create", canConfirm: !name.trimmed.isEmpty,
                   action: { m.createDatabase(name.trimmed, collation: collation) }) {
            Form {
                TextField("Name", text: $name)
                Picker("Collation", selection: $collation) {
                    ForEach(["utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_hungarian_ci", "utf8mb4_bin"], id: \.self) {
                        Text($0)
                    }
                }
            }
        }
    }
}

struct InsertRowSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var values: [String: String] = [:]

    var body: some View {
        SheetFrame(title: "New Row – \(m.currentTable ?? "")", confirm: "Insert", canConfirm: true,
                   action: { m.insertRow(values.filter { !$0.value.isEmpty }) }) {
            ScrollView {
                Form {
                    ForEach(m.columns) { c in
                        TextField(c.name, text: Binding(get: { values[c.name] ?? "" }, set: { values[c.name] = $0 }),
                                  prompt: Text(c.extra.contains("auto_increment") ? "automatic" : c.type))
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 360)
            Text("Fields left empty get their default value.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
