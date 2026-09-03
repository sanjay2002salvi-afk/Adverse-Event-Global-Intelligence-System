/* =============================================================================
   01_bi_layer.sql — the semantic layer Power BI imports
   -----------------------------------------------------------------------------
   MATERIALISED TABLES, NOT VIEWS. MySQL has no materialized views, and a plain
   view is re-executed on every read. Power BI's import refresh would re-run the
   full join graph for each visual's source query, turning a 20-second refresh
   into minutes. Building narrow physical tables here and letting Power BI import
   them keeps refresh fast and moves the aggregation cost to the pipeline, where
   it is paid once per load rather than once per refresh.

   This is the standard workaround for MySQL's missing materialized views. The
   refresh contract is simply that run_pipeline.py rebuilds these tables in the
   same run that rebuilds the fact table, so they can never drift apart.

   MODEL SHAPE (star, for VertiPaq):

        dim_drug ─┐
                  ├─→ bi_signal_current  ←─ dim_reaction
     dim_quarter ─┤
                  └─→ bi_signal_timeseries

   Deliberately NOT exposed to Power BI: fact_drug_reaction (3.1M rows) and the
   staging tables. The dashboard never needs case-level grain, and importing it
   would inflate the model by two orders of magnitude for no analytical gain.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   dim_quarter — 25 rows, not the 9,131-row dim_date.
   Every signal metric is quarterly. Relating a quarterly fact to a daily date
   dimension forces Power BI to either aggregate 91 days per point or build a
   many-to-one on a non-key, both of which are slower and easier to get wrong.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS dim_quarter;
CREATE TABLE dim_quarter (
  quarter_code  CHAR(6)  NOT NULL PRIMARY KEY,
  quarter_ord   INT      NOT NULL COMMENT 'sortable integer; text sort breaks at 2019Q4 -> 2020Q1 boundaries in some locales',
  year_num      SMALLINT NOT NULL,
  quarter_num   TINYINT  NOT NULL,
  quarter_start DATE     NOT NULL,
  quarter_end   DATE     NOT NULL,
  KEY ix_dq_ord (quarter_ord)
) ENGINE=InnoDB COMMENT='GRAIN: one row per calendar quarter present in the data.';

INSERT INTO dim_quarter
SELECT DISTINCT
  quarter_code,
  CAST(LEFT(quarter_code,4) AS SIGNED)*4 + CAST(RIGHT(quarter_code,1) AS SIGNED),
  CAST(LEFT(quarter_code,4) AS SIGNED),
  CAST(RIGHT(quarter_code,1) AS SIGNED),
  MAKEDATE(CAST(LEFT(quarter_code,4) AS SIGNED),1)
    + INTERVAL (CAST(RIGHT(quarter_code,1) AS SIGNED)-1) QUARTER,
  LAST_DAY(MAKEDATE(CAST(LEFT(quarter_code,4) AS SIGNED),1)
    + INTERVAL (CAST(RIGHT(quarter_code,1) AS SIGNED)*3 - 1) MONTH)
FROM q_total_inc;

/* ---------------------------------------------------------------------------
   bi_signal_current — the triage table. One row per evaluated pair, at the
   latest quarter. This is what the analyst sorts, filters and ranks.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS bi_signal_current;
CREATE TABLE bi_signal_current (
  drug_key        INT UNSIGNED NOT NULL,
  reaction_key    INT UNSIGNED NOT NULL,
  ingredient      VARCHAR(128) NOT NULL,
  atc_class       VARCHAR(64)  NULL,
  pt              VARCHAR(255) NOT NULL,
  soc             VARCHAR(96)  NOT NULL,

  a               BIGINT NOT NULL COMMENT 'co-reported cases',
  n_drug_cases    BIGINT NOT NULL,
  n_reaction_cases BIGINT NOT NULL,
  expected        DECIMAL(18,4) NOT NULL,

  prr             DECIMAL(18,4) NULL,
  ror             DECIMAL(18,4) NULL,
  ror_lower95     DECIMAL(18,4) NULL,
  ror_upper95     DECIMAL(18,4) NULL,
  chi2_yates      DECIMAL(18,4) NULL,
  ic              DECIMAL(18,4) NULL,
  ic025           DECIMAL(18,4) NULL,

  n_criteria_met  TINYINT    NOT NULL,
  is_signal       TINYINT(1) NOT NULL COMMENT 'strict operating point: all three criteria agree',

  /* Clinical severity context — a signal on a fatal reaction outranks an
     equally strong signal on a mild one, and triage must reflect that. */
  pct_serious     DECIMAL(6,2) NOT NULL,
  pct_death       DECIMAL(6,2) NOT NULL,
  pct_primary_suspect DECIMAL(6,2) NOT NULL,
  pct_rechallenge_pos DECIMAL(6,2) NOT NULL COMMENT 'strongest causality evidence FAERS carries',
  pct_health_prof DECIMAL(6,2) NOT NULL COMMENT 'clinician-reported share; low values suggest media or litigation effects',

  /* Signal HISTORY, kept distinct from signal STATE (is_signal, above).
     A pair can have crossed the threshold in 2019 and sat below it ever since.
     The first version of this table wrote first_signal_quarter on such a pair
     while is_signal read 0, so the BI table showed rows labelled "Ordinary"
     carrying a first-flagged date — a contradiction on its own face. The two
     concepts now have two columns and the naming says which is which. */
  ever_signalled       TINYINT(1) NOT NULL DEFAULT 0
                         COMMENT 'crossed all three criteria in at least one quarter, ever',
  first_signal_quarter CHAR(6) NULL COMMENT 'first quarter it EVER crossed; NULL if never',
  is_known_labelled    TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'already the subject of an FDA action in our reference set',

  PRIMARY KEY (drug_key, reaction_key),
  /* ix_bsc_triage in sql/09_optimization supersedes a (is_signal, ic025) index
     by prefix, so declaring one here would be dead weight on every INSERT. */
  KEY ix_bsc_ing (ingredient)
) ENGINE=InnoDB COMMENT='GRAIN: one row per (drug, reaction) at the latest quarter. Power BI triage table.';

INSERT INTO bi_signal_current
WITH latest AS (SELECT MAX(as_of_quarter) AS q FROM signal_metrics_quarterly),
sev AS (
  SELECT f.drug_key, f.reaction_key,
         COUNT(*)                                       AS n,
         SUM(f.is_serious)                              AS n_serious,
         SUM(f.is_death)                                AS n_death,
         SUM(f.is_primary_suspect)                      AS n_ps,
         SUM(f.rechal = 'Y')                            AS n_rechal,
         SUM(rp.is_health_prof)                         AS n_hp
  FROM fact_drug_reaction f
  JOIN dim_reporter rp ON rp.reporter_key = f.reporter_key
  GROUP BY f.drug_key, f.reaction_key
)
SELECT
  s.drug_key, s.reaction_key, dd.ingredient, dd.atc_class, dr.pt, dr.soc,
  s.a, s.a + s.b, s.a + s.c, s.expected,
  s.prr, s.ror, s.ror_lower95, s.ror_upper95, s.chi2_yates, s.ic, s.ic025,
  s.n_criteria_met, s.is_signal_strict,
  ROUND(100.0*sev.n_serious/NULLIF(sev.n,0),2),
  ROUND(100.0*sev.n_death  /NULLIF(sev.n,0),2),
  ROUND(100.0*sev.n_ps     /NULLIF(sev.n,0),2),
  ROUND(100.0*sev.n_rechal /NULLIF(sev.n,0),2),
  ROUND(100.0*sev.n_hp     /NULLIF(sev.n,0),2),
  CASE WHEN fd.drug_key IS NOT NULL THEN 1 ELSE 0 END,
  fd.first_signal_quarter,
  CASE WHEN r.action_id IS NOT NULL THEN 1 ELSE 0 END
FROM signal_metrics_quarterly s
CROSS JOIN latest l
JOIN dim_drug     dd ON dd.drug_key     = s.drug_key
JOIN dim_reaction dr ON dr.reaction_key = s.reaction_key
LEFT JOIN sev ON sev.drug_key = s.drug_key AND sev.reaction_key = s.reaction_key
LEFT JOIN signal_first_detection fd
       ON fd.drug_key = s.drug_key AND fd.reaction_key = s.reaction_key
/* DISTINCT, not the raw table: its unique key is (ingredient, pt, action_type),
   so one pair legitimately carries both a DSC and a BOXED_WARNING. Joining the
   raw table fans out and the INSERT then dies on PRIMARY KEY (drug_key,
   reaction_key). Adding a single reference action would have broken the build. */
LEFT JOIN (SELECT DISTINCT ingredient, pt, 1 AS action_id
             FROM ref_fda_safety_actions) r
       ON r.ingredient = dd.ingredient AND r.pt = dr.pt
WHERE s.as_of_quarter = l.q;

/* ---------------------------------------------------------------------------
   bi_signal_timeseries — quarterly trajectory, restricted to pairs that ever
   signalled. Keeping the full 79k-row grid would triple the model size to
   carry flat lines nobody plots.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS bi_signal_timeseries;
CREATE TABLE bi_signal_timeseries (
  drug_key      INT UNSIGNED NOT NULL,
  reaction_key  INT UNSIGNED NOT NULL,
  quarter_code  CHAR(6)      NOT NULL,
  a             BIGINT       NOT NULL,
  expected      DECIMAL(18,4) NOT NULL,
  prr           DECIMAL(18,4) NULL,
  ror           DECIMAL(18,4) NULL,
  ic            DECIMAL(18,4) NULL,
  ic025         DECIMAL(18,4) NULL,
  n_criteria_met TINYINT     NOT NULL,
  is_signal     TINYINT(1)   NOT NULL,
  pair_outcome  VARCHAR(20)  NOT NULL
                  COMMENT 'Sustained | Transient — whether the pair is still signalling at the latest quarter',
  PRIMARY KEY (drug_key, reaction_key, quarter_code),
  KEY ix_bst_q (quarter_code)
) ENGINE=InnoDB COMMENT='GRAIN: one row per (drug, reaction, quarter) for pairs that ever signalled.';

INSERT INTO bi_signal_timeseries
SELECT s.drug_key, s.reaction_key, s.as_of_quarter, s.a, s.expected,
       s.prr, s.ror, s.ic, s.ic025, s.n_criteria_met, s.is_signal_strict,
       CASE WHEN fd.is_sustained = 1 THEN 'Sustained' ELSE 'Transient' END
FROM signal_metrics_quarterly s
JOIN signal_first_detection fd
  ON fd.drug_key = s.drug_key AND fd.reaction_key = s.reaction_key;

/* ---------------------------------------------------------------------------
   bi_kpi — scalar headline figures, one row per metric.
   Power BI cards bind to this rather than each recomputing an aggregate.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS bi_kpi;
CREATE TABLE bi_kpi (
  metric      VARCHAR(64)  NOT NULL PRIMARY KEY,
  value_num   DECIMAL(18,4) NULL,
  value_text  VARCHAR(128) NULL,
  display_ord TINYINT      NOT NULL DEFAULT 99
) ENGINE=InnoDB COMMENT='Headline scalars for dashboard cards.';

INSERT INTO bi_kpi (metric, value_num, value_text, display_ord) VALUES
 ('cases_analysed',        (SELECT COUNT(*) FROM case_master), NULL, 1),
 ('source_rows_ingested',  (SELECT SUM(row_count) FROM ingest_ledger), NULL, 2),
 ('duplicate_and_retracted_rows_removed',
   (SELECT value FROM dedup_summary WHERE metric='raw_demo_rows')
 - (SELECT value FROM dedup_summary WHERE metric='surviving_cases'), NULL, 3),
 ('distinct_ingredients',  (SELECT COUNT(*) FROM dim_drug), NULL, 4),
 ('distinct_reactions',    (SELECT COUNT(*) FROM dim_reaction), NULL, 5),
 ('pairs_evaluated',       (SELECT COUNT(*) FROM bi_signal_current), NULL, 6),
 ('signals_detected',      (SELECT COUNT(*) FROM bi_signal_current WHERE is_signal=1), NULL, 7),
 /* Both definitions of "detected" are published, because quoting one without
    the other makes a precision figure impossible for a reader to falsify.
    See the header of sql/07_backtest/02_backtest.sql. */
 ('signals_ever_flagged',  (SELECT COUNT(*) FROM signal_first_detection), NULL, 7),
 ('transient_crossings',   (SELECT COUNT(*) FROM signal_first_detection WHERE is_sustained=0), NULL, 7),
 ('signals_already_labelled',
   (SELECT COUNT(*) FROM bi_signal_current WHERE is_signal=1 AND is_known_labelled=1), NULL, 8),
 ('dq_checks_passed',      (SELECT SUM(status='PASS') FROM dq_results), NULL, 9),
 ('dq_checks_total',       (SELECT COUNT(*) FROM dq_results), NULL, 10),
 ('drug_map_coverage_pct',
   (SELECT ROUND(100.0*SUM(n_rows)/(SELECT SUM(n_rows) FROM drug_name_map),2)
      FROM drug_name_map WHERE match_method <> 'L5_UNMAPPED'), NULL, 11),
 ('observation_window', NULL,
   (SELECT CONCAT(MIN(quarter_code),' to ',MAX(quarter_code)) FROM dim_quarter), 12);

/* ---------------------------------------------------------------------------
   bi_data_quality / bi_pipeline_runs — the transparency page.
   A dashboard that cannot show the state of its own inputs invites the reader
   to assume the numbers are clean. These make the caveats visible in the
   product rather than buried in a README nobody opens.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS bi_data_quality;
CREATE TABLE bi_data_quality (
  check_id   VARCHAR(12)   NOT NULL PRIMARY KEY,
  check_name VARCHAR(160)  NOT NULL,
  layer      VARCHAR(32)   NOT NULL,
  severity   VARCHAR(8)    NOT NULL,
  measured   DECIMAL(18,4) NOT NULL,
  threshold  DECIMAL(18,4) NOT NULL,
  status     VARCHAR(8)    NOT NULL,
  detail     VARCHAR(400)  NULL
) ENGINE=InnoDB;

INSERT INTO bi_data_quality
SELECT check_id, check_name, layer, severity, measured, threshold,
       COALESCE(status,'?'), detail
FROM dq_results;

DROP TABLE IF EXISTS bi_pipeline_runs;
CREATE TABLE bi_pipeline_runs (
  run_id       BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  stage        VARCHAR(64) NOT NULL,
  object_name  VARCHAR(128) NULL,
  quarter_code CHAR(6) NULL,
  rows_out     BIGINT NULL,
  duration_ms  BIGINT NULL,
  status       VARCHAR(8) NOT NULL,
  started_at   DATETIME NOT NULL
) ENGINE=InnoDB;

INSERT INTO bi_pipeline_runs
SELECT run_id, stage, object_name, quarter_code, rows_out, duration_ms, status, started_at
FROM etl_run_log;

/* ---------------------------------------------------------------------------
   bi_backtest — detection performance, exposed for the evidence page.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS bi_backtest;
CREATE TABLE bi_backtest (
  ingredient        VARCHAR(128) NOT NULL,
  pt                VARCHAR(255) NOT NULL,
  reference_quarter CHAR(6)      NOT NULL,
  detected_quarter  CHAR(6)      NULL,
  lag_quarters      INT          NULL,
  was_detected      TINYINT(1)   NOT NULL,
  a_at_detection    BIGINT       NULL,
  mode              VARCHAR(16)  NOT NULL,
  PRIMARY KEY (ingredient, pt, mode)
) ENGINE=InnoDB;

INSERT INTO bi_backtest
SELECT ingredient, pt, emergence_quarter, detected_quarter, lag_quarters,
       was_detected, a_at_detection, 'SYNTHETIC'
FROM backtest_vs_truth;

ANALYZE TABLE bi_signal_current, bi_signal_timeseries, dim_quarter;

SELECT
 (SELECT COUNT(*) FROM bi_signal_current)    AS bi_signal_current,
 (SELECT COUNT(*) FROM bi_signal_timeseries) AS bi_signal_timeseries,
 (SELECT COUNT(*) FROM dim_quarter)          AS dim_quarter,
 (SELECT COUNT(*) FROM bi_kpi)               AS bi_kpi,
 (SELECT COUNT(*) FROM bi_backtest)          AS bi_backtest;
