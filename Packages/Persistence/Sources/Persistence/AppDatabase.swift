import Foundation
import GRDB

/// Entry point to the on-device SQLite database.
/// Uses a `DatabasePool` (WAL mode) so SwiftUI observation reads never block writes.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrator.make().migrate(writer)
    }

    /// Production database inside the app container, protected until first unlock.
    public static func onDisk(directory: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The file keeps the app's former name (Nutrilog) so installed copies open their existing data.
        let url = directory.appendingPathComponent("nutrilog.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path,
            )
        #endif
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and SwiftUI previews.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    public var reader: any DatabaseReader {
        writer
    }

    /// `fetch`'s value now and after every change to what it read, skipping values equal to the previous one — the
    /// observation behind every repository's `observe…` method.
    func observe<Value: Equatable>(_ fetch: @escaping @Sendable (Database) throws -> Value) -> AsyncValueObservation<Value> {
        ValueObservation.tracking(fetch).removeDuplicates().values(in: reader)
    }
}
