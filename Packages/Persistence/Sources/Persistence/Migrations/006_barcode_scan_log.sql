-- Local scan log for the barcode resolution rate (backlog #30, SPEC §1.3): one row per scan resolution, plus a
-- 'created' row when a food is created for a code the scan couldn't resolve. Private diagnostics on this device:
-- no sync columns, never exported (see DataPortability.tables), cleared from Settings → Barcode resolution.
CREATE TABLE barcode_scan_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    scanned_at      TEXT NOT NULL,
    barcode         TEXT NOT NULL,                    -- normalized key (EAN-13 / EAN-8)
    outcome         TEXT NOT NULL CHECK (outcome IN ('local','off_network','off_cache','off_stale_cache',
                                                     'not_found','offline','unavailable','created')),
    data_quality    TEXT CHECK (data_quality IN ('complete','partial_macros','energy_only'))
);
CREATE INDEX idx_barcode_scan_log_scanned ON barcode_scan_log(scanned_at);
