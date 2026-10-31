import Foundation
import SQLite3

/// Wrapper mínimo do SQLite. Não é thread-safe: cada instância deve ser usada por uma única fila.
final class SQLiteDB {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
    }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    /// Executa um comando com parâmetros (INSERT/UPDATE/DELETE). Statements são reaproveitados.
    func run(_ sql: String, _ args: Any?...) {
        guard let statement = prepare(sql, args) else { return }
        sqlite3_step(statement)
        sqlite3_reset(statement)
    }

    func query(_ sql: String, _ args: Any?...) -> [Row] {
        guard let statement = prepare(sql, args) else { return [] }
        defer { sqlite3_reset(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Row(statement: statement))
        }
        return rows
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var statement = statements[sql]
        if statement == nil {
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                NSLog("MacPet SQLite: \(String(cString: sqlite3_errmsg(db))) em \(sql)")
                return nil
            }
            statements[sql] = statement
        }
        sqlite3_clear_bindings(statement)
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            switch arg {
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as Double: sqlite3_bind_double(statement, position, value)
            case let value as String: sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case let value as Bool: sqlite3_bind_int(statement, position, value ? 1 : 0)
            default: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    struct Row {
        private let values: [Any?]

        fileprivate init(statement: OpaquePointer?) {
            values = (0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: return sqlite3_column_double(statement, index)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, index))
                default: return nil
                }
            }
        }

        func int(_ index: Int) -> Int { (values[index] as? Int) ?? Int((values[index] as? Double) ?? 0) }
        func double(_ index: Int) -> Double { (values[index] as? Double) ?? Double((values[index] as? Int) ?? 0) }
        func string(_ index: Int) -> String? { values[index] as? String }
    }
}

let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
