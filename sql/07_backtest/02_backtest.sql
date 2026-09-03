/* =============================================================================
   02_backtest.sql — when would this pipeline have raised the alarm?
   -----------------------------------------------------------------------------
   The signal engine produces a metric series per (drug, reaction, quarter). The
   backtest asks the only question that makes that series useful:

       In which quarter did this pair FIRST cross the signal threshold?

   and then compares that quarter against a reference date.

   TWO MODES, because the honest reference date depends on the data source.

     MODE A — SYNTHETIC (backtest_vs_truth)
       Reference = the quarter the association was planted in the demo corpus.
       Measures DETECTION LAG: how many quarters of accumulating reports the
       engine needed before the planted association became statistically
       visible. This is a genuine performance characteristic and it is fully
       verifiable, because the truth is known by construction.

     MODE B — REAL FAERS (backtest_vs_fda)
       Reference = the documented FDA action date.
       Measures LEAD TIME between first detectable signal and regulatory action.

   WHY BOTH EXIST RATHER THAN JUST MODE B
   Running Mode B against the synthetic corpus would produce a number, and that
   number would be meaningless — the corpus plants associations in 2019-2020
   while the real FDA actions span 2008-2020, so the arithmetic would "work"
   while comparing fabricated report dates against real regulatory dates. The
   two modes are kept structurally separate so that mistake cannot be made by
   accident. Mode B refuses to report on synthetic data at all.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   First quarter each pair crossed the threshold.

   Uses the strict operating point (all three criteria agreeing) — the same
   threshold the dashboard uses. A backtest evaluated at a looser threshold than
   the product actually ships with would be measuring a system nobody runs.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS signal_first_detection;
CREATE TABLE signal_first_detection (
  drug_key            INT UNSIGNED NOT NULL,
  reaction_key        INT UNSIGNED NOT NULL,
  ingredient          VARCHAR(128) NOT NULL,
  pt                  VARCHAR(255) NOT NULL,
  first_signal_quarter CHAR(6)     NOT NULL,
  first_signal_date   DATE         NOT NULL COMMENT 'last day of that quarter — the earliest date the evidence was complete',
  a_at_detection      BIGINT       NOT NULL,
  prr_at_detection    DECIMAL(18,6) NULL,
  ic025_at_detection  DECIMAL(18,6) NULL,
  a_final             BIGINT       NOT NULL,
  last_signal_quarter CHAR(6)      NOT NULL COMMENT 'most recent quarter this pair met all three criteria',
  n_quarters_signalling INT        NOT NULL,
  is_sustained        TINYINT(1)   NOT NULL
                        COMMENT '1 = still signalling at the latest quarter. 0 = crossed once and decayed back below threshold.',
  PRIMARY KEY (drug_key, reaction_key),
  KEY ix_sfd_ing (ingredient, pt),
  KEY ix_sfd_sustained (is_sustained)
) ENGINE=InnoDB COMMENT='GRAIN: one row per pair that EVER signalled. is_sustained separates a live alert from a transient crossing.';

/* Two defensible definitions of "detected", and the difference is not academic.
   ------------------------------------------------------------------------
   EVER-FLAGGED  — the pair crossed all three thresholds in at least one
                   quarter. This is the right denominator for "how early could
                   this have been caught", which is what the lead-time analysis
                   asks. It is also permissive: a pair can cross on a run of
                   noise at low counts and drift back down as evidence
                   accumulates.
   SUSTAINED     — the pair is still above all three thresholds at the latest
                   quarter. This is what a safety team actually triages: the
                   alert list on the desk this morning.

   Reporting one number without saying which definition produced it is how a
   precision figure becomes unfalsifiable. Both are computed here, both are
   published, and the headline precision figure is stated against the sustained
   definition with the ever-flagged figure alongside it. On this corpus they
   differ by exactly one pair, and that pair is worth talking about — see the
   transient-crossing report at the end of this file. */
INSERT INTO signal_first_detection
WITH first_q AS (
  SELECT drug_key, reaction_key,
         MIN(as_of_quarter) AS first_signal_quarter,
         MAX(as_of_quarter) AS last_signal_quarter,
         COUNT(*)           AS n_quarters_signalling
  FROM signal_metrics_quarterly
  WHERE is_signal_strict = 1
  GROUP BY drug_key, reaction_key
),
final_q AS (
  SELECT drug_key, reaction_key, a AS a_final, is_signal_strict AS still_signalling
  FROM signal_metrics_quarterly
  WHERE as_of_quarter = (SELECT MAX(as_of_quarter) FROM signal_metrics_quarterly)
)
SELECT
  f.drug_key, f.reaction_key, dd.ingredient, dr.pt,
  f.first_signal_quarter,
  /* last day of the detection quarter: the signal is only computable once the
     quarter's reports have all arrived, so this is the earliest defensible date */
  LAST_DAY(MAKEDATE(CAST(LEFT(f.first_signal_quarter,4) AS UNSIGNED),1)
           + INTERVAL (CAST(RIGHT(f.first_signal_quarter,1) AS UNSIGNED)*3 - 1) MONTH),
  s.a, s.prr, s.ic025, fq.a_final,
  f.last_signal_quarter, f.n_quarters_signalling,
  COALESCE(fq.still_signalling, 0)
FROM first_q f
JOIN signal_metrics_quarterly s
     ON s.drug_key = f.drug_key AND s.reaction_key = f.reaction_key
    AND s.as_of_quarter = f.first_signal_quarter
JOIN final_q      fq ON fq.drug_key = f.drug_key AND fq.reaction_key = f.reaction_key
JOIN dim_drug     dd ON dd.drug_key = f.drug_key
JOIN dim_reaction dr ON dr.reaction_key = f.reaction_key;

/* =========================== MODE A — vs planted truth ==================== */
DROP TABLE IF EXISTS backtest_vs_truth;
CREATE TABLE backtest_vs_truth (
  ingredient        VARCHAR(128) NOT NULL,
  pt                VARCHAR(255) NOT NULL,
  emergence_quarter CHAR(6)      NOT NULL,
  detected_quarter  CHAR(6)      NULL,
  lag_quarters      INT          NULL COMMENT 'quarters from planted emergence to first detection',
  peak_excess_rate  DECIMAL(6,3) NOT NULL,
  a_at_detection    BIGINT       NULL,
  was_detected      TINYINT(1)   NOT NULL,
  PRIMARY KEY (ingredient, pt)
) ENGINE=InnoDB COMMENT='Synthetic-mode backtest: detection lag against planted emergence.';

INSERT INTO backtest_vs_truth
SELECT
  g.ingredient, g.pt, g.emergence_quarter, d.first_signal_quarter,
  CASE WHEN d.first_signal_quarter IS NOT NULL THEN
    (CAST(LEFT(d.first_signal_quarter,4) AS SIGNED) * 4
       + CAST(RIGHT(d.first_signal_quarter,1) AS SIGNED))
  - (CAST(LEFT(g.emergence_quarter,4)  AS SIGNED) * 4
       + CAST(RIGHT(g.emergence_quarter,1)  AS SIGNED))
  END,
  g.peak_excess_rate, d.a_at_detection,
  d.first_signal_quarter IS NOT NULL
FROM ground_truth_signals g
LEFT JOIN signal_first_detection d
       ON d.ingredient = g.ingredient AND d.pt = g.pt;

SELECT '=== MODE A: detection lag vs planted emergence (synthetic corpus) ===' AS report;

SELECT
  COUNT(*)                                     AS planted_pairs,
  SUM(was_detected)                            AS detected,
  ROUND(100.0*SUM(was_detected)/COUNT(*),1)    AS detection_rate_pct,
  MIN(lag_quarters)                            AS min_lag_q,
  ROUND(AVG(lag_quarters),2)                   AS mean_lag_q,
  MAX(lag_quarters)                            AS max_lag_q
FROM backtest_vs_truth;

SELECT ingredient, pt, emergence_quarter, detected_quarter, lag_quarters,
       peak_excess_rate, a_at_detection
FROM backtest_vs_truth
ORDER BY lag_quarters, peak_excess_rate DESC;

/* =========================== MODE B — vs FDA actions ===================== */
DROP TABLE IF EXISTS backtest_vs_fda;
CREATE TABLE backtest_vs_fda (
  ingredient          VARCHAR(128) NOT NULL,
  pt                  VARCHAR(255) NOT NULL,
  action_type         VARCHAR(48)  NOT NULL,
  action_date         DATE         NOT NULL,
  first_signal_date   DATE         NULL,
  lead_time_months    INT          NULL COMMENT 'positive = signal detectable before FDA acted',
  a_at_detection      BIGINT       NULL,
  detected            TINYINT(1)   NOT NULL,
  PRIMARY KEY (ingredient, pt, action_type)
) ENGINE=InnoDB COMMENT='Real-data-mode backtest. Meaningless unless staging holds genuine FAERS.';

INSERT INTO backtest_vs_fda
SELECT
  r.ingredient, r.pt, r.action_type, r.action_date,
  d.first_signal_date,
  CASE WHEN d.first_signal_date IS NOT NULL
       THEN TIMESTAMPDIFF(MONTH, d.first_signal_date, r.action_date) END,
  d.a_at_detection,
  d.first_signal_date IS NOT NULL
FROM ref_fda_safety_actions r
LEFT JOIN signal_first_detection d
       ON d.ingredient = r.ingredient AND d.pt = r.pt
WHERE r.action_date IS NOT NULL
  /* Guard the INSERT, not only the report below it. Populating this table in
     demo mode would leave lead times computed from fabricated receipt dates
     against real FDA action dates sitting in the database, where a Power BI
     user or a curious reader would find them with no warning attached. An
     empty table is the honest state when the input is synthetic. */
  AND (SELECT COUNT(*) FROM ground_truth_signals) = 0;

SELECT '=== MODE B: lead time vs FDA action (REAL DATA ONLY) ===' AS report;

/* Guard: refuse to present Mode B numbers when the loaded data is synthetic.
   The demo corpus starts in 2019 while most reference actions predate it, so
   any lead time computed here would be an artefact of the fixture. */
SELECT
  CASE
    WHEN (SELECT COUNT(*) FROM ground_truth_signals) > 0 THEN
      'SUPPRESSED — synthetic corpus loaded. Mode B requires real FAERS data. '
      'Run etl/download_faers.py + etl/load_staging.py, then re-run this file.'
    ELSE 'Real data detected; lead-time statistics below are meaningful.'
  END AS mode_b_status;

SELECT
  COUNT(*)                                  AS reference_pairs_dated,
  SUM(detected)                             AS detected,
  ROUND(AVG(CASE WHEN detected THEN lead_time_months END), 1) AS mean_lead_months,
  MAX(lead_time_months)                     AS max_lead_months,
  MIN(lead_time_months)                     AS min_lead_months
FROM backtest_vs_fda
WHERE (SELECT COUNT(*) FROM ground_truth_signals) = 0;

/* ===================== TRANSIENT CROSSINGS — reported, not hidden ========= */
/* A pair that crossed all three thresholds at some quarter and has since
   decayed below them. These are the difference between the ever-flagged and
   sustained precision figures. Publishing them is the point: a reader can
   check the claim against bi_signal_timeseries rather than take it on trust. */
SELECT '=== TRANSIENT CROSSINGS (ever-flagged but not sustained) ===' AS report;
SELECT
  d.ingredient, d.pt,
  d.first_signal_quarter, d.last_signal_quarter, d.n_quarters_signalling,
  d.a_at_detection, ROUND(d.prr_at_detection,2) AS prr_at_detection,
  ROUND(d.ic025_at_detection,3)                 AS ic025_at_detection,
  ROUND(c.prr,2)   AS prr_now,
  ROUND(c.ic025,3) AS ic025_now,
  CASE WHEN g.ingredient IS NULL THEN 'not planted' ELSE 'planted' END AS ground_truth
FROM signal_first_detection d
JOIN signal_metrics_quarterly c
     ON c.drug_key = d.drug_key AND c.reaction_key = d.reaction_key
    AND c.as_of_quarter = (SELECT MAX(as_of_quarter) FROM signal_metrics_quarterly)
LEFT JOIN ground_truth_signals g ON g.ingredient = d.ingredient AND g.pt = d.pt
WHERE d.is_sustained = 0
ORDER BY d.ingredient, d.pt;

SELECT
  SUM(is_sustained)          AS sustained_signals,
  SUM(is_sustained = 0)      AS transient_crossings,
  COUNT(*)                   AS ever_flagged
FROM signal_first_detection;
