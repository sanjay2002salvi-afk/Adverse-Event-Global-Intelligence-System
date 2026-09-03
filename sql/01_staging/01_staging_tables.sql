/* =============================================================================
   01_staging_tables.sql — raw landing zone
   -----------------------------------------------------------------------------
   DESIGN RULE FOR THIS LAYER: mirror the source, coerce nothing.

   Every column is VARCHAR/TEXT even when it is obviously a date or a number.
   That is deliberate. FAERS ASCII extracts are dirty in specific, documented
   ways:

     * event_dt appears as YYYYMMDD, YYYYMM, or YYYY depending on how much the
       reporter knew. A DATE column would reject two of the three.
     * age arrives as a decimal string whose unit lives in a SEPARATE column
       (age_cod: DEC/YR/MON/WK/DY/HR). '3' can mean 3 years or 3 hours.
     * Numeric fields contain empty strings, and occasionally stray '$'
       characters from mis-escaped free text that shift every later field.

   If staging enforced types, those rows would be silently dropped by the loader
   and the pipeline would under-report without ever raising an error. Loading
   everything as text means bad rows arrive intact and are caught and COUNTED by
   the quality gates in sql/02_quality/, where they are visible.

   Source: FDA FAERS quarterly ASCII extracts, '$'-delimited, header row present.
   Layout below matches the 2014Q3+ format (the schema changed at 2014Q3 when
   FAERS replaced the legacy AERS ISR-keyed layout with the caseid/primaryid
   layout used here).
   ========================================================================== */

USE aegis;

/* --- DEMO: one row per case version. The spine of the whole model. --------- */
DROP TABLE IF EXISTS stg_demo;
CREATE TABLE stg_demo (
  primaryid        VARCHAR(32)  NULL COMMENT 'caseid + caseversion concatenated; unique per case version',
  caseid           VARCHAR(32)  NULL COMMENT 'stable case identifier across versions',
  caseversion      VARCHAR(8)   NULL COMMENT 'increments when a case is amended; keep MAX per caseid',
  i_f_code         VARCHAR(4)   NULL COMMENT 'I=initial, F=follow-up',
  event_dt         VARCHAR(16)  NULL COMMENT 'adverse event onset; partial dates common',
  mfr_dt           VARCHAR(16)  NULL COMMENT 'date manufacturer first received',
  init_fda_dt      VARCHAR(16)  NULL COMMENT 'date FDA first received the case',
  fda_dt           VARCHAR(16)  NULL COMMENT 'date FDA received this version',
  rept_cod         VARCHAR(16)  NULL COMMENT 'EXP=expedited, PER=periodic, DIR=direct',
  auth_num         VARCHAR(64)  NULL,
  mfr_num          VARCHAR(128) NULL,
  mfr_sndr         VARCHAR(255) NULL COMMENT 'reporting organisation; free text, very dirty',
  lit_ref          TEXT         NULL,
  age              VARCHAR(32)  NULL COMMENT 'MEANINGLESS without age_cod',
  age_cod          VARCHAR(8)   NULL COMMENT 'DEC|YR|MON|WK|DY|HR',
  age_grp          VARCHAR(8)   NULL COMMENT 'N|I|C|T|A|E, sparsely populated',
  sex              VARCHAR(8)   NULL COMMENT 'M|F|UNK; blank is common',
  e_sub            VARCHAR(8)   NULL,
  wt               VARCHAR(32)  NULL,
  wt_cod           VARCHAR(8)   NULL COMMENT 'KG|LBS',
  rept_dt          VARCHAR(16)  NULL,
  to_mfr           VARCHAR(8)   NULL,
  occp_cod         VARCHAR(16)  NULL COMMENT 'MD|PH|OT|CN|HP|LW|RN — reporter qualification',
  reporter_country VARCHAR(64)  NULL,
  occr_country     VARCHAR(64)  NULL COMMENT 'country where the event occurred',
  src_quarter      CHAR(6)      NOT NULL COMMENT 'injected by loader, not in source file'
) ENGINE=InnoDB COMMENT='Raw FAERS DEMO. No coercion. One row per case VERSION, not per case.';

/* --- DRUG: one row per drug mentioned per case. --------------------------- */
DROP TABLE IF EXISTS stg_drug;
CREATE TABLE stg_drug (
  primaryid     VARCHAR(32)  NULL,
  caseid        VARCHAR(32)  NULL,
  drug_seq      VARCHAR(16)  NULL COMMENT 'sequence within case; joins to THER/INDI',
  role_cod      VARCHAR(8)   NULL COMMENT 'PS=primary suspect, SS=secondary suspect, C=concomitant, I=interacting',
  drugname      VARCHAR(512) NULL COMMENT 'FREE TEXT as typed by the reporter. The core dirty field.',
  prod_ai       VARCHAR(512) NULL COMMENT 'active ingredient, populated only ~50% of the time',
  val_vbm       VARCHAR(8)   NULL COMMENT '1=validated trade name, 2=verbatim',
  route         VARCHAR(128) NULL,
  dose_vbm      VARCHAR(512) NULL,
  cum_dose_chr  VARCHAR(64)  NULL,
  cum_dose_unit VARCHAR(32)  NULL,
  dechal        VARCHAR(8)   NULL COMMENT 'Y/N/U/D — did the reaction abate on withdrawal? Causality evidence.',
  rechal        VARCHAR(8)   NULL COMMENT 'Y/N/U/D — did it recur on re-exposure? Strongest causality evidence.',
  lot_num       VARCHAR(128) NULL,
  exp_dt        VARCHAR(16)  NULL,
  nda_num       VARCHAR(64)  NULL,
  dose_amt      VARCHAR(64)  NULL,
  dose_unit     VARCHAR(32)  NULL,
  dose_form     VARCHAR(128) NULL,
  dose_freq     VARCHAR(64)  NULL,
  src_quarter   CHAR(6)      NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS DRUG. drugname is free text and requires the standardisation layer.';

/* --- REAC: one row per reported reaction term per case. ------------------- */
DROP TABLE IF EXISTS stg_reac;
CREATE TABLE stg_reac (
  primaryid    VARCHAR(32)  NULL,
  caseid       VARCHAR(32)  NULL,
  pt           VARCHAR(255) NULL COMMENT 'MedDRA Preferred Term. Controlled vocabulary — clean, unlike drugname.',
  drug_rec_act VARCHAR(255) NULL,
  src_quarter  CHAR(6)      NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS REAC. pt is MedDRA-coded, so this side of the 2x2 table is trustworthy.';

/* --- OUTC: seriousness outcomes. Multiple rows per case. ------------------ */
DROP TABLE IF EXISTS stg_outc;
CREATE TABLE stg_outc (
  primaryid   VARCHAR(32) NULL,
  caseid      VARCHAR(32) NULL,
  outc_cod    VARCHAR(8)  NULL COMMENT 'DE=death, LT=life-threatening, HO=hospitalisation, DS=disability, CA=congenital anomaly, RI=required intervention, OT=other',
  src_quarter CHAR(6)     NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS OUTC.';

/* --- RPSR: report source. ------------------------------------------------- */
DROP TABLE IF EXISTS stg_rpsr;
CREATE TABLE stg_rpsr (
  primaryid   VARCHAR(32) NULL,
  caseid      VARCHAR(32) NULL,
  rpsr_cod    VARCHAR(16) NULL COMMENT 'FGN|SDY|LIT|CSM|HP|UF|CR|DT|OTH',
  src_quarter CHAR(6)     NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS RPSR.';

/* --- THER: therapy start/stop dates per drug_seq. ------------------------- */
DROP TABLE IF EXISTS stg_ther;
CREATE TABLE stg_ther (
  primaryid    VARCHAR(32) NULL,
  caseid       VARCHAR(32) NULL,
  dsg_drug_seq VARCHAR(16) NULL COMMENT 'joins to stg_drug.drug_seq',
  start_dt     VARCHAR(16) NULL,
  end_dt       VARCHAR(16) NULL,
  dur          VARCHAR(32) NULL,
  dur_cod      VARCHAR(8)  NULL,
  src_quarter  CHAR(6)     NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS THER. Enables time-to-onset analysis.';

/* --- INDI: indication (why the drug was given). --------------------------- */
DROP TABLE IF EXISTS stg_indi;
CREATE TABLE stg_indi (
  primaryid     VARCHAR(32)  NULL,
  caseid        VARCHAR(32)  NULL,
  indi_drug_seq VARCHAR(16)  NULL,
  indi_pt       VARCHAR(255) NULL COMMENT 'MedDRA-coded indication. Critical for confounding-by-indication checks.',
  src_quarter   CHAR(6)      NOT NULL
) ENGINE=InnoDB COMMENT='Raw FAERS INDI. Used to separate drug effect from underlying-disease effect.';

/* --- DELETED: cases FDA has retracted. MUST be honoured. ------------------ */
DROP TABLE IF EXISTS stg_deleted_cases;
CREATE TABLE stg_deleted_cases (
  caseid      VARCHAR(32) NULL,
  src_quarter CHAR(6)     NOT NULL
) ENGINE=InnoDB COMMENT='Cases FDA retracted. Analyses that ignore this file overcount. Most public FAERS analyses ignore it.';

SELECT 'staging tables created' AS status;
