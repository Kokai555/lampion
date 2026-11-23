import SwiftUI
import AppKit

struct SheetFrame<Content: View>: View {
    let title: String
    let confirm: String
    let canConfirm: Bool
    let action: () -> Void
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
        .frame(width: 440)
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

struct NewTableSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "New Table – \(m.currentDB ?? "")", confirm: "Create", canConfirm: !name.trimmed.isEmpty,
                   action: { if let d = m.currentDB { m.createTable(name.trimmed, in: d) } }) {
            Form { TextField("Name", text: $name) }
            Text("The table is created with an auto-increment “id” primary key. Add the other columns on the Structure tab.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AddColumnSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var type = "VARCHAR(255)"
    @State private var nullable = true
    @State private var defaultValue = ""
    private let presets = ["INT", "BIGINT", "TINYINT(1)", "DECIMAL(10,2)", "FLOAT", "VARCHAR(255)", "TEXT", "LONGTEXT",
                           "DATE", "DATETIME", "TIMESTAMP", "JSON"]

    var body: some View {
        SheetFrame(title: "Add Column – \(m.currentTable ?? "")", confirm: "Add",
                   canConfirm: !name.trimmed.isEmpty && !type.trimmed.isEmpty,
                   action: { m.addColumn(name: name.trimmed, type: type.trimmed, nullable: nullable, defaultValue: defaultValue) }) {
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Type", text: $type)
                    Menu("Common") { ForEach(presets, id: \.self) { p in Button(p) { type = p } } }.fixedSize()
                }
                Toggle("Allow NULL", isOn: $nullable)
                TextField("Default", text: $defaultValue, prompt: Text("none"))
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
