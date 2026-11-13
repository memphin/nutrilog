-- The barcode resolution diagnostics are gone (v1.12): drop their device-local scan log (006) and the scanned codes
-- it still holds. It was never exported or backed up (see DataPortability.tables), so no export refers to it.
DROP INDEX IF EXISTS idx_barcode_scan_log_scanned;
DROP TABLE IF EXISTS barcode_scan_log;
