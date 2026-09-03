/* =============================================================================
   02_load_facts.sql — populate bridges and the fact table
   -----------------------------------------------------------------------------
   Order: case_attributes -> case_drug -> case_reaction -> fact_drug_reaction.
   The fact is the cross product of case_drug and case_reaction within a case,
   decorated with case_attributes.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   case_attributes — one row per case, with resolved dimension keys.

   Date resolution has a deliberate fallback. If fda_dt is malformed (it happens
   — field shift, or a reporter-supplied garbage date), we fall back to the
   first day of the quarter the record was published in, rather than dropping
   the case. Dropping would bias the denominator; the quarter is known with
   certainty because it is the name of the file the row came from, and quarter
   precision is all the signal series actually needs.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE case_attributes;

INSERT INTO case_attributes
  (case_id, year_num, date_key, quarter_code, patient_key, reporter_key,
   is_serious, is_death, is_hospitalisation)
WITH conv AS (
  SELECT
    cm.caseid, cm.primaryid, cm.src_quarter, cm.first_quarter,
    /* FIRST receipt, not the amended version's receipt.
        A case first received 2019Q1 and amended 2023Q3 keeps only the amended
        row after dedup. Keying the cumulative series on that row would place
        the case entirely in 2023Q3 and remove it from 18 quarters it genuinely
        belonged to — biasing every "what did the evidence look like as of
        quarter Q" figure, and every detection lag, later than reality. The demo
        corpus writes both versions in the same quarter so the fixture cannot
        catch this; real FAERS would. */
    CASE WHEN cm.init_fda_dt_raw REGEXP '^[0-9]{8}$'
         THEN STR_TO_DATE(cm.init_fda_dt_raw, '%Y%m%d')
         WHEN cm.fda_dt_raw REGEXP '^[0-9]{8}$'
         THEN STR_TO_DATE(cm.fda_dt_raw, '%Y%m%d') END AS fda_date,
    CASE WHEN cm.age_raw REGEXP '^[0-9]+(\\.[0-9]+)?$' THEN
      CAST(cm.age_raw AS DECIMAL(12,4)) *
      CASE cm.age_cod WHEN 'DEC' THEN 10.0 WHEN 'YR' THEN 1.0
                      WHEN 'MON' THEN 1.0/12 WHEN 'WK' THEN 1.0/52.1775
                      WHEN 'DY' THEN 1.0/365.25 WHEN 'HR' THEN 1.0/8766.0
                      ELSE NULL END
    END AS age_years,
    CASE WHEN cm.sex_raw IN ('M','F') THEN cm.sex_raw ELSE 'UNK' END AS sex,
    CASE WHEN cm.wt_raw REGEXP '^[0-9]+(\\.[0-9]+)?$' THEN
      CAST(cm.wt_raw AS DECIMAL(12,4)) * CASE WHEN cm.wt_cod='LBS' THEN 0.453592 ELSE 1.0 END
    END AS wt_kg,
    COALESCE(NULLIF(cm.occp_cod,''),'UNK')     AS occp_cod,
    COALESCE(NULLIF(cm.occr_country,''),'UNK') AS country,
    COALESCE(NULLIF(cm.rept_cod,''),'UNK')     AS rept_cod
  FROM case_master cm
),
resolved AS (
  SELECT
    c.caseid, c.primaryid,
    /* fallback: first day of the publishing quarter */
    COALESCE(c.fda_date,
             /* fall back to the quarter the case FIRST appeared in, not the
                quarter its latest amendment was published in */
             MAKEDATE(CAST(LEFT(c.first_quarter,4) AS UNSIGNED),1)
               + INTERVAL (CAST(RIGHT(c.first_quarter,1) AS UNSIGNED)-1) QUARTER) AS eff_date,
    CASE WHEN c.age_years IS NULL THEN 'Unknown' WHEN c.age_years > 120 THEN 'Implausible'
         WHEN c.age_years < 1 THEN '<1' WHEN c.age_years < 12 THEN '1-11'
         WHEN c.age_years < 18 THEN '12-17' WHEN c.age_years < 45 THEN '18-44'
         WHEN c.age_years < 65 THEN '45-64' WHEN c.age_years < 75 THEN '65-74'
         ELSE '75+' END AS age_band,
    c.sex,
    CASE WHEN c.wt_kg IS NULL THEN 'Unknown' WHEN c.wt_kg < 40 THEN '<40kg'
         WHEN c.wt_kg < 60 THEN '40-59kg' WHEN c.wt_kg < 80 THEN '60-79kg'
         WHEN c.wt_kg < 100 THEN '80-99kg' ELSE '100kg+' END AS weight_band,
    c.occp_cod, c.country, c.rept_cod
  FROM conv c
),
outc AS (
  SELECT CAST(o.primaryid AS UNSIGNED) AS primaryid,
         MAX(o.outc_cod = 'DE')                                     AS is_death,
         MAX(o.outc_cod = 'HO')                                     AS is_hosp,
         MAX(o.outc_cod IN ('DE','LT','HO','DS','CA','RI'))         AS is_serious
  FROM stg_outc o
  WHERE o.primaryid REGEXP '^[0-9]+$'
  GROUP BY 1
)
SELECT
  r.caseid,
  YEAR(r.eff_date),
  CAST(DATE_FORMAT(r.eff_date, '%Y%m%d') AS UNSIGNED),
  CONCAT(YEAR(r.eff_date), 'Q', QUARTER(r.eff_date)),
  p.patient_key,
  rp.reporter_key,
  COALESCE(o.is_serious, 0), COALESCE(o.is_death, 0), COALESCE(o.is_hosp, 0)
FROM resolved r
JOIN dim_patient  p  ON p.age_band = r.age_band AND p.sex = r.sex
                    AND p.weight_band = r.weight_band
JOIN dim_reporter rp ON rp.occp_cod = r.occp_cod AND rp.country = r.country
                    AND rp.rept_cod = r.rept_cod
LEFT JOIN outc o ON o.primaryid = r.primaryid;

/* ---------------------------------------------------------------------------
   case_drug — one row per (case, ingredient).

   THE COLLAPSE. A case that lists SINGULAIR on drug_seq 1 and MONTELUKAST
   SODIUM on drug_seq 4 has two source rows and one montelukast exposure.
   GROUP BY (case, ingredient) is what turns "count of drug mentions" into
   "count of exposed cases", which is the quantity every disproportionality
   statistic is actually defined on.

   Role and challenge codes are resolved to the STRONGEST value across the
   collapsed rows, via an ordinal ranking rather than MIN() on the raw letters
   (alphabetically 'C' < 'I' < 'PS' < 'SS', which would rank concomitant above
   primary suspect — exactly backwards).
   ------------------------------------------------------------------------ */
TRUNCATE TABLE case_drug;

INSERT INTO case_drug (case_id, drug_key, role_cod, is_primary_suspect, dechal, rechal)
WITH src AS (
  SELECT
    cm.caseid                       AS case_id,
    dd.drug_key,
    CASE d.role_cod WHEN 'PS' THEN 1 WHEN 'SS' THEN 2 WHEN 'I' THEN 3
                    WHEN 'C' THEN 4 ELSE 5 END AS role_ord,
    CASE d.dechal WHEN 'Y' THEN 1 WHEN 'N' THEN 2 WHEN 'D' THEN 3 ELSE 4 END AS dechal_ord,
    CASE d.rechal WHEN 'Y' THEN 1 WHEN 'N' THEN 2 WHEN 'D' THEN 3 ELSE 4 END AS rechal_ord
  FROM stg_drug d
  JOIN case_master   cm ON cm.primaryid = CAST(d.primaryid AS UNSIGNED)
  JOIN drug_name_map m  ON m.raw_name   = d.drugname
  JOIN dim_drug      dd ON dd.ingredient = m.ingredient
  WHERE d.primaryid REGEXP '^[0-9]+$'
)
SELECT
  case_id, drug_key,
  CASE MIN(role_ord) WHEN 1 THEN 'PS' WHEN 2 THEN 'SS' WHEN 3 THEN 'I'
                     WHEN 4 THEN 'C' ELSE 'U' END,
  CASE WHEN MIN(role_ord) = 1 THEN 1 ELSE 0 END,
  CASE MIN(dechal_ord) WHEN 1 THEN 'Y' WHEN 2 THEN 'N' WHEN 3 THEN 'D' ELSE 'U' END,
  CASE MIN(rechal_ord) WHEN 1 THEN 'Y' WHEN 2 THEN 'N' WHEN 3 THEN 'D' ELSE 'U' END
FROM src
GROUP BY case_id, drug_key;

/* ---------------------------------------------------------------------------
   case_reaction — one row per (case, PT). Same collapse on the reaction side:
   a case reporting 'NAUSEA' twice is one nauseated patient.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE case_reaction;

INSERT INTO case_reaction (case_id, reaction_key)
SELECT DISTINCT cm.caseid, dr.reaction_key
FROM stg_reac r
JOIN case_master  cm ON cm.primaryid   = CAST(r.primaryid AS UNSIGNED)
JOIN dim_reaction dr ON dr.pt          = TRIM(UPPER(r.pt))
WHERE r.primaryid REGEXP '^[0-9]+$'
  AND r.pt IS NOT NULL AND TRIM(r.pt) <> '';

/* ---------------------------------------------------------------------------
   fact_drug_reaction — the cross product within each case.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE fact_drug_reaction;

INSERT INTO fact_drug_reaction
  (year_num, case_id, drug_key, reaction_key, date_key, quarter_code,
   patient_key, reporter_key, role_cod, is_primary_suspect,
   is_serious, is_death, is_hospitalisation, dechal, rechal)
SELECT
  ca.year_num, cd.case_id, cd.drug_key, cr.reaction_key,
  ca.date_key, ca.quarter_code, ca.patient_key, ca.reporter_key,
  cd.role_cod, cd.is_primary_suspect,
  ca.is_serious, ca.is_death, ca.is_hospitalisation,
  cd.dechal, cd.rechal
FROM case_drug       cd
JOIN case_reaction   cr ON cr.case_id = cd.case_id
JOIN case_attributes ca ON ca.case_id = cd.case_id;

/* ---------------------------------------------------------------------------
   ix_f_cover — built HERE, not in sql/09_optimization, and the placement is the
   whole point. Its justification is the severity roll-up in
   sql/08_semantic/01_bi_layer.sql, which runs three stages from now. An index
   created after its consumer has already run costs a full build and returns
   nothing. Every column that roll-up touches is listed, so InnoDB can answer
   the aggregate from the index alone instead of descending the primary key once
   per fact row. See sql/09_optimization/01_indexes_and_evidence.sql for the
   measurement and 02_benchmark.sql to reproduce it.
   ------------------------------------------------------------------------ */
CREATE INDEX ix_f_cover ON fact_drug_reaction
  (drug_key, reaction_key, is_serious, is_death, is_primary_suspect,
   rechal, reporter_key);

/* Keep dim_reaction.n_cases current for dashboard sorting. */
UPDATE dim_reaction dr
JOIN (SELECT reaction_key, COUNT(*) n FROM case_reaction GROUP BY 1) x
  ON x.reaction_key = dr.reaction_key
SET dr.n_cases = x.n;

ANALYZE TABLE fact_drug_reaction, case_drug, case_reaction, case_attributes;

SELECT
  (SELECT COUNT(*) FROM case_attributes)    AS cases,
  (SELECT COUNT(*) FROM case_drug)          AS case_drug_rows,
  (SELECT COUNT(*) FROM case_reaction)      AS case_reaction_rows,
  (SELECT COUNT(*) FROM fact_drug_reaction) AS fact_rows,
  (SELECT ROUND(COUNT(*)/ (SELECT COUNT(*) FROM case_attributes),2)
     FROM fact_drug_reaction)               AS avg_fact_rows_per_case;
