/* =============================================================================
   02_bi_detection_curve.sql — expose the detection curve to the BI layer
   -----------------------------------------------------------------------------
   Demo-mode only: requires ground_truth_signals, which exists only when the
   synthetic corpus is loaded. On real FDA data there is no ground truth to
   score against, so there is no curve to compute — that asymmetry is the whole
   reason the synthetic corpus exists.

   This table is what turns "our detector is accurate" into a falsifiable,
   quantified statement with a stated operating limit.
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS bi_detection_curve;
CREATE TABLE bi_detection_curve (
  strength_tier   VARCHAR(16)  NOT NULL PRIMARY KEY,
  tier_label      VARCHAR(48)  NOT NULL,
  excess_min_pct  DECIMAL(6,2) NOT NULL,
  excess_max_pct  DECIMAL(6,2) NOT NULL,
  planted         INT          NOT NULL,
  detected        INT          NOT NULL,
  recall_pct      DECIMAL(6,1) NOT NULL,
  sort_order      TINYINT      NOT NULL
) ENGINE=InnoDB COMMENT='Recall by planted signal strength — the method operating limit.';

INSERT INTO bi_detection_curve
SELECT
  g.strength_tier,
  CASE g.strength_tier
    WHEN '1_strong'    THEN 'Strong'
    WHEN '2_moderate'  THEN 'Moderate'
    WHEN '3_weak'      THEN 'Weak'
    ELSE 'Very weak' END,
  ROUND(MIN(g.peak_excess_rate)*100, 2),
  ROUND(MAX(g.peak_excess_rate)*100, 2),
  COUNT(*),
  SUM(sig.drug_key IS NOT NULL),
  ROUND(100.0 * SUM(sig.drug_key IS NOT NULL) / COUNT(*), 1),
  CAST(LEFT(g.strength_tier, 1) AS UNSIGNED)
FROM ground_truth_signals g
LEFT JOIN (
  SELECT s.drug_key, dd.ingredient, dr.pt
  FROM signal_metrics_quarterly s
  JOIN dim_drug     dd ON dd.drug_key     = s.drug_key
  JOIN dim_reaction dr ON dr.reaction_key = s.reaction_key
  WHERE s.as_of_quarter = (SELECT MAX(as_of_quarter) FROM signal_metrics_quarterly)
    AND s.is_signal_strict = 1
) sig ON sig.ingredient = g.ingredient AND sig.pt = g.pt
GROUP BY g.strength_tier;

/* Headline scalars the curve implies, appended to the KPI table. */
INSERT INTO bi_kpi (metric, value_num, value_text, display_ord) VALUES
 ('signals_planted', (SELECT COUNT(*) FROM ground_truth_signals), NULL, 13),
 ('novel_signals_found',
  (SELECT COUNT(*) FROM bi_signal_current WHERE is_signal=1 AND is_known_labelled=0), NULL, 14),
 ('detection_floor_pct',
  (SELECT MIN(excess_min_pct) FROM bi_detection_curve WHERE recall_pct = 100), NULL, 15)
ON DUPLICATE KEY UPDATE value_num = VALUES(value_num);

SELECT * FROM bi_detection_curve ORDER BY sort_order;
