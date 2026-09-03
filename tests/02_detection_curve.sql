/* =============================================================================
   02_detection_curve.sql — where does this method actually stop working?
   -----------------------------------------------------------------------------
   A single accuracy number on a uniformly easy test set is close to worthless.
   It tells you the detector works on the cases you chose to give it, and nothing
   about the boundary — which is the only part a reviewer should care about.

   The corpus plants signals across four strength tiers spanning a 20x range in
   excess reporting rate. Scoring recall separately per tier produces a DETECTION
   CURVE, and the curve names the operating limit: the excess-reporting rate
   below which this pipeline stops seeing things.

   Reporting the limit is not an admission of weakness. A method with no stated
   limit has simply not been characterised.

   Prerequisites: tests/ground_truth.sql, CALL sp_compute_signals(3);
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS eval_detected;
CREATE TABLE eval_detected AS
SELECT dd.ingredient, dr.pt, s.a, s.prr, s.ror, s.ic025, s.n_criteria_met
FROM signal_metrics_quarterly s
JOIN dim_drug     dd ON dd.drug_key     = s.drug_key
JOIN dim_reaction dr ON dr.reaction_key = s.reaction_key
WHERE s.as_of_quarter = (SELECT MAX(as_of_quarter) FROM signal_metrics_quarterly)
  AND s.is_signal_strict = 1;

/* ----------------------------- THE CURVE -------------------------------- */
SELECT '=== DETECTION CURVE: recall by planted signal strength ===' AS report;

SELECT
  g.strength_tier                                   AS strength_band,
  CONCAT(MIN(g.peak_excess_rate)*100, '% - ',
         MAX(g.peak_excess_rate)*100, '%')          AS excess_reporting_range,
  COUNT(*)                                          AS planted,
  SUM(d.ingredient IS NOT NULL)                     AS detected,
  ROUND(100.0*SUM(d.ingredient IS NOT NULL)/COUNT(*), 1) AS recall_pct
FROM ground_truth_signals g
LEFT JOIN eval_detected d ON d.ingredient = g.ingredient AND d.pt = g.pt
GROUP BY g.strength_tier
ORDER BY g.strength_tier;

/* ------------------------- OVERALL CONFUSION ---------------------------- */
SELECT '=== OVERALL (all tiers pooled) ===' AS report;

WITH m AS (
  SELECT
    (SELECT COUNT(*) FROM ground_truth_signals g
       JOIN eval_detected d ON d.ingredient=g.ingredient AND d.pt=g.pt)      AS tp,
    (SELECT COUNT(*) FROM eval_detected d
       LEFT JOIN ground_truth_signals g ON g.ingredient=d.ingredient AND g.pt=d.pt
      WHERE g.ingredient IS NULL)                                            AS fp,
    (SELECT COUNT(*) FROM ground_truth_signals g
       LEFT JOIN eval_detected d ON d.ingredient=g.ingredient AND d.pt=g.pt
      WHERE d.ingredient IS NULL)                                            AS fn
)
SELECT tp AS true_positives, fp AS false_positives, fn AS false_negatives,
       ROUND(100.0*tp/NULLIF(tp+fp,0), 1) AS precision_pct,
       ROUND(100.0*tp/NULLIF(tp+fn,0), 1) AS recall_pct
FROM m;

/* --------------- WHAT THE PROJECT IS ACTUALLY FOR ----------------------- */
SELECT '=== HELD OUT OF THE REFERENCE SET, AND RECOVERED ===' AS report;

SELECT d.ingredient, d.pt, d.a AS co_reports,
       ROUND(d.prr,2) AS prr, ROUND(d.ic025,2) AS ic025,
       g.strength_tier
FROM eval_detected d
JOIN ground_truth_signals g ON g.ingredient=d.ingredient AND g.pt=d.pt
LEFT JOIN (SELECT DISTINCT ingredient, pt FROM ref_fda_safety_actions) r
       ON r.ingredient=d.ingredient AND r.pt=d.pt
WHERE r.ingredient IS NULL
ORDER BY d.ic025 DESC;

/* ------------------------- MISSED, WITH CONTEXT ------------------------- */
SELECT '=== MISSED (and how close they got) ===' AS report;

SELECT g.ingredient, g.pt, g.strength_tier, g.peak_excess_rate,
       COALESCE(s.a,0) AS co_reports, ROUND(s.prr,2) AS prr,
       ROUND(s.ic025,2) AS ic025,
       COALESCE(s.n_criteria_met,0) AS criteria_met_of_3
FROM ground_truth_signals g
LEFT JOIN eval_detected d ON d.ingredient=g.ingredient AND d.pt=g.pt
LEFT JOIN (SELECT dd.ingredient, dr.pt, s.a, s.prr, s.ic025, s.n_criteria_met
             FROM signal_metrics_quarterly s
             JOIN dim_drug dd ON dd.drug_key=s.drug_key
             JOIN dim_reaction dr ON dr.reaction_key=s.reaction_key
            WHERE s.as_of_quarter=(SELECT MAX(as_of_quarter) FROM signal_metrics_quarterly)) s
       ON s.ingredient=g.ingredient AND s.pt=g.pt
WHERE d.ingredient IS NULL
ORDER BY g.peak_excess_rate DESC;

/* ------------------------------ ASSERTIONS ------------------------------ */
SELECT '=== ASSERTIONS ===' AS report;

WITH t AS (
  SELECT g.strength_tier AS tier, COUNT(*) n,
         SUM(d.ingredient IS NOT NULL) hit
  FROM ground_truth_signals g
  LEFT JOIN eval_detected d ON d.ingredient=g.ingredient AND d.pt=g.pt
  GROUP BY g.strength_tier
),
p AS (
  SELECT
    (SELECT COUNT(*) FROM ground_truth_signals g
       JOIN eval_detected d ON d.ingredient=g.ingredient AND d.pt=g.pt) tp,
    (SELECT COUNT(*) FROM eval_detected d
       LEFT JOIN ground_truth_signals g ON g.ingredient=d.ingredient AND g.pt=d.pt
      WHERE g.ingredient IS NULL) fp
)
SELECT 'TEST-001' AS id,
       'recall on STRONG signals >= 95%' AS assertion,
       ROUND(100.0*(SELECT hit FROM t WHERE tier='1_strong')
                  /(SELECT n   FROM t WHERE tier='1_strong'),1) AS measured,
       IF(100.0*(SELECT hit FROM t WHERE tier='1_strong')
               /(SELECT n FROM t WHERE tier='1_strong') >= 95,'PASS','FAIL') AS status
UNION ALL
SELECT 'TEST-002', 'precision across ALL tiers >= 90%',
       ROUND(100.0*tp/NULLIF(tp+fp,0),1),
       IF(100.0*tp/NULLIF(tp+fp,0) >= 90,'PASS','FAIL') FROM p
UNION ALL
/* The curve must be monotonic. If a weaker tier ever outscores a stronger one,
   the planting or the scoring is wrong — this catches that silently. */
SELECT 'TEST-003', 'detection curve is monotonic: violations = 0',
       /* Report the number of VIOLATIONS, not the number of tiers. The old
          version emitted the tier count (4) in a column the two tests above
          use for a percentage, so the row read "TEST-003 ... 4 ... PASS" and
          told the reader nothing about what had been measured. A measured
          value that cannot be interpreted is worse than no column. */
       (SELECT COUNT(*) FROM t a JOIN t b
          ON b.tier > a.tier AND (b.hit/b.n) > (a.hit/a.n)),
       CASE
         WHEN (SELECT COUNT(*) FROM t) < 4 THEN 'SKIP'   -- not all tiers planted
         WHEN (SELECT hit/n FROM t WHERE tier='1_strong')   >= (SELECT hit/n FROM t WHERE tier='2_moderate')
          AND (SELECT hit/n FROM t WHERE tier='2_moderate') >= (SELECT hit/n FROM t WHERE tier='3_weak')
          AND (SELECT hit/n FROM t WHERE tier='3_weak')     >= (SELECT hit/n FROM t WHERE tier='4_very_weak')
           THEN 'PASS' ELSE 'FAIL'
       END;

/* TEST-004 — false positives under BOTH definitions of "detected".
   The precision figure this project publishes is only meaningful next to the
   definition that produced it, so both are asserted here rather than one being
   quoted and the other left for the reader to discover in the CSVs.
     SUSTAINED    = still above all three thresholds at the latest quarter.
                    This is the alert list a safety team would triage, and it is
                    the operating point the headline precision figure uses.
     EVER-FLAGGED = crossed all three in any quarter, including a pair that
                    crossed on thin counts and decayed back down as evidence
                    accumulated. More permissive, and the right denominator for
                    "how early could this have been caught". */
SELECT '=== TEST-004: false positives under both detection definitions ===' AS report;
SELECT 'TEST-004a' AS id,
       'false positives among SUSTAINED signals = 0' AS assertion,
       SUM(d.is_sustained = 1 AND g.ingredient IS NULL) AS measured,
       IF(SUM(d.is_sustained = 1 AND g.ingredient IS NULL) = 0, 'PASS', 'FAIL') AS status
FROM signal_first_detection d
LEFT JOIN ground_truth_signals g
       ON g.ingredient = d.ingredient AND g.pt = d.pt
UNION ALL
SELECT 'TEST-004b',
       'transient crossings (ever-flagged, not sustained) — reported, not suppressed',
       SUM(d.is_sustained = 0),
       'INFO'
FROM signal_first_detection d;

DROP TABLE IF EXISTS eval_detected;
