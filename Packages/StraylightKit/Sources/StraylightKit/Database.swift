import Foundation
import SQLite3

/// A small wrapper over the system SQLite library, enough for the history
/// store. Not thread-safe: `History` uses it from one queue.
final class Database {
    enum Value: Equatable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case null

        var int: Int? {
            switch self {
            case .integer(let value): Int(value)
            case .real(let value): Int(value)
            default: nil
            }
        }

        var double: Double? {
            switch self {
            case .integer(let value): Double(value)
            case .real(let value): value
            default: nil
            }
        }

        var string: String? {
            if case .text(let value) = self { value } else { nil }
        }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// SQLite copies bound text before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `nil` opens a private in-memory database, for tests.
    init(path: String?) throws {
        let status = sqlite3_open_v2(path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(handle)
            throw Error(description: "open: \(message)")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error("execute") }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error("run") }
    }

    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        var rows: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            case SQLITE_DONE:
                return rows
            default:
                throw error("query")
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.first?.int) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw error("prepare") }
            statements[sql] = prepared
            statement = prepared
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
        default: .null
        }
    }

    private func error(_ operation: String) -> Error {
        Error(description: "\(operation): \(String(cString: sqlite3_errmsg(handle)))")
    }
}

extension Database.Value {
    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
}
