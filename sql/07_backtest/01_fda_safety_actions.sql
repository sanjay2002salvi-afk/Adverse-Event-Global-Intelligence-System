/* =============================================================================
   01_fda_safety_actions.sql — reference set of real FDA safety actions
   -----------------------------------------------------------------------------
   The benchmark the signal engine is scored against when running on REAL FAERS
   data: known drug-reaction pairs where the FDA eventually took a documented
   regulatory action, with the date of that action.

   The evaluation question: at what point did the accumulated spontaneous-report
   evidence first cross a standard signal-detection threshold, and how does that
   compare with the date the regulator acted?

   HONESTY REQUIREMENTS, because this is where a project like this can slide
   into overclaiming:

     1. The FDA does not act on FAERS alone. Boxed warnings follow randomised
        trials, observational studies, published case series and advisory
        committee review. A positive lead time does NOT mean "we beat the FDA".
        It means the spontaneous-report stream contained a detectable
        statistical signal before the regulatory action concluded — which is
        expected, since regulatory action is deliberately slow and evidentiary.

     2. Detecting a signal is not the same as being right. This reference set is
        inherently a set of confirmed true positives; scoring only against it
        measures sensitivity and says nothing about false-positive rate. The
        false-positive side is measured separately, against planted ground truth
        in the synthetic corpus (tests/02_detection_curve.sql).

     3. Dates below are the earliest clearly-dated public FDA action found for
        that pair, compiled from FDA Drug Safety Communications and label
        changes. Pairs whose warning predates the modern FAERS era (2004+) carry
        a NULL action_date and are EXCLUDED from lead-time statistics: we cannot
        measure lead time against an action that happened before our data starts.
        They are retained because they remain valid positive controls for
        sensitivity.

   Contributors: verify any date against the primary FDA source before citing it
   in a report. The source_url column is there so that is a one-click check.
   ========================================================================== */

USE aegis;

DROP TABLE IF EXISTS ref_fda_safety_actions;
CREATE TABLE ref_fda_safety_actions (
  action_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  ingredient   VARCHAR(128) NOT NULL,
  pt           VARCHAR(255) NOT NULL COMMENT 'MedDRA PT matching dim_reaction',
  action_date  DATE         NULL     COMMENT 'NULL = predates FAERS window; excluded from lead-time stats',
  action_type  VARCHAR(48)  NOT NULL COMMENT 'BOXED_WARNING | DSC | LABEL_CHANGE | WITHDRAWAL',
  action_label VARCHAR(255) NOT NULL,
  source_url   VARCHAR(400) NULL,
  PRIMARY KEY (action_id),
  UNIQUE KEY uq_action (ingredient, pt, action_type),
  KEY ix_action_date (action_date)
) ENGINE=InnoDB COMMENT='Documented FDA safety actions used as positive controls.';

INSERT INTO ref_fda_safety_actions
  (ingredient, pt, action_date, action_type, action_label, source_url) VALUES

-- Dated within the modern FAERS era -----------------------------------------
('MONTELUKAST','SUICIDAL IDEATION','2020-03-04','BOXED_WARNING',
 'Boxed warning added for serious neuropsychiatric events',
 'https://www.fda.gov/drugs/fda-requires-boxed-warning-about-serious-mental-health-side-effects-asthma-and-allergy-drug'),
('MONTELUKAST','DEPRESSION','2020-03-04','BOXED_WARNING',
 'Boxed warning added for serious neuropsychiatric events',
 'https://www.fda.gov/drugs/fda-requires-boxed-warning-about-serious-mental-health-side-effects-asthma-and-allergy-drug'),
('MONTELUKAST','NIGHTMARE','2020-03-04','BOXED_WARNING',
 'Boxed warning added for serious neuropsychiatric events',
 'https://www.fda.gov/drugs/fda-requires-boxed-warning-about-serious-mental-health-side-effects-asthma-and-allergy-drug'),

('FEBUXOSTAT','MYOCARDIAL INFARCTION','2019-02-21','BOXED_WARNING',
 'Boxed warning for cardiovascular death following CARES trial',
 'https://www.fda.gov/drugs/drug-safety-and-availability'),

('LEVOFLOXACIN','TENDON RUPTURE','2008-07-08','BOXED_WARNING',
 'Fluoroquinolone class boxed warning for tendinitis and tendon rupture', NULL),
('CIPROFLOXACIN','TENDON RUPTURE','2008-07-08','BOXED_WARNING',
 'Fluoroquinolone class boxed warning for tendinitis and tendon rupture', NULL),
('LEVOFLOXACIN','AORTIC ANEURYSM','2018-12-20','DSC',
 'Warning on increased risk of aortic dissection and rupture', NULL),

('CANAGLIFLOZIN','DIABETIC KETOACIDOSIS','2015-05-15','DSC',
 'SGLT2 inhibitor class warning for ketoacidosis', NULL),
('CANAGLIFLOZIN','AMPUTATION','2017-05-16','BOXED_WARNING',
 'Boxed warning for lower-limb amputation (subsequently removed 2020-08-26)', NULL),

('VARENICLINE','SUICIDAL IDEATION','2009-07-01','BOXED_WARNING',
 'Boxed warning for neuropsychiatric events (removed 2016-12-16 after EAGLES)', NULL),

('ONDANSETRON','ELECTROCARDIOGRAM QT PROLONGED','2011-09-15','DSC',
 'QT interval prolongation warning; 32 mg IV dose withdrawn 2012', NULL),
('ONDANSETRON','TORSADE DE POINTES','2011-09-15','DSC',
 'QT interval prolongation and torsade de pointes warning', NULL),

('TRAMADOL','RESPIRATORY DEPRESSION','2017-04-20','BOXED_WARNING',
 'Contraindicated under 12 years; boxed warning for respiratory depression', NULL),
('TRAMADOL','SEROTONIN SYNDROME','2016-03-22','LABEL_CHANGE',
 'Opioid class labelling updated for serotonin syndrome risk', NULL),

('OMEPRAZOLE','CLOSTRIDIUM DIFFICILE COLITIS','2012-02-08','DSC',
 'PPI class warning for C. difficile-associated diarrhoea', NULL),
('SITAGLIPTIN','PANCREATITIS','2009-09-25','DSC',
 'Revised labelling for acute pancreatitis', NULL),
('HYDROXYCHLOROQUINE','ELECTROCARDIOGRAM QT PROLONGED','2020-07-01','DSC',
 'Cautions on QT prolongation outside hospital settings', NULL),
('VALPROATE','FOETAL MALFORMATION','2011-06-30','DSC',
 'Neural tube defects and impaired cognitive development in offspring', NULL),

-- Predating the FAERS window: valid positive controls, no lead time computable
('CLOZAPINE','AGRANULOCYTOSIS',NULL,'BOXED_WARNING',
 'Boxed warning present since US approval (1989); mandatory ANC monitoring', NULL),
('CLOZAPINE','MYOCARDITIS',NULL,'BOXED_WARNING',
 'Myocarditis added to boxed warning in the early 2000s', NULL),
('AMIODARONE','PULMONARY FIBROSIS',NULL,'BOXED_WARNING',
 'Boxed warning for pulmonary toxicity, long-standing', NULL),
('METHOTREXATE','PANCYTOPENIA',NULL,'BOXED_WARNING',
 'Boxed warning for bone marrow suppression, long-standing', NULL),
('WARFARIN','GASTROINTESTINAL HAEMORRHAGE',NULL,'BOXED_WARNING',
 'Boxed warning for bleeding risk, long-standing', NULL),
('METFORMIN','LACTIC ACIDOSIS',NULL,'BOXED_WARNING',
 'Boxed warning for lactic acidosis, long-standing', NULL),
('ISOTRETINOIN','DEPRESSION',NULL,'LABEL_CHANGE',
 'Psychiatric labelling added 1998; iPLEDGE programme', NULL),
('ALLOPURINOL','STEVENS-JOHNSON SYNDROME',NULL,'LABEL_CHANGE',
 'Severe cutaneous adverse reactions, long-standing labelling', NULL),
('ATORVASTATIN','RHABDOMYOLYSIS',NULL,'LABEL_CHANGE',
 'Statin class myopathy/rhabdomyolysis labelling, long-standing', NULL);

/* -----------------------------------------------------------------------------
   Ensure ground_truth_signals exists even on the real-data path.

   tests/ground_truth.sql creates and fills this table, but it is a demo-only
   stage. sql/07_backtest/02_backtest.sql reads it unconditionally, so a real
   FAERS run (no --demo) aborted here with "Table 'aegis.ground_truth_signals'
   doesn't exist" and never reached the BI layer. Creating it empty makes Mode A
   return zero rows — which is the correct answer when there is no planted truth
   to score against — instead of killing the run.
   -------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS ground_truth_signals (
  ingredient        VARCHAR(128) NOT NULL,
  pt                VARCHAR(255) NOT NULL,
  emergence_quarter CHAR(6)      NOT NULL,
  peak_excess_rate  DECIMAL(6,4) NOT NULL,
  strength_tier     VARCHAR(16)  NOT NULL,
  PRIMARY KEY (ingredient, pt)
) ENGINE=InnoDB COMMENT='Planted associations. Empty on the real-data path, by design.';

SELECT COUNT(*) AS total_actions,
       SUM(action_date IS NOT NULL) AS dated_within_faers_era,
       SUM(action_date IS NULL)     AS predates_window
FROM ref_fda_safety_actions;
