/* =============================================================================
   01_load_dimensions.sql — populate the dimension tables
   -----------------------------------------------------------------------------
   Idempotent: every statement is INSERT ... ON DUPLICATE KEY UPDATE against a
   natural-key unique constraint, so re-running after adding a quarter extends
   the dimensions without renumbering existing surrogate keys. Surrogate key
   stability matters because the Power BI model caches relationships; renumbering
   keys silently reassigns every historical fact row to the wrong dimension member.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   dim_drug — one row per standardised ingredient.
   n_source_names records how many distinct raw strings collapsed into each
   ingredient. It is kept because it is the evidence that standardisation did
   real work: an ingredient showing 6 source names would, without this layer,
   have been six separate under-powered drugs.
   ------------------------------------------------------------------------ */
INSERT INTO dim_drug (ingredient, atc_class, n_source_names, n_source_rows, best_match_rung)
SELECT
    m.ingredient,
    MIN(r.atc_class)                       AS atc_class,
    COUNT(*)                               AS n_source_names,
    SUM(m.n_rows)                          AS n_source_rows,
    MIN(m.match_method)                    AS best_match_rung   -- L1 < L2 < ... lexically
FROM drug_name_map m
/* Pre-aggregate the class lookup. ref_brand_ingredient has one row per BRAND,
   so joining it directly multiplies each drug_name_map row by the number of
   brands sharing that ingredient — inflating COUNT(*) and SUM(n_rows) by the
   brand multiplicity (measured: VALPROATE reported 20 source names / 111,075
   rows against a true 4 / 23,317). Those two columns are quoted as evidence
   that standardisation mattered, so the fan-out landed directly in a published
   figure. Collapsing the lookup to one row per ingredient first removes it. */
LEFT JOIN (SELECT ingredient, MIN(atc_class) AS atc_class
             FROM ref_brand_ingredient GROUP BY ingredient) r
       ON r.ingredient = m.ingredient
GROUP BY m.ingredient
ON DUPLICATE KEY UPDATE
    atc_class       = VALUES(atc_class),
    n_source_names  = VALUES(n_source_names),
    n_source_rows   = VALUES(n_source_rows),
    best_match_rung = VALUES(best_match_rung);

/* ---------------------------------------------------------------------------
   dim_reaction — one row per MedDRA PT actually observed.
   Unmapped PTs get SOC 'Unclassified' rather than being dropped: an
   unclassified reaction is still a valid reaction for signal detection, it just
   cannot be grouped by organ class on the dashboard.
   ------------------------------------------------------------------------ */
INSERT INTO dim_reaction (pt, soc)
SELECT DISTINCT TRIM(UPPER(r.pt)), COALESCE(s.soc, 'Unclassified')
FROM stg_reac r
LEFT JOIN ref_meddra_soc s ON s.pt = TRIM(UPPER(r.pt))
WHERE r.pt IS NOT NULL AND TRIM(r.pt) <> ''
ON DUPLICATE KEY UPDATE soc = VALUES(soc);

/* ---------------------------------------------------------------------------
   dim_patient — banded age/sex/weight junk dimension.

   AGE UNIT CONVERSION HAPPENS HERE AND NOWHERE ELSE.
   FAERS stores a bare number in `age` and its unit in `age_cod`. The value 45
   means 45 years if age_cod='YR' and 450 years if age_cod='DEC'. Converting in
   one place, at load, means the conversion is written once and tested once. The
   alternative — converting in each downstream query — guarantees that some
   query somewhere will forget, and the resulting error is invisible because a
   plausible-looking age comes out either way.
   ------------------------------------------------------------------------ */
INSERT INTO dim_patient (age_band, age_band_ord, sex, weight_band)
WITH conv AS (
  SELECT
    CASE WHEN cm.age_raw REGEXP '^[0-9]+(\\.[0-9]+)?$' THEN
      CAST(cm.age_raw AS DECIMAL(12,4)) *
      CASE cm.age_cod
        WHEN 'DEC' THEN 10.0        -- decades
        WHEN 'YR'  THEN 1.0
        WHEN 'MON' THEN 1.0/12
        WHEN 'WK'  THEN 1.0/52.1775
        WHEN 'DY'  THEN 1.0/365.25
        WHEN 'HR'  THEN 1.0/8766.0
        ELSE NULL                    -- unit absent => age is uninterpretable
      END
    END AS age_years,
    CASE WHEN cm.sex_raw IN ('M','F') THEN cm.sex_raw ELSE 'UNK' END AS sex,
    CASE WHEN cm.wt_raw REGEXP '^[0-9]+(\\.[0-9]+)?$' THEN
      CAST(cm.wt_raw AS DECIMAL(12,4)) * CASE WHEN cm.wt_cod = 'LBS' THEN 0.453592 ELSE 1.0 END
    END AS wt_kg
  FROM case_master cm
),
banded AS (
  SELECT
    CASE
      WHEN age_years IS NULL      THEN 'Unknown'
      WHEN age_years > 120        THEN 'Implausible'   -- surfaced, never silently kept
      WHEN age_years <  1         THEN '<1'
      WHEN age_years < 12         THEN '1-11'
      WHEN age_years < 18         THEN '12-17'
      WHEN age_years < 45         THEN '18-44'
      WHEN age_years < 65         THEN '45-64'
      WHEN age_years < 75         THEN '65-74'
      ELSE '75+'
    END AS age_band,
    CASE
      WHEN age_years IS NULL THEN 9 WHEN age_years > 120 THEN 8
      WHEN age_years < 1 THEN 1 WHEN age_years < 12 THEN 2 WHEN age_years < 18 THEN 3
      WHEN age_years < 45 THEN 4 WHEN age_years < 65 THEN 5 WHEN age_years < 75 THEN 6
      ELSE 7
    END AS age_band_ord,
    sex,
    CASE
      WHEN wt_kg IS NULL  THEN 'Unknown'
      WHEN wt_kg < 40     THEN '<40kg'
      WHEN wt_kg < 60     THEN '40-59kg'
      WHEN wt_kg < 80     THEN '60-79kg'
      WHEN wt_kg < 100    THEN '80-99kg'
      ELSE '100kg+'
    END AS weight_band
  FROM conv
)
SELECT DISTINCT age_band, age_band_ord, sex, weight_band FROM banded
ON DUPLICATE KEY UPDATE age_band_ord = VALUES(age_band_ord);

/* ---------------------------------------------------------------------------
   dim_reporter — qualification, country and report type.
   is_health_prof is precomputed because "was this signal reported by clinicians
   or by consumers?" is the first question asked of any surprising signal.
   ------------------------------------------------------------------------ */
INSERT INTO dim_reporter (occp_cod, occp_desc, is_health_prof, country, is_domestic_us, rept_cod)
SELECT DISTINCT
  COALESCE(NULLIF(cm.occp_cod, ''), 'UNK'),
  CASE COALESCE(NULLIF(cm.occp_cod, ''), 'UNK')
    WHEN 'MD' THEN 'Physician'          WHEN 'PH' THEN 'Pharmacist'
    WHEN 'OT' THEN 'Other health prof'  WHEN 'CN' THEN 'Consumer'
    WHEN 'HP' THEN 'Health professional' WHEN 'LW' THEN 'Lawyer'
    WHEN 'RN' THEN 'Registered nurse'   ELSE 'Unknown'
  END,
  CASE WHEN COALESCE(cm.occp_cod,'') IN ('MD','PH','OT','HP','RN') THEN 1 ELSE 0 END,
  COALESCE(NULLIF(cm.occr_country, ''), 'UNK'),
  CASE WHEN cm.occr_country = 'US' THEN 1 ELSE 0 END,
  COALESCE(NULLIF(cm.rept_cod, ''), 'UNK')
FROM case_master cm
ON DUPLICATE KEY UPDATE occp_desc = VALUES(occp_desc);

SELECT
  (SELECT COUNT(*) FROM dim_drug)     AS dim_drug,
  (SELECT COUNT(*) FROM dim_reaction) AS dim_reaction,
  (SELECT COUNT(*) FROM dim_patient)  AS dim_patient,
  (SELECT COUNT(*) FROM dim_reporter) AS dim_reporter,
  (SELECT COUNT(*) FROM dim_date)     AS dim_date;
