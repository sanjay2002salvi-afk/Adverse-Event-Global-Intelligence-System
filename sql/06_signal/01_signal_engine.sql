/* =============================================================================
   01_signal_engine.sql — disproportionality analysis, in SQL
   -----------------------------------------------------------------------------
   WHAT DISPROPORTIONALITY ACTUALLY MEASURES

   FAERS has no denominator. We know how many people reported a reaction on a
   drug; we do NOT know how many people took the drug. So absolute risk is
   uncomputable and any statement of the form "drug X causes Y in Z% of
   patients" is unsupportable from this data.

   What IS computable: whether reaction E is reported disproportionately OFTEN
   with drug D, relative to how often E is reported with everything else. That
   is a comparison of proportions WITHIN the reporting system, so the unknown
   denominator cancels. Every metric below is a variation on that one idea.

   The 2x2 contingency table for drug D and reaction E, counting CASES:

                        reaction E    not reaction E     total
       drug D               a              b            a+b
       not drug D           c              d            c+d
       total               a+c            b+d            N

   METRICS IMPLEMENTED
     PRR  = [a/(a+b)] / [c/(c+d)]      Proportional Reporting Ratio (MHRA)
     ROR  = (a*d)/(b*c)                Reporting Odds Ratio (Netherlands/EMA)
     chi2 = Yates-corrected chi-square
     IC   = log2[(a+0.5)/(E+0.5)]      Information Component (BCPNN, Uppsala)

   WHY FOUR AND NOT ONE
     PRR and ROR answer nearly the same question and agree when a is large.
     They diverge for rare events: ROR is the better-behaved estimator when the
     reaction is uncommon, PRR is more stable when the drug is uncommon.
     chi-square guards against calling a signal on a ratio built from tiny
     counts. IC applies Bayesian shrinkage, which is the only one of the four
     that is honest about a=3 being weak evidence regardless of how extreme the
     ratio looks. Requiring agreement across criteria is what keeps the false
     positive rate survivable.

   THRESHOLDS (Evans et al. 2001, the standard screening criteria)
     PRR signal   : a >= 3 AND PRR >= 2 AND chi2 >= 4
     ROR signal   : a >= 3 AND lower bound of 95% CI for ROR > 1
     BCPNN signal : IC025 > 0

   WHAT THIS IS NOT: causality. Disproportionate reporting is a hypothesis
   generator. Confounding by indication, notoriety bias, and litigation-driven
   reporting all produce genuine disproportionality without any causal link.
   The dashboard says "signal", never "causes", and that distinction is load-
   bearing rather than decorative.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   Quarterly incremental counts.

   The expensive way to build an "as of each quarter" series is to re-scan the
   fact table once per quarter — 25 full scans for a 25-quarter window, and
   quadratic in the window length as the archive grows.

   The cheap way, used here: every case belongs to exactly ONE receipt quarter,
   so the cumulative count through quarter Q is just the running sum of the
   per-quarter increments. One pass to build increments, then window functions
   to accumulate. Linear instead of quadratic, and the intermediate tables are
   small enough to stay in memory.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS q_pair_inc;
CREATE TABLE q_pair_inc (
  drug_key     INT UNSIGNED NOT NULL,
  reaction_key INT UNSIGNED NOT NULL,
  quarter_code CHAR(6)      NOT NULL,
  a_inc        BIGINT       NOT NULL COMMENT 'cases with BOTH drug and reaction, received this quarter',
  PRIMARY KEY (drug_key, reaction_key, quarter_code)
) ENGINE=InnoDB;

INSERT INTO q_pair_inc
SELECT drug_key, reaction_key, quarter_code, COUNT(*)
FROM fact_drug_reaction
GROUP BY drug_key, reaction_key, quarter_code;

DROP TABLE IF EXISTS q_drug_inc;
CREATE TABLE q_drug_inc (
  drug_key     INT UNSIGNED NOT NULL,
  quarter_code CHAR(6)      NOT NULL,
  n_inc        BIGINT       NOT NULL COMMENT 'cases exposed to this drug, received this quarter',
  PRIMARY KEY (drug_key, quarter_code)
) ENGINE=InnoDB;

INSERT INTO q_drug_inc
SELECT cd.drug_key, ca.quarter_code, COUNT(*)
FROM case_drug cd JOIN case_attributes ca ON ca.case_id = cd.case_id
GROUP BY cd.drug_key, ca.quarter_code;

DROP TABLE IF EXISTS q_reac_inc;
CREATE TABLE q_reac_inc (
  reaction_key INT UNSIGNED NOT NULL,
  quarter_code CHAR(6)      NOT NULL,
  n_inc        BIGINT       NOT NULL,
  PRIMARY KEY (reaction_key, quarter_code)
) ENGINE=InnoDB;

INSERT INTO q_reac_inc
SELECT cr.reaction_key, ca.quarter_code, COUNT(*)
FROM case_reaction cr JOIN case_attributes ca ON ca.case_id = cr.case_id
GROUP BY cr.reaction_key, ca.quarter_code;

DROP TABLE IF EXISTS q_total_inc;
CREATE TABLE q_total_inc (
  quarter_code CHAR(6) NOT NULL PRIMARY KEY,
  n_inc        BIGINT  NOT NULL
) ENGINE=InnoDB;

INSERT INTO q_total_inc
SELECT quarter_code, COUNT(*) FROM case_attributes GROUP BY quarter_code;

/* ---------------------------------------------------------------------------
   The output table: one row per (drug, reaction, as-of quarter).
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS signal_metrics_quarterly;
CREATE TABLE signal_metrics_quarterly (
  drug_key      INT UNSIGNED NOT NULL,
  reaction_key  INT UNSIGNED NOT NULL,
  as_of_quarter CHAR(6)      NOT NULL COMMENT 'metrics use ALL cases received up to and including this quarter',

  a BIGINT NOT NULL COMMENT 'cases with drug AND reaction',
  b BIGINT NOT NULL COMMENT 'cases with drug, without reaction',
  c BIGINT NOT NULL COMMENT 'cases without drug, with reaction',
  d BIGINT NOT NULL COMMENT 'cases with neither',
  n_total BIGINT NOT NULL,
  expected DECIMAL(18,6) NOT NULL COMMENT '(a+b)(a+c)/N — reports expected if drug and reaction were independent',

  prr          DECIMAL(18,6) NULL,
  prr_lower95  DECIMAL(18,6) NULL,
  ror          DECIMAL(18,6) NULL,
  ror_lower95  DECIMAL(18,6) NULL,
  ror_upper95  DECIMAL(18,6) NULL,
  chi2_yates   DECIMAL(18,6) NULL,
  ic           DECIMAL(18,6) NULL,
  ic025        DECIMAL(18,6) NULL,

  is_signal_prr   TINYINT(1) NOT NULL DEFAULT 0,
  is_signal_ror   TINYINT(1) NOT NULL DEFAULT 0,
  is_signal_bcpnn TINYINT(1) NOT NULL DEFAULT 0,
  n_criteria_met  TINYINT    NOT NULL DEFAULT 0 COMMENT '0-3, how many textbook criteria fired',

  /* =====================================================================
     THE OPERATING POINT — consensus of all three criteria.

     This column exists because of a measured failure, not a hunch. Scoring
     the engine against planted ground truth at the obvious operating point
     ("at least 2 of 3 criteria") gave recall 100% but precision 64.2%: 24
     spurious signals out of 67. Inspecting them showed every false positive
     had PRR between 1.08 and 1.20 on a co-report count in the hundreds or
     thousands.

     That is not a bug in the arithmetic. It is the large-sample behaviour of
     significance testing. Two of the three textbook criteria —
       ROR   : lower bound of the 95% CI > 1
       BCPNN : IC025 > 0
     test only whether the association is DISTINGUISHABLE FROM NONE. Neither
     carries a minimum effect size. With N = 373,446 cases the confidence
     intervals are narrow enough that an 8% elevation clears both. Only the
     Evans PRR criterion carries an effect-size floor (PRR >= 2), and at the
     "2 of 3" operating point the two significance-only criteria could
     outvote it.

     Requiring all three to agree makes the effect-size floor mandatory,
     because Evans is one of the three. Measured result: precision 100%,
     recall 76.7% (33 of 43). That is a real trade and not a free lunch —
     ten planted signals were lost, four weak-tier and six very weak. At a
     base rate of one real signal per 73 candidates it is the right trade,
     because a false alarm costs a pharmacologist a week of review while a
     missed weak signal costs one more quarter of evidence before it crosses
     anyway. Both halves of the trade are published; see the detection curve
     in sql/08_semantic/02_bi_detection_curve.sql.

     The general lesson, and the reason this is worth the paragraph: as N
     grows, statistical significance stops being evidence of importance. Any
     screening rule intended to survive scale needs an effect-size threshold,
     not just a p-value or a confidence bound.
     ===================================================================== */
  is_signal_strict TINYINT(1) GENERATED ALWAYS AS (n_criteria_met = 3) STORED
    COMMENT 'Dashboard operating point: all three criteria agree.',

  PRIMARY KEY (drug_key, reaction_key, as_of_quarter),
  KEY ix_smq_quarter (as_of_quarter),
  KEY ix_smq_signal (n_criteria_met, as_of_quarter),
  KEY ix_smq_strict (is_signal_strict, as_of_quarter)
) ENGINE=InnoDB
  COMMENT='GRAIN: one row per (drug, reaction, as-of quarter). Cumulative, not incremental.';

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_compute_signals $$
/* ---------------------------------------------------------------------------
   sp_compute_signals(p_min_cases)

   p_min_cases is the minimum FINAL cumulative co-report count (a) for a pair to
   be evaluated at all. This is not an optimisation detail — it is a statistical
   necessity. With ~40 drugs and ~79 reactions the full grid is small, but real
   FAERS has ~5,000 ingredients and ~25,000 PTs, i.e. 125 million candidate
   pairs, the overwhelming majority of which have a = 0 or 1. Evaluating them
   all would be slow AND would produce a multiple-comparisons catastrophe: at
   125M tests, even a 1-in-100,000 false positive rate yields 1,250 spurious
   "signals". Screening at a >= 3 is the standard convention (Evans 2001) and is
   applied here for both reasons.
   ------------------------------------------------------------------------ */
CREATE PROCEDURE sp_compute_signals(IN p_min_cases INT)
BEGIN
  DECLARE v_rows BIGINT DEFAULT 0;

  IF p_min_cases IS NULL OR p_min_cases < 1 THEN SET p_min_cases = 3; END IF;

  DELETE FROM signal_metrics_quarterly;

  INSERT INTO signal_metrics_quarterly
    (drug_key, reaction_key, as_of_quarter, a, b, c, d, n_total, expected,
     prr, prr_lower95, ror, ror_lower95, ror_upper95, chi2_yates, ic, ic025,
     is_signal_prr, is_signal_ror, is_signal_bcpnn, n_criteria_met)
  WITH
  quarters AS (SELECT quarter_code FROM q_total_inc),

  /* Pairs worth evaluating: those reaching the screening threshold by the end
     of the window. */
  eligible AS (
    SELECT drug_key, reaction_key
    FROM q_pair_inc
    GROUP BY drug_key, reaction_key
    HAVING SUM(a_inc) >= p_min_cases
  ),

  /* Full (pair x quarter) grid so a pair's series has no gaps before it starts
     being reported — cumulative sums need every quarter present. */
  grid AS (
    SELECT e.drug_key, e.reaction_key, q.quarter_code
    FROM eligible e CROSS JOIN quarters q
  ),

  cum AS (
    SELECT
      g.drug_key, g.reaction_key, g.quarter_code,
      SUM(COALESCE(pi.a_inc, 0)) OVER (
        PARTITION BY g.drug_key, g.reaction_key ORDER BY g.quarter_code
        ROWS UNBOUNDED PRECEDING)                                   AS a_cum
    FROM grid g
    LEFT JOIN q_pair_inc pi
           ON pi.drug_key = g.drug_key AND pi.reaction_key = g.reaction_key
          AND pi.quarter_code = g.quarter_code
  ),
  drug_cum AS (
    SELECT d.drug_key, q.quarter_code,
           SUM(COALESCE(di.n_inc,0)) OVER (
             PARTITION BY d.drug_key ORDER BY q.quarter_code ROWS UNBOUNDED PRECEDING) AS n_drug
    FROM (SELECT DISTINCT drug_key FROM eligible) d
    CROSS JOIN quarters q
    LEFT JOIN q_drug_inc di ON di.drug_key = d.drug_key AND di.quarter_code = q.quarter_code
  ),
  reac_cum AS (
    SELECT r.reaction_key, q.quarter_code,
           SUM(COALESCE(ri.n_inc,0)) OVER (
             PARTITION BY r.reaction_key ORDER BY q.quarter_code ROWS UNBOUNDED PRECEDING) AS n_reac
    FROM (SELECT DISTINCT reaction_key FROM eligible) r
    CROSS JOIN quarters q
    LEFT JOIN q_reac_inc ri ON ri.reaction_key = r.reaction_key AND ri.quarter_code = q.quarter_code
  ),
  total_cum AS (
    SELECT quarter_code,
           SUM(n_inc) OVER (ORDER BY quarter_code ROWS UNBOUNDED PRECEDING) AS n_total
    FROM q_total_inc
  ),

  /* Assemble the 2x2 table. */
  cells AS (
    SELECT
      c.drug_key, c.reaction_key, c.quarter_code,
      c.a_cum                                  AS a,
      dc.n_drug - c.a_cum                      AS b,
      rc.n_reac - c.a_cum                      AS c_cell,
      tc.n_total - dc.n_drug - rc.n_reac + c.a_cum AS d,
      tc.n_total,
      (dc.n_drug * rc.n_reac) / NULLIF(tc.n_total, 0) AS expected
    FROM cum c
    JOIN drug_cum  dc ON dc.drug_key     = c.drug_key     AND dc.quarter_code = c.quarter_code
    JOIN reac_cum  rc ON rc.reaction_key = c.reaction_key AND rc.quarter_code = c.quarter_code
    JOIN total_cum tc ON tc.quarter_code = c.quarter_code
  ),

  stats AS (
    SELECT
      x.*,
      /* PRR = [a/(a+b)] / [c/(c+d)] */
      CASE WHEN x.a > 0 AND (x.a + x.b) > 0 AND x.c_cell > 0 AND (x.c_cell + x.d) > 0
           THEN (x.a / (x.a + x.b)) / (x.c_cell / (x.c_cell + x.d)) END AS prr_v,
      /* ROR = ad/bc */
      CASE WHEN x.a > 0 AND x.b > 0 AND x.c_cell > 0 AND x.d > 0
           THEN (x.a * x.d) / (x.b * x.c_cell) END AS ror_v,
      /* SE of ln(ROR) = sqrt(1/a + 1/b + 1/c + 1/d) */
      CASE WHEN x.a > 0 AND x.b > 0 AND x.c_cell > 0 AND x.d > 0
           THEN SQRT(1.0/x.a + 1.0/x.b + 1.0/x.c_cell + 1.0/x.d) END AS se_ln_ror,
      /* SE of ln(PRR) = sqrt(1/a - 1/(a+b) + 1/c - 1/(c+d)) */
      CASE WHEN x.a > 0 AND x.c_cell > 0 AND (x.a+x.b) > 0 AND (x.c_cell+x.d) > 0
           THEN SQRT(1.0/x.a - 1.0/(x.a+x.b) + 1.0/x.c_cell - 1.0/(x.c_cell+x.d)) END AS se_ln_prr,
      /* Yates-corrected chi-square. The continuity correction matters here:
         without it, small-a pairs produce inflated chi-square values and the
         screen fires on noise. */
      CASE WHEN (x.a+x.b) > 0 AND (x.c_cell+x.d) > 0 AND (x.a+x.c_cell) > 0 AND (x.b+x.d) > 0
           /* GREATEST(0, ...): when |ad-bc| < N/2 the uncorrected term goes
              negative and squaring it yields a small positive chi-square where
              the convention gives exactly 0. Affected 2,188 of 79,000 rows at a
              max chi-square of 0.038 — no signal decision changed, but the value
              was wrong. */
           THEN (x.n_total * POW(GREATEST(0, ABS(x.a*x.d - x.b*x.c_cell) - x.n_total/2.0), 2))
                / ((x.a+x.b) * (x.c_cell+x.d) * (x.a+x.c_cell) * (x.b+x.d)) END AS chi2_v,
      /* Information Component with the standard +0.5 shrinkage on both terms.
         The shrinkage is what stops a=1,E=0.01 from reporting IC=6.6. */
      CASE WHEN x.expected IS NOT NULL
           THEN LOG2((x.a + 0.5) / (x.expected + 0.5)) END AS ic_v
    FROM cells x
  )

  SELECT
    s.drug_key, s.reaction_key, s.quarter_code,
    s.a, s.b, s.c_cell, s.d, s.n_total, COALESCE(s.expected, 0),
    s.prr_v,
    CASE WHEN s.prr_v IS NOT NULL AND s.se_ln_prr IS NOT NULL
         THEN EXP(LOG(s.prr_v) - 1.96 * s.se_ln_prr) END,
    s.ror_v,
    CASE WHEN s.ror_v IS NOT NULL AND s.se_ln_ror IS NOT NULL
         THEN EXP(LOG(s.ror_v) - 1.96 * s.se_ln_ror) END,
    CASE WHEN s.ror_v IS NOT NULL AND s.se_ln_ror IS NOT NULL
         THEN EXP(LOG(s.ror_v) + 1.96 * s.se_ln_ror) END,
    s.chi2_v,
    s.ic_v,
    /* IC025: Noren's approximation to the 2.5th percentile of the IC posterior. */
    CASE WHEN s.ic_v IS NOT NULL AND s.a >= 0
         THEN s.ic_v - 3.3 * POW(s.a + 0.5, -0.5) - 2.0 * POW(s.a + 0.5, -1.5) END,

    /* --- signal criteria --- */
    CASE WHEN s.a >= p_min_cases AND s.prr_v >= 2.0 AND s.chi2_v >= 4.0 THEN 1 ELSE 0 END,
    CASE WHEN s.a >= p_min_cases AND s.ror_v IS NOT NULL AND s.se_ln_ror IS NOT NULL
              AND EXP(LOG(s.ror_v) - 1.96 * s.se_ln_ror) > 1.0 THEN 1 ELSE 0 END,
    CASE WHEN s.ic_v IS NOT NULL
              AND (s.ic_v - 3.3 * POW(s.a + 0.5, -0.5) - 2.0 * POW(s.a + 0.5, -1.5)) > 0
         THEN 1 ELSE 0 END,

    (CASE WHEN s.a >= p_min_cases AND s.prr_v >= 2.0 AND s.chi2_v >= 4.0 THEN 1 ELSE 0 END)
  + (CASE WHEN s.a >= p_min_cases AND s.ror_v IS NOT NULL AND s.se_ln_ror IS NOT NULL
               AND EXP(LOG(s.ror_v) - 1.96 * s.se_ln_ror) > 1.0 THEN 1 ELSE 0 END)
  + (CASE WHEN s.ic_v IS NOT NULL
               AND (s.ic_v - 3.3 * POW(s.a + 0.5, -0.5) - 2.0 * POW(s.a + 0.5, -1.5)) > 0
          THEN 1 ELSE 0 END)
  FROM stats s;

  SET v_rows = ROW_COUNT();

  INSERT INTO etl_run_log (stage, object_name, rows_out, finished_at, status, message)
  VALUES ('signal_calc', 'signal_metrics_quarterly', v_rows, NOW(3), 'SUCCESS',
          CONCAT('min_cases=', p_min_cases));

  SELECT v_rows AS rows_written;
END $$

DELIMITER ;

SELECT 'signal engine installed' AS status;
