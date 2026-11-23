import SwiftUI
import AppKit

extension DBModel {
    private static var selfTestStarted = false

    func runSelfTest() {
        if DBModel.selfTestStarted { return }
        DBModel.selfTestStarted = true
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Szerverpanel-dbtest.log")
        try? FileManager.default.removeItem(at: logURL)
        var report = ""
        var failures = 0
        func out(_ s: String) { report += s + "\n"; try? Data(report.utf8).write(to: logURL) }
        func onMain<T>(_ f: () -> T) -> T { DispatchQueue.main.sync(execute: f) }
        func wait() {
            Thread.sleep(forTimeInterval: 0.5)
            var idle = 0
            for _ in 0..<200 {
                idle = onMain({ self.busyCount == 0 }) ? idle + 1 : 0
                if idle >= 5 { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        func check(_ ok: Bool, _ what: String) { out((ok ? "OK   " : "FAIL ") + what); if !ok { failures += 1 } }
        func cell(_ row: Int, _ col: String) -> String? { onMain { self.data.value(row, col) } }

        let db = "_szerverpanel_teszt", tricky = "Árvíztűrő 'tükörfúrógép' \\ <b>&\"x\""
        DispatchQueue.global(qos: .userInitiated).async {
            wait()
            onMain { self.alertMessage = nil }
            check(onMain { self.connectionError == nil && self.databases.contains("mysql") }, "Connect and list databases")

            if onMain({ self.databases.contains(db) }) { onMain { self.dropDatabase(db) }; wait() }
            onMain { self.createDatabase(db, collation: "utf8mb4_hungarian_ci") }; wait()
            check(onMain { self.databases.contains(db) }, "Create database")

            onMain { self.createTable("termekek", in: db) }; wait()
            check(onMain { self.selection == .table(db, "termekek") && self.columns.map(\.name) == ["id"] }, "Create table")

            onMain { self.addColumn(name: "nev", type: "VARCHAR(100)", nullable: true, defaultValue: "") }; wait()
            onMain { self.addColumn(name: "ar", type: "DECIMAL(10,2)", nullable: false, defaultValue: "0") }; wait()
            check(onMain { self.columns.map(\.name) == ["id", "nev", "ar"] }, "Add columns")

            onMain { self.insertRow(["nev": tricky, "ar": "1999.50"]) }; wait()
            onMain { self.insertRow(["nev": "Második", "ar": "500"]) }; wait()
            check(onMain { self.data.rows.count == 2 && self.totalRows == 2 }, "Insert rows")
            check(cell(0, "nev") == tricky, "Accented and special characters survive intact")

            onMain { self.updateCell(row: 1, column: 1, value: "Módosítva") }; wait()
            check(cell(1, "nev") == "Módosítva", "Edit cell")
            onMain { self.updateCell(row: 1, column: 1, value: nil) }; wait()
            check(onMain { self.data.rows.count == 2 && self.data.rows[1][1] == nil }, "Set cell to NULL")

            onMain { self.filter = "ar > 1000"; self.loadData() }; wait()
            check(onMain { self.data.rows.count == 1 && self.totalRows == 1 }, "Filter (WHERE)")
            onMain { self.filter = "nincs_ilyen = 1"; self.loadData() }; wait()
            check(onMain { self.dataError != nil }, "Invalid filter reports an error")
            onMain { self.filter = ""; self.sort(by: "ar") }; wait()
            check(cell(0, "ar") == "500.00", "Sort ascending")
            onMain { self.sort(by: "ar") }; wait()
            check(cell(0, "ar") == "1999.50", "Sort descending")

            onMain { self.queryText = "SELECT COUNT(*) AS db FROM termekek;\nSELECT nev, ar FROM termekek ORDER BY id;"; self.runQuery() }; wait()
            check(onMain { self.queryError == nil && self.queryResults.count == 2 && self.queryResults[0].rows.first?.first == "2"
                           && self.queryResults[1].rows.count == 2 }, "Query with multiple results")
            onMain { self.queryText = "UPDATE termekek SET ar = ar + 1"; self.runQuery() }; wait()
            check(onMain { self.queryMessage.contains("rows affected: 2") }, "Modifying query reports rows affected")
            onMain { self.tab = .query; self.queryText = "SELEC hiba"; self.runQuery() }; wait()
            check(onMain { self.queryError?.contains("1064") == true }, "Invalid SQL reports an error")
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.markedErrors } == ["SELEC"], "Editor marks the syntax error location")
            onMain { self.queryText = "SELECT nev,\n  nincs_ilyen\nFROM termekek"; self.runQuery() }; wait()
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.markedErrors } == ["nincs_ilyen"], "Editor marks an unknown column")
            onMain { self.queryText = "SELECT * FROM termekek"; self.runQuery() }; wait()
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.markedErrors.isEmpty }, "A successful query clears the error mark")
            let kinds = SQLSyntax.tokenize("SELECT COUNT(*), 'a' FROM `t` WHERE x = 12 -- note").map(\.kind)
            check(kinds == [.keyword, .function, .string, .keyword, .identifier, .keyword, .number, .comment], "Syntax highlighting recognises token types")
            check(SQLSyntax.tokenize("SELECT 'open").last?.kind == .error && SQLSyntax.tokenize("SELECT (1").last?.kind == .error
                  && SQLSyntax.tokenize("SELECT 1)").last?.kind == .error, "Unclosed quote and unbalanced parentheses are flagged")

            let dumpPath = NSTemporaryDirectory() + "szerverpanel-teszt.sql"
            onMain { self.dump(db: db, table: nil, to: dumpPath) }; wait()
            let dumped = (try? String(contentsOfFile: dumpPath, encoding: .utf8)) ?? ""
            check(dumped.contains("CREATE TABLE `termekek`") && dumped.contains("tükörfúrógép"), "Export to SQL file")
            try? FileManager.default.removeItem(atPath: dumpPath)

            check(onMain { self.completions(prefix: "terme", qualifier: nil) } == ["termekek"], "Completion: table name")
            check(onMain { self.completions(prefix: "", qualifier: "termekek") } == ["id", "nev", "ar"], "Completion: columns after table.")
            check(onMain { self.completions(prefix: "SEL", qualifier: nil) } == ["SELECT"], "Completion: keyword")
            check(onMain { self.completions(prefix: "CRE", qualifier: nil).first } == "CREATE", "Completion: CREATE comes first")
            check(onMain { self.completions(prefix: "TAB", qualifier: nil).prefix(2) } == ["TABLE", "TABLES"], "Completion: TABLE")
            check(onMain { self.completions(prefix: "tab", qualifier: nil).first } == "table", "Completion: lowercase stays lowercase")
            check(onMain { ["VARCHAR", "AUTO_INCREMENT", "GROUP_CONCAT", "ENGINE", "CONSTRAINT"].allSatisfy { w in
                self.completions(prefix: String(w.prefix(5)), qualifier: nil).contains(w) } }, "Completion: types, functions, options")
            check(onMain { self.completions(prefix: "n", qualifier: "t").contains("nev") }, "Completion: columns after an alias")

            onMain { self.tab = .query; self.queryText = "SELECT * FROM terme" }
            Thread.sleep(forTimeInterval: 0.8)
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            Thread.sleep(forTimeInterval: 1.2)
            check(onMain { self.queryText } == "SELECT * FROM termekek", "Tab in the editor inserts the single match")
            onMain { self.queryText = "SELECT * FROM termekek WHERE termekek." }
            Thread.sleep(forTimeInterval: 0.5)
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.shownSuggestions } == ["id", "nev", "ar"], "Tab after table. opens the column list")
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: "n") }
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.shownSuggestions } == ["nev"], "Typing narrows the open list")
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { self.queryText.hasSuffix("termekek.nev") && SQLEditor.shownSuggestions.isEmpty }, "Tab accepts the suggestion and closes the list")
            onMain { self.queryText = "" }
            Thread.sleep(forTimeInterval: 0.5)
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: "cre") }
            Thread.sleep(forTimeInterval: 0.4)
            check(onMain { SQLEditor.shownSuggestions.first } == "create", "Suggestions appear while typing, without Tab")
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            Thread.sleep(forTimeInterval: 0.3)
            onMain { self.queryText = "-- Products above a price\nSELECT id, nev, COUNT(*) AS db, ROUND(ar, 2)\nFROM `termekek`\nWHERE ar > 1000 AND nev LIKE 'A%'\n  AND nincs_ilyen = 1\nORDER BY ar DESC LIMIT 10"
                     self.runQuery() }; wait()
            Thread.sleep(forTimeInterval: 0.5)
            out("PAUSE")
            Thread.sleep(forTimeInterval: 5)
            onMain { self.queryText = "SELECT * FROM termekek;"; self.runQuery(); self.tab = .data; self.loadData() }; wait()

            onMain { self.selectedRows = [0]; self.deleteSelectedRows() }; wait()
            check(onMain { self.data.rows.count == 1 }, "Delete row")
            onMain { self.dropColumn("ar") }; wait()
            check(onMain { self.columns.map(\.name) == ["id", "nev"] }, "Delete Column")
            onMain { self.truncateTable("termekek", in: db) }; wait()
            check(onMain { self.data.rows.isEmpty }, "Empty table")
            onMain { self.dropTable("termekek", in: db) }; wait()
            check(onMain { self.tables[db]?.isEmpty == true }, "Delete table")

            // Structure: designer, column changes, indexes, foreign keys, table operations.
            func column(_ name: String) -> ColumnInfo? { onMain { self.columns.first { $0.name == name } } }
            onMain { self.selection = .database(db) }
            Thread.sleep(forTimeInterval: 0.3)
            onMain { self.createTable(name: "vevok", in: db, columns: [
                ColumnDraft(name: "id", type: "INT UNSIGNED", nullable: false, autoIncrement: true, primaryKey: true),
                ColumnDraft(name: "nev", type: "VARCHAR(50)", nullable: false),
                ColumnDraft(name: "email", type: "VARCHAR(100)"),
                ColumnDraft(name: "letrehozva", type: "DATETIME", nullable: false, defaultText: "CURRENT_TIMESTAMP"),
            ], engine: "InnoDB", collation: "utf8mb4_hungarian_ci") }; wait()
            check(onMain { self.selection == .table(db, "vevok") && self.columns.map(\.name) == ["id", "nev", "email", "letrehozva"] }
                  && column("id")?.key == "PRI" && column("id")?.extra.contains("auto_increment") == true
                  && column("letrehozva")?.def?.lowercased().hasPrefix("current_timestamp") == true
                  && onMain({ self.currentTableInfo?.collation }) == "utf8mb4_hungarian_ci", "Table designer creates a table with all its columns")

            var draft = ColumnDraft(column("nev")!)
            draft.name = "teljes_nev"; draft.type = "VARCHAR(120)"; draft.defaultText = "ismeretlen"; draft.comment = "Customer's name"
            onMain { self.saveColumn(draft, replacing: "nev", position: .after("email")) }; wait()
            check(onMain { self.columns.map(\.name) == ["id", "email", "teljes_nev", "letrehozva"] }
                  && column("teljes_nev")?.type == "varchar(120)" && column("teljes_nev")?.def == "ismeretlen"
                  && column("teljes_nev")?.null == "NO" && column("teljes_nev")?.comment == "Customer's name", "Edit column: rename, type, default, comment, position")

            let before = onMain { self.columns.map { "\($0.name)|\($0.type)|\($0.null)|\($0.def ?? "nil")|\($0.extra)|\($0.comment)" } }
            for name in ["id", "email", "teljes_nev", "letrehozva"] {
                let same = ColumnDraft(column(name)!)
                onMain { self.saveColumn(same, replacing: name) }; wait()
            }
            let after = onMain { self.columns.map { "\($0.name)|\($0.type)|\($0.null)|\($0.def ?? "nil")|\($0.extra)|\($0.comment)" } }
            check(before == after && onMain({ self.alertMessage == nil }), "Saving a column unchanged keeps it exactly as it was")

            onMain { self.saveColumn(ColumnDraft(name: "aktiv", type: "TINYINT(1)", nullable: false, defaultText: "1"), replacing: nil, position: .first) }; wait()
            check(onMain { self.columns.first?.name == "aktiv" } && column("aktiv")?.def == "1", "Add column at a chosen position")

            onMain { self.addIndex(name: "uq_email", kind: .unique, columns: ["email"]) }; wait()
            onMain { self.addIndex(name: "", kind: .index, columns: ["teljes_nev", "email"]) }; wait()
            check(onMain { self.indexList.contains { $0.name == "uq_email" && $0.unique && $0.columns == ["email"] }
                           && self.indexList.contains { !$0.unique && $0.columns == ["teljes_nev", "email"] }
                           && self.indexList.contains { $0.isPrimary && $0.columns == ["id"] } }, "Add unique and multi-column indexes")
            onMain { self.dropIndex("uq_email") }; wait()
            check(onMain { !self.indexList.contains { $0.name == "uq_email" } && self.indexList.count == 2 }, "Delete index")

            onMain { self.selection = .database(db) }
            Thread.sleep(forTimeInterval: 0.3)
            onMain { self.createTable(name: "rendelesek", in: db, columns: [
                ColumnDraft(name: "id", type: "INT UNSIGNED", nullable: false, autoIncrement: true, primaryKey: true),
                ColumnDraft(name: "vevo_id", type: "INT UNSIGNED", nullable: false),
            ], engine: "InnoDB", collation: "utf8mb4_general_ci") }; wait()
            onMain { self.addForeignKey(name: "fk_vevo", column: "vevo_id", refTable: "vevok", refColumn: "id", onDelete: "CASCADE", onUpdate: "RESTRICT") }; wait()
            check(onMain { self.foreignKeys == [ForeignKeyInfo(name: "fk_vevo", column: "vevo_id", refSchema: db, refTable: "vevok",
                                                               refColumn: "id", updateRule: "RESTRICT", deleteRule: "CASCADE")] }, "Add foreign key")
            onMain { self.queryText = "INSERT INTO rendelesek (vevo_id) VALUES (999)"; self.runQuery() }; wait()
            check(onMain { self.queryError?.contains("foreign key constraint fails") == true }, "The foreign key is enforced by the server")
            onMain { self.dropForeignKey("fk_vevo") }; wait()
            check(onMain { self.foreignKeys.isEmpty && self.alertMessage == nil }, "Delete foreign key")

            onMain { self.setTableOptions(engine: "MyISAM", collation: "utf8mb4_hungarian_ci") }; wait()
            check(onMain { self.currentTableInfo?.engine == "MyISAM" && self.currentTableInfo?.collation == "utf8mb4_hungarian_ci" }, "Change engine and collation")
            onMain { self.infoMessage = nil; self.maintenance("OPTIMIZE") }; wait()
            check(onMain { self.infoMessage?.contains("Optimize finished") == true }, "Maintenance reports the server's answer")
            onMain { self.infoMessage = nil; self.queryText = "INSERT INTO rendelesek (vevo_id) VALUES (1), (2)"; self.runQuery() }; wait()
            onMain { self.copyTable(to: "rendelesek_masolat", withData: true) }; wait()
            let copied = DBClient.run("SELECT COUNT(*) FROM `\(db)`.`rendelesek_masolat`").sets.first?.rows.first?.first ?? nil
            check(copied == "2" && onMain({ self.tables[db]?.contains { $0.name == "rendelesek_masolat" } == true }), "Copy table with data")
            onMain { self.infoMessage = nil; self.renameTable(to: "megrendelesek", database: db) }; wait()
            check(onMain { self.selection == .table(db, "megrendelesek") && self.tables[db]?.contains { $0.name == "rendelesek" } == false
                           && self.columns.map(\.name) == ["id", "vevo_id"] }, "Rename table")
            check(onMain { self.tab == .structure }, "The table designer leaves you on the Structure tab")
            onMain { self.selection = .table(db, "vevok"); self.structureSection = .columns }; wait()
            check(onMain { self.tab == .structure }, "Switching tables keeps the Structure tab")
            if CommandLine.arguments.contains("--screenshots") {
                out("PAUSE2"); Thread.sleep(forTimeInterval: 4)
                onMain { self.sheet = .newTable }
                Thread.sleep(forTimeInterval: 1.5); out("PAUSE3"); Thread.sleep(forTimeInterval: 4)
                onMain { self.sheet = nil }
                Thread.sleep(forTimeInterval: 1)
                onMain { self.sheet = .tableOptions }
                Thread.sleep(forTimeInterval: 1.5); out("PAUSE4"); Thread.sleep(forTimeInterval: 4)
                onMain { self.sheet = nil }
                Thread.sleep(forTimeInterval: 1)
            }
            check(onMain { self.alertMessage == nil }, "Structure operations left no error")
            onMain { self.expanded.remove(db); self.selection = .database(db) }
            Thread.sleep(forTimeInterval: 0.3)
            onMain { self.tab = .query; self.queryText = "CREATE TABLE diak (om CHAR(10) PRIMARY KEY, nev VARCHAR(100) NOT NULL)"; self.runQuery() }; wait()
            check(onMain { self.tables[db]?.contains { $0.name == "diak" } == true }, "A table created by a query shows up in a collapsed database")
            onMain { self.dropDatabase(db) }; wait()
            check(onMain { !self.databases.contains(db) }, "Delete database")
            check(onMain { self.alertMessage == nil }, "No unexpected error message left")

            out(failures == 0 ? "DATABASE SELF-TEST PASSED" : "DATABASE SELF-TEST FAILED: \(failures) failures")
        }
    }
}
