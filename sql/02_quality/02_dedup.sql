/* =============================================================================
   02_dedup.sql — case-version resolution and retraction handling
   -----------------------------------------------------------------------------
   THIS FILE IS THE SINGLE MOST IMPORTANT CORRECTNESS STEP IN THE PROJECT.

   FAERS is a *versioned* dataset, and almost every published FAERS analysis
   gets this wrong. Three distinct traps:

   TRAP 1 — CASE VERSIONS ARE NOT DISTINCT CASES.
     When a case is amended (new information from the reporter, a follow-up
     from the manufacturer), FDA republishes the ENTIRE case with the same
     caseid and an incremented caseversion. Both rows sit in the extract. If
     you count rows, an amended case counts twice, a thrice-amended case three
     times. Since amendment is more likely for *serious* cases, this bias is
     not random — it systematically inflates exactly the events we care about,
     and inflates them differently for different drugs. The fix is to keep only
     MAX(caseversion) per caseid.

   TRAP 2 — VERSIONS SPAN QUARTERS.
     A case first reported in 2019Q1 and amended in 2021Q3 appears in BOTH
     quarterly files. Deduplicating within a quarter is not enough; the MAX
     must be taken across the entire loaded window. This is why case_master is
     rebuilt from all of stg_demo rather than incrementally per quarter.

   TRAP 3 — FDA RETRACTS CASES.
     Each quarter ships a deleted-cases file listing caseids FDA has withdrawn
     (duplicates, invalid submissions, cases that were never real). They are
     NOT removed from previously published quarters. If you ignore the file,
     retracted reports stay in your denominator and your numerator forever.

   OUTPUT: case_master — exactly one row per real, surviving case. Every
   downstream table joins through it. Nothing else may read stg_demo directly.
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS case_master;
CREATE TABLE case_master (
  caseid          BIGINT UNSIGNED NOT NULL COMMENT 'stable case identifier',
  primaryid       BIGINT UNSIGNED NOT NULL COMMENT 'primaryid of the SURVIVING version',
  caseversion     SMALLINT UNSIGNED NOT NULL,
  n_versions      SMALLINT UNSIGNED NOT NULL COMMENT 'how many versions existed; >1 means amended',
  src_quarter     CHAR(6)      NOT NULL COMMENT 'quarter of the surviving version',
  first_quarter   CHAR(6)      NOT NULL COMMENT 'quarter the case first appeared',
  fda_dt_raw      VARCHAR(16)  NULL COMMENT 'receipt date of the SURVIVING (amended) version',
  init_fda_dt_raw VARCHAR(16)  NULL COMMENT 'date FDA FIRST received the case — this is what the time series must key on',
  event_dt_raw    VARCHAR(16)  NULL,
  age_raw         VARCHAR(32)  NULL,
  age_cod         VARCHAR(8)   NULL,
  sex_raw         VARCHAR(8)   NULL,
  wt_raw          VARCHAR(32)  NULL,
  wt_cod          VARCHAR(8)   NULL,
  occp_cod        VARCHAR(16)  NULL,
  rept_cod        VARCHAR(16)  NULL,
  occr_country    VARCHAR(64)  NULL,
  mfr_sndr        VARCHAR(255) NULL,
  PRIMARY KEY (caseid),
  UNIQUE KEY uq_primaryid (primaryid),
  KEY ix_cm_quarter (src_quarter),
  KEY ix_cm_first_quarter (first_quarter)
) ENGINE=InnoDB
  COMMENT='One row per surviving case. THE join spine. Never bypass this table.';

/* -----------------------------------------------------------------------------
   Rank versions per case and keep the highest.

   ORDER BY on a CAST is deliberate: caseversion is a text column in staging and
   a lexical sort puts '10' before '9', which would silently keep the WRONG
   version for any case amended more than nine times. Rare, but wrong is wrong.

   The tie-break on primaryid guarantees determinism if a quarter ever ships two
   rows at the same version (it happens; FDA restates).
   -------------------------------------------------------------------------- */
INSERT INTO case_master
  (caseid, primaryid, caseversion, n_versions, src_quarter, first_quarter,
   fda_dt_raw, init_fda_dt_raw, event_dt_raw, age_raw, age_cod, sex_raw, wt_raw, wt_cod,
   occp_cod, rept_cod, occr_country, mfr_sndr)
WITH ranked AS (
  SELECT
      CAST(d.caseid AS UNSIGNED)                        AS caseid,
      CAST(d.primaryid AS UNSIGNED)                     AS primaryid,
      CAST(d.caseversion AS UNSIGNED)                   AS caseversion,
      d.src_quarter, d.fda_dt, d.init_fda_dt, d.event_dt, d.age, d.age_cod, d.sex,
      d.wt, d.wt_cod, d.occp_cod, d.rept_cod, d.occr_country, d.mfr_sndr,
      ROW_NUMBER() OVER (
        PARTITION BY CAST(d.caseid AS UNSIGNED)
        ORDER BY CAST(d.caseversion AS UNSIGNED) DESC,
                 CAST(d.primaryid  AS UNSIGNED) DESC
      )                                                 AS rn,
      COUNT(*)    OVER (PARTITION BY CAST(d.caseid AS UNSIGNED)) AS n_versions,
      MIN(d.src_quarter) OVER (PARTITION BY CAST(d.caseid AS UNSIGNED)) AS first_quarter
  FROM stg_demo d
  WHERE d.caseid      REGEXP '^[0-9]+$'      -- reject rows corrupted by field shift
    AND d.primaryid   REGEXP '^[0-9]+$'
    AND d.caseversion REGEXP '^[0-9]+$'
)
SELECT caseid, primaryid, caseversion, n_versions, src_quarter, first_quarter,
       fda_dt, init_fda_dt, event_dt, age, age_cod, sex, wt, wt_cod,
       occp_cod, rept_cod, occr_country, mfr_sndr
FROM ranked
WHERE rn = 1
  /* TRAP 3: honour FDA retractions */
  AND caseid NOT IN (
      SELECT CAST(caseid AS UNSIGNED)
      FROM stg_deleted_cases
      WHERE caseid REGEXP '^[0-9]+$'
  );

/* -----------------------------------------------------------------------------
   Record what the dedup actually removed. These numbers are quoted in the
   README, so they must come from the database, not from memory.
   -------------------------------------------------------------------------- */
DROP TABLE IF EXISTS dedup_summary;
CREATE TABLE dedup_summary (
  metric      VARCHAR(64) NOT NULL PRIMARY KEY,
  value       BIGINT      NOT NULL,
  pct_of_raw  DECIMAL(6,3) NULL,
  note        VARCHAR(255) NULL
) ENGINE=InnoDB COMMENT='Provenance for the row-reduction figures quoted in the README.';

INSERT INTO dedup_summary (metric, value, note) VALUES
  ('raw_demo_rows',
   (SELECT COUNT(*) FROM stg_demo),
   'every case VERSION as shipped by FDA'),
  ('rows_rejected_nonnumeric_key',
   (SELECT COUNT(*) FROM stg_demo
     WHERE NOT (caseid REGEXP '^[0-9]+$' AND primaryid REGEXP '^[0-9]+$'
                AND caseversion REGEXP '^[0-9]+$')),
   'field shift from unescaped $ in free text'),
  ('distinct_cases_before_deletion',
   (SELECT COUNT(DISTINCT CAST(caseid AS UNSIGNED)) FROM stg_demo
     WHERE caseid REGEXP '^[0-9]+$'),
   'after collapsing versions, before honouring retractions'),
  ('retracted_cases_removed',
   (SELECT COUNT(DISTINCT CAST(caseid AS UNSIGNED)) FROM stg_deleted_cases
     WHERE caseid REGEXP '^[0-9]+$'
       AND CAST(caseid AS UNSIGNED) IN (SELECT DISTINCT CAST(caseid AS UNSIGNED)
                                        FROM stg_demo WHERE caseid REGEXP '^[0-9]+$')),
   'listed in FDA deleted-cases file AND present in our window'),
  ('surviving_cases',
   (SELECT COUNT(*) FROM case_master),
   'final analysis population'),
  ('amended_cases',
   (SELECT COUNT(*) FROM case_master WHERE n_versions > 1),
   'cases that had at least one follow-up version');

UPDATE dedup_summary
SET pct_of_raw = ROUND(100.0 * value /
      NULLIF((SELECT value FROM (SELECT value FROM dedup_summary
              WHERE metric = 'raw_demo_rows') x), 0), 3);

SELECT * FROM dedup_summary ORDER BY FIELD(metric,
  'raw_demo_rows','rows_rejected_nonnumeric_key','distinct_cases_before_deletion',
  'retracted_cases_removed','surviving_cases','amended_cases');
