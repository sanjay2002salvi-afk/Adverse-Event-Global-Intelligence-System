/* =============================================================================
   AEGIS — Adverse Event Global Intelligence System
   00_create_database.sql — database, character set, and session baseline
   -----------------------------------------------------------------------------
   Run first. Everything downstream assumes this has executed.

   Character set note: FAERS free-text drug names contain non-ASCII characters
   (accented ingredient names, micro sign in dose units, occasional CJK from
   foreign reporters). utf8mb4 is mandatory; utf8mb3 silently truncates them
   and corrupts the drug-name standardisation layer.

   Collation note: we use utf8mb4_0900_as_ci — accent-SENSITIVE, case-insensitive.
   Accent-insensitive collation would merge distinct ingredients whose names
   differ only by diacritic, which is a real (if rare) correctness bug.
   ========================================================================== */

DROP DATABASE IF EXISTS aegis;
CREATE DATABASE aegis
  CHARACTER SET utf8mb4
  COLLATE       utf8mb4_0900_as_ci;

USE aegis;

/* -----------------------------------------------------------------------------
   Pipeline run ledger.
   Every executed stage writes one row here. This is what makes the pipeline
   auditable: given any number in the dashboard you can trace which run produced
   it, how long it took, and how many rows it touched.
   -------------------------------------------------------------------------- */
CREATE TABLE etl_run_log (
  run_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  stage         VARCHAR(64)     NOT NULL COMMENT 'e.g. stage_load, dedup, dim_drug, signal_calc',
  object_name   VARCHAR(128)    NULL     COMMENT 'table or procedure acted upon',
  quarter_code  CHAR(6)         NULL     COMMENT 'FAERS quarter, e.g. 2024Q3; NULL for whole-DB stages',
  rows_in       BIGINT          NULL,
  rows_out      BIGINT          NULL,
  started_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  finished_at   DATETIME(3)     NULL,
  duration_ms   BIGINT GENERATED ALWAYS AS
                  (TIMESTAMPDIFF(MICROSECOND, started_at, finished_at) / 1000) STORED,
  status        ENUM('RUNNING','SUCCESS','FAILED') NOT NULL DEFAULT 'RUNNING',
  message       TEXT            NULL,
  PRIMARY KEY (run_id),
  KEY ix_run_stage (stage, started_at),
  KEY ix_run_quarter (quarter_code)
) ENGINE=InnoDB
  COMMENT='Audit trail: one row per pipeline stage execution.';

/* -----------------------------------------------------------------------------
   Ingestion ledger.
   Tracks which FAERS quarters have been loaded and their source file checksums.
   etl/load_staging.py compares the checksum before loading and skips a file
   whose bytes are unchanged; a changed file is deleted and reloaded for that
   quarter, so either path leaves the staging tables idempotent. Pass --force to
   reload regardless.

   The checksum, rather than the filename or the row count, is the comparison
   that matters: FDA silently restates old quarters, republishing the same
   filename with different contents. A loader keyed on filename would never
   notice, and the restated quarter would sit in the warehouse indefinitely
   holding the superseded numbers.

   In a full `run_pipeline.py` run this ledger starts empty, because stage 00
   drops the database — the skip is there for incremental loads, where you add
   one new quarter to a warehouse that already holds twenty-four.
   -------------------------------------------------------------------------- */
CREATE TABLE ingest_ledger (
  quarter_code  CHAR(6)      NOT NULL COMMENT 'e.g. 2024Q3',
  file_kind     VARCHAR(16)  NOT NULL COMMENT 'DEMO|DRUG|REAC|OUTC|RPSR|THER|INDI|DELETED',
  source_file   VARCHAR(255) NOT NULL,
  sha256        CHAR(64)     NOT NULL,
  row_count     BIGINT       NOT NULL,
  loaded_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (quarter_code, file_kind),
  KEY ix_ingest_sha (sha256)
) ENGINE=InnoDB
  COMMENT='Which FAERS quarters/files are loaded, with checksums for idempotent reload.';

SELECT 'aegis database created' AS status;
