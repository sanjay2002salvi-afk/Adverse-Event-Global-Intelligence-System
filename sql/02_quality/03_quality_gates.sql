/* =============================================================================
   03_quality_gates.sql — executable data-quality assertions
   -----------------------------------------------------------------------------
   A dashboard that cannot tell you when its inputs are broken is a liability,
   not an asset. Every check below writes a row to dq_results with a measured
   value, a threshold, and a PASS/WARN/FAIL verdict. The pipeline runner treats
   any FAIL as fatal and refuses to publish to the BI layer.

   The distinction that matters: a WARN describes a property of the SOURCE that
   we have measured and accepted (FAERS genuinely has ~12% missing sex — that is
   not our bug, but the dashboard must disclose it). A FAIL describes a property
   of OUR PIPELINE that should be impossible (an orphaned foreign key, a case
   counted twice) and means the run is wrong.

   Confusing "the data is dirty" with "my code is broken" is how bad numbers
   reach a slide. These are kept separate on purpose.
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS dq_results;
CREATE TABLE dq_results (
  check_id     VARCHAR(12)   NOT NULL PRIMARY KEY,
  check_name   VARCHAR(160)  NOT NULL,
  layer        VARCHAR(32)   NOT NULL,
  severity     ENUM('FAIL','WARN') NOT NULL
                 COMMENT 'FAIL = our pipeline is wrong. WARN = the source is dirty and we disclose it.',
  measured     DECIMAL(18,4) NOT NULL,
  threshold    DECIMAL(18,4) NOT NULL,
  comparison   ENUM('<=','>=','=') NOT NULL,
  status       VARCHAR(8)    NULL,
  detail       VARCHAR(400)  NULL,
  checked_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='One row per data-quality assertion, with evidence.';

/* ========================= INTEGRITY CHECKS (FAIL) ======================== */

-- DQ-000 — the analysis population must not be empty.
--   Every percentage gate below divides by this count. Without an explicit check
--   an empty population makes each of them NULL, and `measured` is NOT NULL, so
--   the gate designed to report "your inputs are broken" instead crashes the run
--   with a constraint error. Check the precondition first, in its own row.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-000', 'analysis population is non-empty', 'cleansed', 'FAIL',
       (SELECT COUNT(*) FROM case_master), 1, '>=',
       'Precondition for every percentage gate below. Guards against a silent empty load.';

-- DQ-001 — every case must be unique. If this trips, dedup is broken.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-001', 'case_master contains no duplicate caseid', 'cleansed', 'FAIL',
       (SELECT COUNT(*) FROM (SELECT caseid FROM case_master
                              GROUP BY caseid HAVING COUNT(*) > 1) d),
       0, '=', 'Enforced by PK; assertion exists to catch a future schema change that drops it.';

-- DQ-002 — no surviving case may be one FDA retracted.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-002', 'no retracted case survived into case_master', 'cleansed', 'FAIL',
       (SELECT COUNT(*) FROM case_master cm
         WHERE cm.caseid IN (SELECT CAST(caseid AS UNSIGNED) FROM stg_deleted_cases
                              WHERE caseid REGEXP '^[0-9]+$')),
       0, '=', 'FDA deleted-cases file must be honoured or the denominator is inflated forever.';

-- DQ-003 — the surviving version must be the highest version of its case.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-003', 'surviving version equals MAX(caseversion) for its case', 'cleansed', 'FAIL',
       (SELECT COUNT(*)
          FROM case_master cm
          JOIN (SELECT CAST(caseid AS UNSIGNED) cid,
                       MAX(CAST(caseversion AS UNSIGNED)) mx
                  FROM stg_demo WHERE caseid REGEXP '^[0-9]+$'
                    AND caseversion REGEXP '^[0-9]+$'
                 GROUP BY 1) m ON m.cid = cm.caseid
         WHERE cm.caseversion <> m.mx),
       0, '=', 'Guards against lexical-vs-numeric sort bug on caseversion (10 < 9 as text).';

-- DQ-004 — every case in the analysis population must carry >=1 reaction.
--          A case with no reaction contributes to the denominator but can never
--          contribute to a numerator, which biases every PRR downward.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-004', 'share of surviving cases with zero reaction terms', 'cleansed', 'FAIL',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM case_master cm
                       WHERE NOT EXISTS (SELECT 1 FROM stg_reac r
                                          WHERE CAST(r.primaryid AS UNSIGNED) = cm.primaryid))
             / NULLIF((SELECT COUNT(*) FROM case_master), 0), 4), 0),
       1.0, '<=', 'Reaction-less cases silently deflate every disproportionality statistic.';

-- DQ-005 — every case in the analysis population must carry >=1 drug.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-005', 'share of surviving cases with zero drug rows', 'cleansed', 'FAIL',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM case_master cm
                       WHERE NOT EXISTS (SELECT 1 FROM stg_drug d
                                          WHERE CAST(d.primaryid AS UNSIGNED) = cm.primaryid))
             / NULLIF((SELECT COUNT(*) FROM case_master), 0), 4), 0),
       1.0, '<=', 'Same reasoning as DQ-004, on the exposure side of the 2x2 table.';

/* ====================== SOURCE-DIRTINESS CHECKS (WARN) =================== */

-- DQ-006 — field shift caused by unescaped '$' inside free-text drug names.
--
--   The detector must be a closed-domain column positioned AFTER the free-text
--   column that causes the shift. This is not a subtlety — it is the whole
--   check. The first version of this gate tested role_cod and reported exactly
--   0.0000 on a corpus with a known 3% corruption rate. role_cod is column 4;
--   drugname is column 5. A delimiter injected into column 5 cannot disturb
--   column 4, so that gate was structurally incapable of ever firing.
--
--   val_vbm (column 7) is the right probe: its domain is {1, 2, empty}, and on
--   a shifted row it receives the active-ingredient string instead. route
--   (column 8) corroborates by receiving the numeric val_vbm value.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-006', 'stg_drug rows with val_vbm outside its closed domain (field shift)', 'staging', 'WARN',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM stg_drug
                       WHERE val_vbm IS NOT NULL AND val_vbm <> ''
                         AND val_vbm NOT IN ('1','2'))
             / NULLIF((SELECT COUNT(*) FROM stg_drug), 0), 4), 0),
       6.0, '<=', 'Unescaped $ in reporter free text shifts every LATER field. Probe must sit after drugname.';

-- DQ-006b — corroborating probe one column further along.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-006b', 'stg_drug rows whose route holds a numeric val_vbm value (shift corroboration)', 'staging', 'WARN',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM stg_drug WHERE route IN ('1','2'))
             / NULLIF((SELECT COUNT(*) FROM stg_drug), 0), 4), 0),
       6.0, '<=', 'Reads HIGHER than DQ-006 by design: see note below. Use this as the true shift rate.';
/*  Why DQ-006b exceeds DQ-006, and why that is correct rather than a bug:
    prod_ai is populated in only ~55% of source rows. On a shifted row the probe
    column val_vbm receives whatever prod_ai held — and when prod_ai was blank,
    val_vbm receives an empty string, which DQ-006 deliberately excludes from its
    domain test. So DQ-006 systematically under-detects by the prod_ai blank rate.
    route, one column further along, receives the ALWAYS-populated val_vbm value,
    so DQ-006b recovers the full shift rate.
    Rule of thumb this generalises to: a domain probe is only as sensitive as the
    fill rate of the column that shifts INTO it. Choose densely-populated probes. */

-- DQ-007 — missing sex. A real and well-documented FAERS property.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-007', 'share of cases with unknown or missing sex', 'cleansed', 'WARN',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM case_master
                       WHERE sex_raw IS NULL OR sex_raw = '' OR sex_raw = 'UNK')
             / NULLIF((SELECT COUNT(*) FROM case_master), 0), 4), 0),
       40.0, '<=', 'Disclosed on the dashboard. Stratified analyses must exclude, not impute.';

-- DQ-008 — missing or partial event dates.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-008', 'share of cases whose event date is absent or not full precision', 'cleansed', 'WARN',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM case_master
                       WHERE event_dt_raw IS NULL OR event_dt_raw = ''
                          OR NOT event_dt_raw REGEXP '^[0-9]{8}$')
             / NULLIF((SELECT COUNT(*) FROM case_master), 0), 4), 0),
       55.0, '<=', 'Why the time series is keyed on FDA receipt date, not event onset date.';

-- DQ-009 — blank drug names, which cannot be standardised to an ingredient.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-009', 'share of drug rows with an empty drugname', 'staging', 'WARN',
       COALESCE(ROUND(100.0 * (SELECT COUNT(*) FROM stg_drug WHERE drugname IS NULL OR TRIM(drugname) = '')
             / NULLIF((SELECT COUNT(*) FROM stg_drug), 0), 4), 0),
       2.0, '<=', 'Unmappable exposures. Counted and excluded, never guessed at.';

-- DQ-010 — implausible ages, indicating a unit or field-shift error.
INSERT INTO dq_results (check_id, check_name, layer, severity, measured, threshold, comparison, detail)
SELECT 'DQ-010', 'cases reporting age > 120 years', 'cleansed', 'WARN',
       (SELECT COUNT(*) FROM case_master
         WHERE age_cod = 'YR' AND age_raw REGEXP '^[0-9]+(\\.[0-9]+)?$'
           AND CAST(age_raw AS DECIMAL(10,2)) > 120),
       500, '<=', 'Classic age/age_cod mismatch: 45 DEC (decades) misread as 45 YR.';

/* ============================== VERDICT ================================== */
UPDATE dq_results
SET status = CASE
      WHEN comparison = '='  AND measured =  threshold THEN 'PASS'
      WHEN comparison = '<=' AND measured <= threshold THEN 'PASS'
      WHEN comparison = '>=' AND measured >= threshold THEN 'PASS'
      ELSE severity
    END;

SELECT check_id, status, severity, measured, comparison, threshold, check_name
FROM dq_results ORDER BY check_id;

SELECT
  SUM(status = 'PASS') AS passed,
  SUM(status = 'WARN') AS warned,
  SUM(status = 'FAIL') AS failed
FROM dq_results;
