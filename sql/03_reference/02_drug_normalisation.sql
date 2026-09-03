/* =============================================================================
   02_drug_normalisation.sql — free text -> active ingredient
   -----------------------------------------------------------------------------
   THE PROBLEM
   FAERS drugname is whatever the reporter typed. The same exposure arrives as
   'SINGULAIR', 'Singulair 10mg', 'MONTELUKAST SODIUM', 'montelukast',
   'SINGULAIR (MONTELUKAST)' and 'MONTELUKAST SOD.'. Disproportionality analysis
   counts cases per drug; if those six strings stay distinct, one real signal is
   split into six under-powered fragments and every one of them falls below the
   detection threshold. The signal does not become weaker — it disappears, with
   no error raised anywhere. This is the most dangerous failure mode in the
   project precisely because it is silent.

   THE PERFORMANCE INSIGHT
   Do NOT normalise 1.2M drug rows. Normalise the DISTINCT vocabulary (a few
   thousand strings) into a lookup table, then join. Regex over the raw fact
   rows costs ~200x more for an identical result. Measured on the demo corpus:
   distinct names 123, drug rows 1.26M.

   RESOLUTION LADDER (highest confidence first)
     L1  prod_ai        FDA's own coded active ingredient  — but ONLY on rows
                        not flagged as field-shifted, because on a shifted row
                        prod_ai holds a fragment of the neighbouring column.
     L2  brand exact    normalised string matches ref_brand_ingredient
     L3  ingredient     normalised string is already a known ingredient
     L4  parenthetical  'LEVAQUIN (LEVOFLOXACIN)' -> try the bracketed text
     L5  unmapped       keep the normalised string, flag it, never guess

   Every mapping records WHICH rung resolved it, so mapping quality is a
   measurable, reportable property rather than an article of faith.
   ========================================================================== */

USE aegis;
SET SESSION group_concat_max_len = 1048576;
SET SESSION cte_max_recursion_depth = 10000;

/* ---------------------------------------------------------------------------
   Step 0 — the distinct vocabulary, with a field-shift flag per raw string.
   A raw name is considered shift-suspect if ANY row bearing it shows the
   structural corruption signature identified by quality gate DQ-006b.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS drug_name_vocab;
CREATE TABLE drug_name_vocab (
  raw_name        VARCHAR(512) NOT NULL,
  n_rows          BIGINT       NOT NULL,
  n_shift_suspect BIGINT       NOT NULL,
  prod_ai_mode    VARCHAR(512) NULL COMMENT 'most common clean prod_ai seen with this raw name',
  /* Keyed on a hash of the FULL string, not PRIMARY KEY (raw_name(255)).
     A 255-byte prefix key silently declares two drugnames identical when they
     share a 255-character prefix — routine in FAERS, where reporters paste an
     entire label into the field. On the demo corpus no two names collide, so a
     prefix key passes here and fails on the real data with a duplicate-entry
     error partway through a 40-minute load. The hash is generated and stored,
     so the collision is impossible rather than unlikely. */
  raw_name_hash   BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(raw_name, 256))) STORED,
  PRIMARY KEY (raw_name_hash),
  KEY ix_dnv_raw_name (raw_name(255))
) ENGINE=InnoDB COMMENT='Distinct drugname strings. Normalise this, not the fact table.';

INSERT INTO drug_name_vocab (raw_name, n_rows, n_shift_suspect, prod_ai_mode)
SELECT
    d.drugname,
    COUNT(*),
    SUM(CASE WHEN d.route IN ('1','2')
              OR (d.val_vbm <> '' AND d.val_vbm NOT IN ('1','2')) THEN 1 ELSE 0 END),
    /* Genuinely the MODE, resolved in a correlated subquery.
        The previous form used SUBSTRING_INDEX(GROUP_CONCAT(... ORDER BY prod_ai))
        which returns MIN(prod_ai), not the most common value — so a single stray
        prod_ai sorting alphabetically first could redirect an entire ingredient
        through the highest-priority mapping rung. It also silently truncated at
        group_concat_max_len on high-volume names. */
    (SELECT d2.prod_ai
       FROM stg_drug d2
      WHERE d2.drugname = d.drugname
        AND d2.prod_ai <> ''
        AND d2.route NOT IN ('1','2')
        AND (d2.val_vbm = '' OR d2.val_vbm IN ('1','2'))
      GROUP BY d2.prod_ai
      ORDER BY COUNT(*) DESC, d2.prod_ai
      LIMIT 1)
FROM stg_drug d
WHERE d.drugname IS NOT NULL AND TRIM(d.drugname) <> ''
GROUP BY d.drugname;

/* ---------------------------------------------------------------------------
   Step 1 — normalise. One regex pass per transformation, over the vocabulary.

   Order is deliberate:
     strengths before punctuation  ('10MG' must die while the digits survive)
     punctuation before tokens     (so 'SOD.' becomes the strippable token 'SOD')
     tokens last                   (word-boundary anchored so 'CAP' inside
                                    'CAPTOPRIL' is never touched)
   ------------------------------------------------------------------------ */
SET @strip_re = (
  SELECT CONCAT('\\b(', GROUP_CONCAT(token ORDER BY CHAR_LENGTH(token) DESC, token SEPARATOR '|'), ')\\b')
  FROM ref_token_strip
);

/* ---------------------------------------------------------------------------
   Step 1a — normalise the LOOKUP SIDE with the identical transformation.

   Both sides of a join must pass through the same normaliser. Matching a
   normalised probe against a raw lookup key is a silent-miss generator: the
   first version of this file compared the cleaned string 'Z PAK' against the
   stored brand key 'Z-PAK' and left 7,871 rows unmapped, because punctuation
   had been stripped from one side only.

   Defining the transformation once, here, and applying it to both sides makes
   that class of bug structurally impossible rather than merely absent.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS ref_brand_normalised;
CREATE TABLE ref_brand_normalised (
  norm_brand VARCHAR(128) NOT NULL,
  ingredient VARCHAR(128) NOT NULL,
  PRIMARY KEY (norm_brand),
  KEY ix_rbn_ing (ingredient)
) ENGINE=InnoDB COMMENT='ref_brand_ingredient keys pushed through the same normaliser as the probe.';

INSERT IGNORE INTO ref_brand_normalised (norm_brand, ingredient)
SELECT TRIM(REGEXP_REPLACE(
         REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(UPPER(brand_name),
               '[0-9]+(\\.[0-9]+)?\\s*(MG|MCG|G|ML|L|IU|U|UNITS?|%)\\b', ' '),
             '[^A-Z0-9/+ ]', ' '),
           @strip_re, ' '),
         '\\s+', ' ')),
       ingredient
FROM ref_brand_ingredient;

DROP TABLE IF EXISTS ref_ingredient_normalised;
CREATE TABLE ref_ingredient_normalised (
  norm_ingredient VARCHAR(128) NOT NULL,
  ingredient      VARCHAR(128) NOT NULL,
  PRIMARY KEY (norm_ingredient)
) ENGINE=InnoDB COMMENT='Canonical ingredient names, normalised identically.';

INSERT IGNORE INTO ref_ingredient_normalised (norm_ingredient, ingredient)
SELECT TRIM(REGEXP_REPLACE(
         REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(UPPER(ingredient),
               '[0-9]+(\\.[0-9]+)?\\s*(MG|MCG|G|ML|L|IU|U|UNITS?|%)\\b', ' '),
             '[^A-Z0-9/+ ]', ' '),
           @strip_re, ' '),
         '\\s+', ' ')),
       ingredient
FROM (SELECT DISTINCT ingredient FROM ref_brand_ingredient) x;

DROP TABLE IF EXISTS drug_name_map;
CREATE TABLE drug_name_map (
  raw_name      VARCHAR(512) NOT NULL,
  norm_name     VARCHAR(512) NOT NULL COMMENT 'main candidate, brackets removed',
  paren_name    VARCHAR(512) NULL     COMMENT 'candidate taken from inside brackets',
  ingredient    VARCHAR(128) NOT NULL COMMENT 'resolved active ingredient, or the normalised string if unresolved',
  match_method  ENUM('L1_PROD_AI','L2_BRAND','L3_INGREDIENT','L4_PAREN','L5_UNMAPPED') NOT NULL,
  is_combination TINYINT(1)  NOT NULL DEFAULT 0,
  n_rows        BIGINT       NOT NULL,
  /* Same reasoning as drug_name_vocab above: hash the full string. */
  raw_name_hash BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(raw_name, 256))) STORED,
  PRIMARY KEY (raw_name_hash),
  KEY ix_dnm_raw_name (raw_name(255)),
  KEY ix_dnm_ingredient (ingredient),
  KEY ix_dnm_method (match_method)
) ENGINE=InnoDB COMMENT='Raw drug string -> ingredient, with the rung that resolved it.';

INSERT INTO drug_name_map
  (raw_name, norm_name, paren_name, ingredient, match_method, is_combination, n_rows)
WITH base AS (
  SELECT
      v.raw_name, v.n_rows, v.n_shift_suspect, v.prod_ai_mode,
      /* text OUTSIDE brackets */
      TRIM(REGEXP_REPLACE(UPPER(v.raw_name), '\\(.*?\\)', ' '))          AS outside_raw,
      /* text INSIDE the first bracket pair, if any */
      NULLIF(TRIM(REGEXP_SUBSTR(UPPER(v.raw_name), '(?<=\\().*?(?=\\))')), '') AS inside_raw
  FROM drug_name_vocab v
),
cleaned AS (
  SELECT
      raw_name, n_rows, n_shift_suspect, prod_ai_mode, inside_raw,
      TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(outside_raw,
              '[0-9]+(\\.[0-9]+)?\\s*(MG|MCG|G|ML|L|IU|U|UNITS?|%)\\b', ' '),  -- strengths
            '[^A-Z0-9/+ ]', ' '),                                              -- punctuation
          @strip_re, ' '),                                                     -- noise tokens
        '\\s+', ' ')) AS norm_name,
      TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(COALESCE(inside_raw, ''),
              '[0-9]+(\\.[0-9]+)?\\s*(MG|MCG|G|ML|L|IU|U|UNITS?|%)\\b', ' '),
            '[^A-Z0-9/+ ]', ' '),
          @strip_re, ' '),
        '\\s+', ' ')) AS paren_name,
      TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(UPPER(COALESCE(prod_ai_mode, '')),
              '[0-9]+(\\.[0-9]+)?\\s*(MG|MCG|G|ML|L|IU|U|UNITS?|%)\\b', ' '),
            '[^A-Z0-9/+ ]', ' '),
          @strip_re, ' '),
        '\\s+', ' ')) AS norm_prod_ai
  FROM base
),
resolved AS (
  SELECT
      c.raw_name, c.norm_name, NULLIF(c.paren_name, '') AS paren_name, c.n_rows,
      CASE
        /* L1 — FDA's own coded active ingredient.
           NOTE: there is deliberately no n_shift_suspect test here. prod_ai_mode
           was already computed in Step 0 exclusively from rows that show no
           shift signature, so the value reaching this point is clean by
           construction. An earlier version additionally required
           n_shift_suspect = 0 for the whole raw name, which — because the 3%
           corruption is randomly distributed — was true for zero of 123 names.
           A single corrupted row anywhere disabled the highest-confidence rung
           for the entire drug. Filter at the source, not at the aggregate. */
        WHEN pa.ingredient IS NOT NULL THEN pa.ingredient      -- L1 prod_ai
        WHEN b1.ingredient IS NOT NULL THEN b1.ingredient      -- L2 brand
        WHEN k1.ingredient IS NOT NULL THEN k1.ingredient      -- L3 already an ingredient
        WHEN b2.ingredient IS NOT NULL THEN b2.ingredient      -- L4 bracketed brand
        WHEN k2.ingredient IS NOT NULL THEN k2.ingredient      -- L4 bracketed ingredient
        ELSE NULLIF(c.norm_name, '')
      END AS ingredient,
      CASE
        WHEN pa.ingredient IS NOT NULL THEN 'L1_PROD_AI'
        WHEN b1.ingredient IS NOT NULL THEN 'L2_BRAND'
        WHEN k1.ingredient IS NOT NULL THEN 'L3_INGREDIENT'
        WHEN b2.ingredient IS NOT NULL OR k2.ingredient IS NOT NULL THEN 'L4_PAREN'
        ELSE 'L5_UNMAPPED'
      END AS match_method
  FROM cleaned c
  LEFT JOIN ref_ingredient_normalised pa ON pa.norm_ingredient = c.norm_prod_ai
  LEFT JOIN ref_brand_normalised      b1 ON b1.norm_brand      = c.norm_name
  LEFT JOIN ref_ingredient_normalised k1 ON k1.norm_ingredient = c.norm_name
  LEFT JOIN ref_brand_normalised      b2 ON b2.norm_brand      = c.paren_name
  LEFT JOIN ref_ingredient_normalised k2 ON k2.norm_ingredient = c.paren_name
)
SELECT
    raw_name, norm_name, paren_name,
    COALESCE(ingredient, 'UNKNOWN') AS ingredient,
    match_method,
    /* combination products carry a separator between two active moieties */
    CASE WHEN COALESCE(ingredient,'') REGEXP '[/+]' THEN 1 ELSE 0 END,
    n_rows
FROM resolved;

/* ---------------------------------------------------------------------------
   Step 2 — mapping coverage report. Coverage is weighted by ROW COUNT, not by
   distinct strings: mapping 90% of strings is worthless if the unmapped 10%
   are the high-volume ones. Row-weighted coverage is the honest metric.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS drug_map_coverage;
CREATE TABLE drug_map_coverage (
  match_method   VARCHAR(20)  NOT NULL PRIMARY KEY,
  distinct_names BIGINT       NOT NULL,
  drug_rows      BIGINT       NOT NULL,
  pct_of_rows    DECIMAL(7,3) NOT NULL
) ENGINE=InnoDB;

INSERT INTO drug_map_coverage
SELECT match_method, COUNT(*), SUM(n_rows),
       ROUND(100.0 * SUM(n_rows) / (SELECT SUM(n_rows) FROM drug_name_map), 3)
FROM drug_name_map GROUP BY match_method;

SELECT * FROM drug_map_coverage
ORDER BY FIELD(match_method,'L1_PROD_AI','L2_BRAND','L3_INGREDIENT','L4_PAREN','L5_UNMAPPED');

SELECT
  (SELECT COUNT(*) FROM drug_name_vocab)                                   AS distinct_raw_names,
  (SELECT COUNT(DISTINCT ingredient) FROM drug_name_map)                   AS distinct_ingredients,
  (SELECT ROUND(100.0 * SUM(n_rows) / (SELECT SUM(n_rows) FROM drug_name_map), 2)
     FROM drug_name_map WHERE match_method <> 'L5_UNMAPPED')               AS pct_rows_mapped;
