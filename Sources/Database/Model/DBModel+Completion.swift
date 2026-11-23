import SwiftUI
import AppKit

/// Tab-kiegészítés: kulcsszavak és javaslatok.
extension DBModel {
    /// Gyakori szavak elöl, utána a MariaDB kulcsszavai, függvényei és típusai ábécérendben, végül gyakori szókapcsolatok.
    static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "DATABASE", "ALTER", "DROP", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
        "CROSS", "ON", "USING", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC", "DISTINCT",
        "UNION", "ALL", "IN", "IS", "LIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "IF",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT", "AUTO_INCREMENT", "ADD", "COLUMN", "MODIFY",
        "CHANGE", "RENAME", "TO", "TRUNCATE", "REPLACE", "SHOW", "DESCRIBE", "EXPLAIN", "USE", "TABLES", "DATABASES",
        "COLUMNS", "COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "NOW", "INT", "VARCHAR",
        "TEXT", "DATE", "DATETIME", "DECIMAL", "BOOLEAN", "ABS", "ACTION", "ADDDATE", "ADDTIME", "AES_DECRYPT",
        "AES_ENCRYPT", "AFTER", "AGAINST", "ALGORITHM", "ALWAYS", "ANALYZE", "ANY", "Aria", "ASCII", "AUTOCOMMIT",
        "AVG_ROW_LENGTH", "BEFORE", "BEGIN", "BIGINT", "BIN", "BINARY", "BIT", "BIT_LENGTH", "BLOB", "BOOL", "BOTH",
        "BTREE", "CALL", "CASCADE", "CASCADED", "CAST", "CEIL", "CEILING", "CHAR", "CHAR_LENGTH", "CHARACTER",
        "CHARSET", "CHECK", "CHECKSUM", "COLLATE", "COLLATION", "COMMENT", "COMMIT", "COMMITTED", "COMPACT",
        "COMPRESSED", "CONCAT_WS", "CONNECTION_ID", "CONSTRAINT", "CONTAINS", "CONVERT", "CURDATE", "CURRENT",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "CURSOR", "CURTIME", "CYCLE", "DATA",
        "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DATEDIFF", "DAY", "DAYNAME", "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR",
        "DEALLOCATE", "DEC", "DECLARE", "DEFINER", "DELAYED", "DELIMITER", "DENSE_RANK", "DETERMINISTIC", "DISABLE",
        "DIV", "DO", "DOUBLE", "DUPLICATE", "DYNAMIC", "EACH", "ELSEIF", "ELT", "ENABLE", "ENCLOSED", "ENGINE",
        "ENGINES", "ENUM", "ERRORS", "ESCAPE", "ESCAPED", "EVENT", "EVENTS", "EXCEPT", "EXECUTE", "EXIT", "EXP",
        "EXTENDED", "EXTRACT", "FALSE", "FETCH", "FIELD", "FIELDS", "FIND_IN_SET", "FIRST", "FIRST_VALUE", "FIXED",
        "FLOAT", "FLOOR", "FLUSH", "FOLLOWING", "FOR", "FORCE", "FORMAT", "FOUND_ROWS", "FROM_UNIXTIME", "FULL",
        "FULLTEXT", "FUNCTION", "GENERATED", "GEOMETRY", "GLOBAL", "GRANT", "GRANTS", "GREATEST", "GROUP_CONCAT",
        "HANDLER", "HASH", "HEX", "HIGH_PRIORITY", "HOUR", "IDENTIFIED", "IGNORE", "IMPORT", "INCREMENT", "INDEXES",
        "INET_ATON", "INET_NTOA", "INFILE", "InnoDB", "INOUT", "INSERT_METHOD", "INSTR", "INTEGER", "INTERSECT",
        "INTERVAL", "INVISIBLE", "ISNULL", "ISOLATION", "ITERATE", "JSON", "JSON_ARRAY", "JSON_ARRAYAGG",
        "JSON_CONTAINS", "JSON_EXTRACT", "JSON_LENGTH", "JSON_OBJECT", "JSON_OBJECTAGG", "JSON_SET", "JSON_UNQUOTE",
        "JSON_VALUE", "KEYS", "KILL", "LAG", "LANGUAGE", "LAST", "LAST_DAY", "LAST_INSERT_ID", "LAST_VALUE", "latin1",
        "LCASE", "LEAD", "LEADING", "LEAST", "LEAVE", "LENGTH", "LEVEL", "LINES", "LN", "LOAD", "LOCAL", "LOCATE",
        "LOCK", "LOG", "LOGS", "LONGBLOB", "LONGTEXT", "LOOP", "LOW_PRIORITY", "LOWER", "LPAD", "LTRIM", "MAKEDATE",
        "MASTER", "MATCH", "MAXVALUE", "MD5", "MEDIUMBLOB", "MEDIUMINT", "MEDIUMTEXT", "MEMORY", "MERGE", "MINUTE",
        "MINVALUE", "MOD", "MODE", "MONTH", "MONTHNAME", "MyISAM", "NAMES", "NATURAL", "NEXT", "NO", "NOWAIT",
        "NTILE", "NULLIF", "NUMERIC", "NVARCHAR", "OPEN", "OPTIMIZE", "OPTION", "OPTIONALLY", "OUT", "OUTFILE",
        "OVER", "PARTITION", "PARTITIONS", "PASSWORD", "PERSISTENT", "PI", "POSITION", "POW", "POWER", "PRECEDING",
        "PRECISION", "PREPARE", "PRIVILEGES", "PROCEDURE", "PROCESSLIST", "PURGE", "QUARTER", "QUERY", "QUICK",
        "RAND", "RANGE", "RANK", "READ", "REAL", "RECURSIVE", "REDUNDANT", "REGEXP", "RELEASE", "REPAIR", "REPEAT",
        "REPEATABLE", "REQUIRE", "RESET", "RESTRICT", "RETURN", "RETURNING", "RETURNS", "REVERSE", "REVOKE", "RLIKE",
        "ROLE", "ROLLBACK", "ROLLUP", "ROUND", "ROUTINE", "ROW", "ROW_COUNT", "ROW_FORMAT", "ROW_NUMBER", "ROWS",
        "RPAD", "RTRIM", "SAVEPOINT", "SCHEMA", "SCHEMAS", "SECOND", "SECURITY", "SEPARATOR", "SEQUENCE", "SERIAL",
        "SERIALIZABLE", "SESSION", "SHA1", "SHA2", "SIGN", "SIGNAL", "SIGNED", "SLAVE", "SLEEP", "SMALLINT", "SOME",
        "SPATIAL", "SQL", "SQL_CALC_FOUND_ROWS", "SQRT", "START", "STARTING", "STATUS", "STORED", "STR_TO_DATE",
        "STRAIGHT_JOIN", "SUBDATE", "SUBPARTITION", "SUBSTR", "SUBSTRING", "SUBSTRING_INDEX", "SYSDATE", "TEMPORARY",
        "TERMINATED", "TIME", "TIME_FORMAT", "TIMEDIFF", "TIMESTAMP", "TIMESTAMPDIFF", "TINYBLOB", "TINYINT",
        "TINYTEXT", "TO_DAYS", "TRAILING", "TRANSACTION", "TRIGGER", "TRIGGERS", "TRIM", "TRUE", "UCASE", "UNBOUNDED",
        "UNCOMMITTED", "UNDO", "UNHEX", "UNIX_TIMESTAMP", "UNLOCK", "UNSIGNED", "UNTIL", "UPPER", "USAGE", "USER",
        "UTC_TIMESTAMP", "utf8mb4", "utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_hungarian_ci", "utf8mb4_unicode_ci",
        "UUID", "VALUE", "VARBINARY", "VARIABLES", "VARYING", "VERSION", "VIRTUAL", "WAIT", "WARNINGS", "WEEK",
        "WEEKDAY", "WHILE", "WINDOW", "WITH", "WORK", "WRITE", "XOR", "YEAR", "YEARWEEK", "ZEROFILL", "ORDER BY",
        "GROUP BY", "INSERT INTO", "DELETE FROM", "CREATE TABLE", "CREATE DATABASE", "ALTER TABLE", "DROP TABLE",
        "LEFT JOIN", "INNER JOIN", "PRIMARY KEY", "FOREIGN KEY", "NOT NULL", "IF NOT EXISTS", "IF EXISTS",
        "UNION ALL", "ON DELETE CASCADE", "ON UPDATE CASCADE", "ON DUPLICATE KEY UPDATE", "SHOW TABLES",
        "SHOW DATABASES", "SHOW CREATE TABLE", "IS NULL", "IS NOT NULL", "TRUNCATE TABLE", "ADD COLUMN",
        "DROP COLUMN", "DEFAULT CHARSET",
    ]

    /// Javaslatok a begépelt szókezdethez. `qualifier`: a pont előtti név (tábla vagy adatbázis), ha van.
    func completions(prefix: String, qualifier: String?) -> [String] {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        let db = currentDB
        var candidates: [String] = []
        if let q = qualifier {
            if let db, let cols = completionColumns[db]?.first(where: { same($0.key, q) })?.value {
                candidates = cols
            } else if let d = databases.first(where: { same($0, q) }) {
                candidates = (tables[d] ?? []).map(\.name)
            } else {
                // álnév (pl. "t.") – az aktuális adatbázis összes oszlopa
                candidates = db.flatMap { completionColumns[$0] }?.values.flatMap { $0 } ?? []
            }
        } else {
            if let db {
                candidates += (tables[db] ?? []).map(\.name)
                if let t = currentTable { candidates += completionColumns[db]?[t] ?? [] }
                candidates += (completionColumns[db] ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
            }
            candidates += databases
            // Kulcsszavak a begépelt betűk írásmódjában (kisbetűs gépelésnél kisbetűvel).
            let lower = !prefix.isEmpty && prefix == prefix.lowercased() && prefix != prefix.uppercased()
            candidates += lower ? DBModel.keywords.map { $0.lowercased() } : DBModel.keywords
        }
        var seen = Set<String>()
        return candidates.filter { c in
            (prefix.isEmpty || c.lowercased().hasPrefix(prefix.lowercased())) && !same(c, prefix) && seen.insert(c.lowercased()).inserted
        }.prefix(60).map { $0 }
    }
}
