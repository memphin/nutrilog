import Foundation

/// Automatic local backups (FR-62, backlog #41): a full JSON export written to a folder in the app container about
/// once a week, keeping the newest seven. They guard against a bad import or a bug, not against losing the phone —
/// for that, export and store the file elsewhere.
public struct LocalBackups: Sendable {
    public struct Backup: Hashable, Identifiable, Sendable {
        public var url: URL
        public var createdAt: Date
        public var sizeBytes: Int

        public var id: URL {
            url
        }
    }

    /// Backups kept; older ones are removed after each new one.
    public static let keep = 7
    /// A new automatic backup is due this long after the last one.
    public static let interval: TimeInterval = 7 * 86400
    static let prefix = "vitalion-backup-"
    /// Backups written while the app was named Nutrilog: still listed, restorable and pruned.
    static let legacyPrefixes = ["nutrilog-backup-"]

    let directory: URL
    let portability: DataPortability
    let clock: AppClock

    public init(directory: URL, portability: DataPortability, clock: AppClock = .system) {
        self.directory = directory
        self.portability = portability
        self.clock = clock
    }

    /// Backups in the folder, newest first. Files that aren't backups are ignored.
    public func list() throws -> [Backup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return urls.compactMap { url -> Backup? in
            guard let date = Self.date(fromFileName: url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Backup(url: url, createdAt: date, sizeBytes: size)
        }
        .sorted { ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent) }
    }

    /// Writes a backup now and removes all but the newest `keep`.
    @discardableResult
    public func backupNow() throws -> Backup {
        let now = clock.now()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: now))
        let data = try portability.exportJSON()
        try data.write(to: url, options: .atomic)
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path,
            )
        #endif
        for old in try list().dropFirst(Self.keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return Backup(url: url, createdAt: Self.date(fromFileName: url.lastPathComponent) ?? now, sizeBytes: data.count)
    }

    /// Writes a backup when there is none yet or the newest is at least `interval` old. Returns it, or nil when
    /// none was due.
    @discardableResult
    public func backupIfDue() throws -> Backup? {
        if let latest = try list().first, clock.now().timeIntervalSince(latest.createdAt) < Self.interval {
            return nil
        }
        return try backupNow()
    }

    /// Replaces all data with the backup's (like Import → Replace).
    @discardableResult
    public func restore(_ backup: Backup) throws -> DataPortability.ImportSummary {
        try portability.importJSON(Data(contentsOf: backup.url), mode: .replace)
    }

    public func delete(_ backup: Backup) throws {
        try FileManager.default.removeItem(at: backup.url)
    }

    // MARK: File names — "vitalion-backup-20261109T140312Z.json" (UTC)

    static func fileName(for date: Date) -> String {
        prefix + formatter().string(from: date) + ".json"
    }

    static func date(fromFileName name: String) -> Date? {
        guard name.hasSuffix(".json"), let used = ([prefix] + legacyPrefixes).first(where: name.hasPrefix) else { return nil }
        return formatter().date(from: String(name.dropFirst(used.count).dropLast(".json".count)))
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }
}
