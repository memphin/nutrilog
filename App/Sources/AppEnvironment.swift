import Foundation
import Observation
import Persistence

/// Dependency container shared through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    enum DatabaseState {
        case ready(AppDatabase)
        case failed(String)
    }

    let database: DatabaseState
    let config: AppConfig

    init(database: DatabaseState, config: AppConfig) {
        self.database = database
        self.config = config
    }

    /// Production environment: on-disk database in Application Support.
    static func live(bundle: Bundle = .main) -> AppEnvironment {
        let state: DatabaseState
        do {
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Database", isDirectory: true)
            state = try .ready(AppDatabase.onDisk(directory: dir))
        } catch {
            state = .failed(String(describing: error))
        }
        return AppEnvironment(database: state, config: AppConfig(bundle: bundle))
    }

    /// In-memory environment for tests and previews.
    static func preview() -> AppEnvironment {
        let state: DatabaseState
        do { state = try .ready(AppDatabase.inMemory()) } catch { state = .failed(String(describing: error)) }
        return AppEnvironment(database: state, config: AppConfig(usdaAPIKey: nil, offUserAgent: AppConfig.defaultUserAgent))
    }
}
