import Foundation
import GRDB

public extension DailyMetricsRepository {
    /// The ids Vitalion's own weight, body-fat and water samples in Health may carry as external id
    /// (`HKMetadataKeyExternalUUID`) while their local row still accounts for them: every `weight_entry` and
    /// `water_entry`, soft-deleted ones included (their samples may still be waiting to be deleted from Health), plus
    /// weight and water rows that are still linked or queued for Health (a replace import removed the row, the outbox
    /// has yet to delete its samples).
    ///
    /// Health sync leaves own samples with these ids out of `daily_metrics`; own samples with any other id (written by
    /// an earlier install whose rows are gone) are read like data from other apps.
    func localHealthSampleIDs() throws -> Set<String> {
        try database.reader.read { db in
            try Set(String.fetchAll(db, sql: """
            SELECT id FROM weight_entry
            UNION SELECT id FROM water_entry
            UNION SELECT owner_id FROM healthkit_link WHERE owner_table IN ('weight_entry', 'water_entry')
            UNION SELECT owner_id FROM healthkit_outbox WHERE owner_table IN ('weight_entry', 'water_entry')
            """))
        }
    }
}
