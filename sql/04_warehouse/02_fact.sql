/* =============================================================================
   02_fact.sql — the fact table
   -----------------------------------------------------------------------------
   GRAIN: one row per (case, standardised ingredient, MedDRA preferred term).

   This grain is the single most consequential decision in the warehouse, so it
   is worth being explicit about what it is NOT:

     NOT one row per drug row in the source. A case listing both 'SINGULAIR' and
     'MONTELUKAST SODIUM' has two source rows but ONE montelukast exposure. Left
     uncollapsed, that case would contribute 2 to the numerator of every
     montelukast 2x2 table — inflating a=count(cases) into a=count(mentions),
     which is a different and wrong statistic.

     NOT one row per case. Disproportionality needs the drug-reaction cross
     product within each case.

   Because the grain is exactly (case, drug, reaction), the contingency cell
     a = COUNT(*) WHERE drug_key = D AND reaction_key = E
   is a plain count with no DISTINCT needed. The PRIMARY KEY enforces this: a
   duplicate at this grain cannot physically be inserted. The grain is protected
   by the schema rather than by everyone downstream remembering to write DISTINCT.

   PARTITIONING: RANGE on year. The quarterly signal series repeatedly asks
   "what did the evidence look like as of quarter Q?", i.e. WHERE year <= Y.
   That is exactly the access pattern partition pruning is built for. MySQL
   requires every partitioning column to appear in every unique key, which is
   why year_num leads the primary key.
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS fact_drug_reaction;
CREATE TABLE fact_drug_reaction (
  year_num        SMALLINT UNSIGNED NOT NULL COMMENT 'partition column; year of FDA receipt',
  case_id         BIGINT UNSIGNED   NOT NULL COMMENT 'degenerate dimension — the case itself',
  drug_key        INT UNSIGNED      NOT NULL,
  reaction_key    INT UNSIGNED      NOT NULL,

  date_key        INT UNSIGNED      NOT NULL COMMENT '-> dim_date (FDA receipt date)',
  quarter_code    CHAR(6)           NOT NULL COMMENT 'denormalised from dim_date: the signal series groups on this several million times, and the join is pure overhead',
  patient_key     INT UNSIGNED      NOT NULL,
  reporter_key    INT UNSIGNED      NOT NULL,

  /* Strongest role this ingredient held in this case.
     PS (primary suspect) > SS (secondary) > I (interacting) > C (concomitant).
     Kept because a signal built from primary-suspect reports is materially
     stronger evidence than one built from drugs the patient merely happened to
     also be taking. Concomitant-only signals are usually confounding. */
  role_cod           CHAR(2)    NOT NULL,
  is_primary_suspect TINYINT(1) NOT NULL,

  /* Case-level seriousness, denormalised onto the fact for filter speed. */
  is_serious          TINYINT(1) NOT NULL,
  is_death            TINYINT(1) NOT NULL,
  is_hospitalisation  TINYINT(1) NOT NULL,

  /* Dechallenge / rechallenge — the only causality evidence FAERS carries.
     Rechallenge positive (the reaction recurred on re-exposure) is the single
     strongest signal of true causation available in spontaneous report data. */
  dechal CHAR(1) NOT NULL DEFAULT 'U',
  rechal CHAR(1) NOT NULL DEFAULT 'U',

  PRIMARY KEY (year_num, case_id, drug_key, reaction_key),
  KEY ix_f_drug_reaction (drug_key, reaction_key),
  KEY ix_f_reaction      (reaction_key),
  KEY ix_f_quarter       (quarter_code, drug_key, reaction_key),
  KEY ix_f_case          (case_id)
) ENGINE=InnoDB
  COMMENT='GRAIN: one row per (case, ingredient, MedDRA PT). PK enforces the grain.'
PARTITION BY RANGE (year_num) (
  PARTITION p_pre2015 VALUES LESS THAN (2015),
  PARTITION p2015 VALUES LESS THAN (2016), PARTITION p2016 VALUES LESS THAN (2017),
  PARTITION p2017 VALUES LESS THAN (2018), PARTITION p2018 VALUES LESS THAN (2019),
  PARTITION p2019 VALUES LESS THAN (2020), PARTITION p2020 VALUES LESS THAN (2021),
  PARTITION p2021 VALUES LESS THAN (2022), PARTITION p2022 VALUES LESS THAN (2023),
  PARTITION p2023 VALUES LESS THAN (2024), PARTITION p2024 VALUES LESS THAN (2025),
  PARTITION p2025 VALUES LESS THAN (2026), PARTITION p2026 VALUES LESS THAN (2027),
  PARTITION p_max  VALUES LESS THAN MAXVALUE
);

/* ---------------------------------------------------------------------------
   Case-level bridge tables.

   These sit between case_master and the fact table and are the tables that
   actually enforce "one exposure per case" and "one reaction per case". They
   are materialised rather than inlined as CTEs because the fact build joins
   them, the signal engine's denominator counts read them directly, and the
   quality tests assert against them. Computing them three times from scratch
   would be both slower and a chance for the three definitions to drift apart.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS case_drug;
CREATE TABLE case_drug (
  case_id            BIGINT UNSIGNED NOT NULL,
  drug_key           INT UNSIGNED    NOT NULL,
  role_cod           CHAR(2)         NOT NULL COMMENT 'strongest role across all source rows for this ingredient',
  is_primary_suspect TINYINT(1)      NOT NULL,
  dechal             CHAR(1)         NOT NULL DEFAULT 'U',
  rechal             CHAR(1)         NOT NULL DEFAULT 'U',
  PRIMARY KEY (case_id, drug_key),
  KEY ix_cd_drug (drug_key)
) ENGINE=InnoDB COMMENT='GRAIN: one row per (case, ingredient). Collapses brand/generic duplicates.';

DROP TABLE IF EXISTS case_reaction;
CREATE TABLE case_reaction (
  case_id      BIGINT UNSIGNED NOT NULL,
  reaction_key INT UNSIGNED    NOT NULL,
  PRIMARY KEY (case_id, reaction_key),
  KEY ix_cr_reaction (reaction_key)
) ENGINE=InnoDB COMMENT='GRAIN: one row per (case, MedDRA PT).';

DROP TABLE IF EXISTS case_attributes;
CREATE TABLE case_attributes (
  case_id            BIGINT UNSIGNED NOT NULL,
  year_num           SMALLINT UNSIGNED NOT NULL,
  date_key           INT UNSIGNED    NOT NULL,
  quarter_code       CHAR(6)         NOT NULL,
  patient_key        INT UNSIGNED    NOT NULL,
  reporter_key       INT UNSIGNED    NOT NULL,
  is_serious         TINYINT(1)      NOT NULL,
  is_death           TINYINT(1)      NOT NULL,
  is_hospitalisation TINYINT(1)      NOT NULL,
  PRIMARY KEY (case_id),
  KEY ix_ca_quarter (quarter_code)
) ENGINE=InnoDB COMMENT='GRAIN: one row per case. Resolved dimension keys and seriousness flags.';

SELECT 'fact and bridge tables created' AS status;
