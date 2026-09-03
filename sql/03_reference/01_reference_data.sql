/* =============================================================================
   01_reference_data.sql — curated reference vocabularies
   -----------------------------------------------------------------------------
   Reference data lives in SQL rather than CSV deliberately: no file paths, no
   LOAD DATA privileges, no encoding surprises. It runs identically on Windows,
   macOS and Linux, which matters because contributors are on different machines.

   THREE VOCABULARIES:
     ref_token_strip      — noise tokens removed during drug-name normalisation
     ref_brand_ingredient — brand/trade name -> active ingredient
     ref_meddra_soc       — MedDRA Preferred Term -> System Organ Class grouping

   Contributors: to improve mapping coverage, add rows here. Re-run this file
   and sql/03_reference/02_drug_normalisation.sql; nothing else changes.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   1. Tokens stripped during normalisation.
      Ordering matters at apply time (longest first) so that 'HYDROCHLORIDE'
      is removed before 'HCL' can partially match inside another word.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS ref_token_strip;
CREATE TABLE ref_token_strip (
  token     VARCHAR(48) NOT NULL PRIMARY KEY,
  category  ENUM('SALT','DOSE_FORM','MODIFIER') NOT NULL,
  note      VARCHAR(160) NULL
) ENGINE=InnoDB COMMENT='Noise tokens removed from free-text drug names.';

INSERT INTO ref_token_strip (token, category, note) VALUES
-- Salt and hydrate forms. Pharmacologically the same active moiety, so they
-- MUST collapse: 'METOPROLOL TARTRATE' and 'METOPROLOL SUCCINATE' are the same
-- ingredient for signal-detection purposes even though they are different products.
('HYDROCHLORIDE','SALT',NULL), ('HCL','SALT',NULL), ('HYDROBROMIDE','SALT',NULL),
('SODIUM','SALT',NULL), ('POTASSIUM','SALT',NULL), ('CALCIUM','SALT',NULL),
('MAGNESIUM','SALT',NULL), ('SULFATE','SALT',NULL), ('SULPHATE','SALT',NULL),
('TARTRATE','SALT',NULL), ('BITARTRATE','SALT',NULL), ('BESYLATE','SALT',NULL),
('MALEATE','SALT',NULL), ('MESYLATE','SALT',NULL), ('ACETATE','SALT',NULL),
('CITRATE','SALT',NULL), ('PHOSPHATE','SALT',NULL), ('FUMARATE','SALT',NULL),
('SUCCINATE','SALT',NULL), ('NITRATE','SALT',NULL), ('OXALATE','SALT',NULL),
('TOSYLATE','SALT',NULL), ('PAMOATE','SALT',NULL), ('VALERATE','SALT',NULL),
('PROPIONATE','SALT',NULL), ('DIPROPIONATE','SALT',NULL), ('XINAFOATE','SALT',NULL),
('BROMIDE','SALT',NULL), ('CHLORIDE','SALT',NULL), ('BISULFATE','SALT',NULL),
('HEMIHYDRATE','SALT',NULL), ('MONOHYDRATE','SALT',NULL), ('DIHYDRATE','SALT',NULL),
('ANHYDROUS','SALT',NULL), ('SOD','SALT','abbreviation seen in reporter text'),
-- Dose forms and release modifiers.
('TABLET','DOSE_FORM',NULL), ('TABLETS','DOSE_FORM',NULL), ('TAB','DOSE_FORM',NULL),
('TABS','DOSE_FORM',NULL), ('CAPSULE','DOSE_FORM',NULL), ('CAPSULES','DOSE_FORM',NULL),
('CAP','DOSE_FORM',NULL), ('CAPS','DOSE_FORM',NULL), ('SOLUTION','DOSE_FORM',NULL),
('INJECTION','DOSE_FORM',NULL), ('INJ','DOSE_FORM',NULL), ('CREAM','DOSE_FORM',NULL),
('OINTMENT','DOSE_FORM',NULL), ('SUSPENSION','DOSE_FORM',NULL), ('SYRUP','DOSE_FORM',NULL),
('INHALER','DOSE_FORM',NULL), ('PATCH','DOSE_FORM',NULL), ('GEL','DOSE_FORM',NULL),
('DROPS','DOSE_FORM',NULL), ('SPRAY','DOSE_FORM',NULL), ('POWDER','DOSE_FORM',NULL),
('XR','DOSE_FORM','extended release'), ('ER','DOSE_FORM','extended release'),
('SR','DOSE_FORM','sustained release'), ('CR','DOSE_FORM','controlled release'),
('XL','DOSE_FORM',NULL), ('ODT','DOSE_FORM','orally disintegrating tablet'),
('LA','DOSE_FORM','long acting'), ('DS','DOSE_FORM','double strength'),
('EC','DOSE_FORM','enteric coated'),
-- Generic modifiers contributing no identity.
('ORAL','MODIFIER',NULL), ('TOPICAL','MODIFIER',NULL), ('UNKNOWN','MODIFIER',NULL),
('NOS','MODIFIER','not otherwise specified'), ('PRN','MODIFIER',NULL),
('GENERIC','MODIFIER',NULL), ('BRAND','MODIFIER',NULL), ('USP','MODIFIER',NULL),
('EXTENDED','MODIFIER',NULL), ('RELEASE','MODIFIER',NULL), ('DELAYED','MODIFIER',NULL);

/* ---------------------------------------------------------------------------
   2. Brand -> ingredient.
      Reporters type whatever is on the box. 'SINGULAIR', 'Singulair 10mg' and
      'MONTELUKAST SODIUM' are one exposure and must aggregate to one row of the
      2x2 table. Failing to collapse them splits a true signal across several
      under-powered pairs and it silently disappears — the most damaging failure
      mode in this entire project, because it produces no error, just absence.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS ref_brand_ingredient;
CREATE TABLE ref_brand_ingredient (
  brand_name  VARCHAR(128) NOT NULL PRIMARY KEY,
  ingredient  VARCHAR(128) NOT NULL,
  atc_class   VARCHAR(64)  NULL COMMENT 'coarse therapeutic class for dashboard grouping',
  KEY ix_rbi_ingredient (ingredient)
) ENGINE=InnoDB COMMENT='Trade name to active ingredient. Extend freely; this is the coverage lever.';

INSERT INTO ref_brand_ingredient (brand_name, ingredient, atc_class) VALUES
-- Respiratory
('SINGULAIR','MONTELUKAST','Respiratory'),
('VENTOLIN','ALBUTEROL','Respiratory'), ('PROVENTIL','ALBUTEROL','Respiratory'),
('SALBUTAMOL','ALBUTEROL','Respiratory'), ('ADVAIR','FLUTICASONE','Respiratory'),
('SYMBICORT','BUDESONIDE','Respiratory'), ('SPIRIVA','TIOTROPIUM','Respiratory'),
('FLOVENT','FLUTICASONE','Respiratory'), ('DULERA','MOMETASONE','Respiratory'),
-- Anti-infective
('LEVAQUIN','LEVOFLOXACIN','Anti-infective'),
('CIPRO','CIPROFLOXACIN','Anti-infective'), ('CIPRO XR','CIPROFLOXACIN','Anti-infective'),
('AVELOX','MOXIFLOXACIN','Anti-infective'), ('ZITHROMAX','AZITHROMYCIN','Anti-infective'),
('Z-PAK','AZITHROMYCIN','Anti-infective'), ('ZPAK','AZITHROMYCIN','Anti-infective'),
('AUGMENTIN','AMOXICILLIN','Anti-infective'), ('AMOXIL','AMOXICILLIN','Anti-infective'),
('KEFLEX','CEPHALEXIN','Anti-infective'), ('FLAGYL','METRONIDAZOLE','Anti-infective'),
('BACTRIM','SULFAMETHOXAZOLE','Anti-infective'), ('SEPTRA','SULFAMETHOXAZOLE','Anti-infective'),
('DIFLUCAN','FLUCONAZOLE','Anti-infective'), ('VALTREX','VALACICLOVIR','Anti-infective'),
('PLAQUENIL','HYDROXYCHLOROQUINE','Anti-infective'),
-- Diabetes
('INVOKANA','CANAGLIFLOZIN','Diabetes'), ('JARDIANCE','EMPAGLIFLOZIN','Diabetes'),
('FARXIGA','DAPAGLIFLOZIN','Diabetes'), ('JANUVIA','SITAGLIPTIN','Diabetes'),
('ONGLYZA','SAXAGLIPTIN','Diabetes'), ('TRADJENTA','LINAGLIPTIN','Diabetes'),
('GLUCOPHAGE','METFORMIN','Diabetes'), ('GLUCOPHAGE XR','METFORMIN','Diabetes'),
('LANTUS','INSULIN GLARGINE','Diabetes'), ('BASAGLAR','INSULIN GLARGINE','Diabetes'),
('TOUJEO','INSULIN GLARGINE','Diabetes'), ('HUMALOG','INSULIN LISPRO','Diabetes'),
('NOVOLOG','INSULIN ASPART','Diabetes'), ('OZEMPIC','SEMAGLUTIDE','Diabetes'),
('TRULICITY','DULAGLUTIDE','Diabetes'), ('VICTOZA','LIRAGLUTIDE','Diabetes'),
('AMARYL','GLIMEPIRIDE','Diabetes'), ('ACTOS','PIOGLITAZONE','Diabetes'),
('AVANDIA','ROSIGLITAZONE','Diabetes'),
-- Cardiovascular
('LIPITOR','ATORVASTATIN','Cardiovascular'), ('CRESTOR','ROSUVASTATIN','Cardiovascular'),
('ZOCOR','SIMVASTATIN','Cardiovascular'), ('PRAVACHOL','PRAVASTATIN','Cardiovascular'),
('ZETIA','EZETIMIBE','Cardiovascular'), ('NORVASC','AMLODIPINE','Cardiovascular'),
('ZESTRIL','LISINOPRIL','Cardiovascular'), ('PRINIVIL','LISINOPRIL','Cardiovascular'),
('COZAAR','LOSARTAN','Cardiovascular'), ('DIOVAN','VALSARTAN','Cardiovascular'),
('BENICAR','OLMESARTAN','Cardiovascular'), ('TOPROL','METOPROLOL','Cardiovascular'),
('LOPRESSOR','METOPROLOL','Cardiovascular'), ('TENORMIN','ATENOLOL','Cardiovascular'),
('COREG','CARVEDILOL','Cardiovascular'), ('LASIX','FUROSEMIDE','Cardiovascular'),
('COUMADIN','WARFARIN','Cardiovascular'), ('JANTOVEN','WARFARIN','Cardiovascular'),
('ELIQUIS','APIXABAN','Cardiovascular'), ('XARELTO','RIVAROXABAN','Cardiovascular'),
('PRADAXA','DABIGATRAN','Cardiovascular'), ('PLAVIX','CLOPIDOGREL','Cardiovascular'),
('BRILINTA','TICAGRELOR','Cardiovascular'), ('CORDARONE','AMIODARONE','Cardiovascular'),
('PACERONE','AMIODARONE','Cardiovascular'), ('LANOXIN','DIGOXIN','Cardiovascular'),
('ENTRESTO','SACUBITRIL','Cardiovascular'),
-- Gastrointestinal
('PRILOSEC','OMEPRAZOLE','Gastrointestinal'), ('NEXIUM','ESOMEPRAZOLE','Gastrointestinal'),
('PROTONIX','PANTOPRAZOLE','Gastrointestinal'), ('PREVACID','LANSOPRAZOLE','Gastrointestinal'),
('ACIPHEX','RABEPRAZOLE','Gastrointestinal'), ('ZANTAC','RANITIDINE','Gastrointestinal'),
('PEPCID','FAMOTIDINE','Gastrointestinal'), ('ZOFRAN','ONDANSETRON','Gastrointestinal'),
('ZOFRAN ODT','ONDANSETRON','Gastrointestinal'), ('REGLAN','METOCLOPRAMIDE','Gastrointestinal'),
-- CNS / psychiatry
('ZOLOFT','SERTRALINE','CNS'), ('PROZAC','FLUOXETINE','CNS'), ('PAXIL','PAROXETINE','CNS'),
('LEXAPRO','ESCITALOPRAM','CNS'), ('CELEXA','CITALOPRAM','CNS'),
('CYMBALTA','DULOXETINE','CNS'), ('EFFEXOR','VENLAFAXINE','CNS'),
('WELLBUTRIN','BUPROPION','CNS'), ('REMERON','MIRTAZAPINE','CNS'),
('ABILIFY','ARIPIPRAZOLE','CNS'), ('SEROQUEL','QUETIAPINE','CNS'),
('ZYPREXA','OLANZAPINE','CNS'), ('RISPERDAL','RISPERIDONE','CNS'),
('CLOZARIL','CLOZAPINE','CNS'), ('FAZACLO','CLOZAPINE','CNS'),
('LAMICTAL','LAMOTRIGINE','CNS'), ('DEPAKOTE','VALPROATE','CNS'),
('DEPAKENE','VALPROATE','CNS'), ('VALPROIC ACID','VALPROATE','CNS'),
('DIVALPROEX','VALPROATE','CNS'), ('DIVALPROEX SODIUM','VALPROATE','CNS'),
('KEPPRA','LEVETIRACETAM','CNS'), ('DILANTIN','PHENYTOIN','CNS'),
('TEGRETOL','CARBAMAZEPINE','CNS'), ('NEURONTIN','GABAPENTIN','CNS'),
('LYRICA','PREGABALIN','CNS'), ('AMBIEN','ZOLPIDEM','CNS'),
('XANAX','ALPRAZOLAM','CNS'), ('ATIVAN','LORAZEPAM','CNS'),
('KLONOPIN','CLONAZEPAM','CNS'), ('VALIUM','DIAZEPAM','CNS'),
('CHANTIX','VARENICLINE','CNS'), ('ADDERALL','AMPHETAMINE','CNS'),
('RITALIN','METHYLPHENIDATE','CNS'), ('CONCERTA','METHYLPHENIDATE','CNS'),
('ARICEPT','DONEPEZIL','CNS'), ('SINEMET','LEVODOPA','CNS'),
-- Analgesia
('ULTRAM','TRAMADOL','Analgesic'), ('ADVIL','IBUPROFEN','Analgesic'),
('MOTRIN','IBUPROFEN','Analgesic'), ('ALEVE','NAPROXEN','Analgesic'),
('NAPROSYN','NAPROXEN','Analgesic'), ('CELEBREX','CELECOXIB','Analgesic'),
('TYLENOL','PARACETAMOL','Analgesic'), ('ACETAMINOPHEN','PARACETAMOL','Analgesic'),
('OXYCONTIN','OXYCODONE','Analgesic'), ('PERCOCET','OXYCODONE','Analgesic'),
('VICODIN','HYDROCODONE','Analgesic'), ('NORCO','HYDROCODONE','Analgesic'),
('DURAGESIC','FENTANYL','Analgesic'), ('MS CONTIN','MORPHINE','Analgesic'),
-- Immunology / oncology
('HUMIRA','ADALIMUMAB','Immunology'), ('ENBREL','ETANERCEPT','Immunology'),
('REMICADE','INFLIXIMAB','Immunology'), ('STELARA','USTEKINUMAB','Immunology'),
('XELJANZ','TOFACITINIB','Immunology'), ('OTEZLA','APREMILAST','Immunology'),
('KEYTRUDA','PEMBROLIZUMAB','Oncology'), ('OPDIVO','NIVOLUMAB','Oncology'),
('HERCEPTIN','TRASTUZUMAB','Oncology'), ('AVASTIN','BEVACIZUMAB','Oncology'),
('RITUXAN','RITUXIMAB','Oncology'), ('GLEEVEC','IMATINIB','Oncology'),
('TREXALL','METHOTREXATE','Immunology'), ('RHEUMATREX','METHOTREXATE','Immunology'),
-- Endocrine / other
('SYNTHROID','LEVOTHYROXINE','Endocrine'), ('LEVOXYL','LEVOTHYROXINE','Endocrine'),
('DELTASONE','PREDNISONE','Endocrine'), ('MEDROL','METHYLPREDNISOLONE','Endocrine'),
('FOSAMAX','ALENDRONATE','Endocrine'), ('PROLIA','DENOSUMAB','Endocrine'),
('ULORIC','FEBUXOSTAT','Endocrine'), ('ZYLOPRIM','ALLOPURINOL','Endocrine'),
('FLOMAX','TAMSULOSIN','Urology'), ('VIAGRA','SILDENAFIL','Urology'),
('CIALIS','TADALAFIL','Urology'), ('ACCUTANE','ISOTRETINOIN','Dermatology'),
('CLARAVIS','ISOTRETINOIN','Dermatology'), ('ABSORICA','ISOTRETINOIN','Dermatology');

/* ---------------------------------------------------------------------------
   3. MedDRA Preferred Term -> System Organ Class.
      Used for dashboard grouping and for the "is this signal clinically
      coherent?" check: a drug whose signals cluster inside one organ class is
      far more plausible than one scattered at random across every class.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS ref_meddra_soc;
CREATE TABLE ref_meddra_soc (
  pt   VARCHAR(255) NOT NULL PRIMARY KEY,
  soc  VARCHAR(96)  NOT NULL,
  KEY ix_soc (soc)
) ENGINE=InnoDB COMMENT='PT to System Organ Class. Coarse mapping covering the demo vocabulary.';

INSERT INTO ref_meddra_soc (pt, soc) VALUES
('DEPRESSION','Psychiatric'), ('SUICIDAL IDEATION','Psychiatric'), ('ANXIETY','Psychiatric'),
('INSOMNIA','Psychiatric'), ('NIGHTMARE','Psychiatric'), ('AGGRESSION','Psychiatric'),
('HALLUCINATION','Psychiatric'), ('CONFUSIONAL STATE','Psychiatric'),
('SOMNOLENCE','Nervous system'), ('DIZZINESS','Nervous system'), ('HEADACHE','Nervous system'),
('TREMOR','Nervous system'), ('SEIZURE','Nervous system'), ('PARAESTHESIA','Nervous system'),
('MEMORY IMPAIRMENT','Nervous system'), ('SEROTONIN SYNDROME','Nervous system'),
('MYOCARDIAL INFARCTION','Cardiac'), ('ATRIAL FIBRILLATION','Cardiac'),
('TACHYCARDIA','Cardiac'), ('ELECTROCARDIOGRAM QT PROLONGED','Cardiac'),
('TORSADE DE POINTES','Cardiac'), ('CARDIAC ARREST','Cardiac'), ('BRADYCARDIA','Cardiac'),
('MYOCARDITIS','Cardiac'), ('HYPOTENSION','Vascular'), ('HYPERTENSION','Vascular'),
('AORTIC ANEURYSM','Vascular'), ('HAEMORRHAGE','Vascular'),
('TENDON RUPTURE','Musculoskeletal'), ('TENDONITIS','Musculoskeletal'),
('MYALGIA','Musculoskeletal'), ('RHABDOMYOLYSIS','Musculoskeletal'),
('ARTHRALGIA','Musculoskeletal'), ('MUSCULAR WEAKNESS','Musculoskeletal'),
('BACK PAIN','Musculoskeletal'),
('NAUSEA','Gastrointestinal'), ('VOMITING','Gastrointestinal'), ('DIARRHOEA','Gastrointestinal'),
('ABDOMINAL PAIN','Gastrointestinal'), ('PANCREATITIS','Gastrointestinal'),
('CLOSTRIDIUM DIFFICILE COLITIS','Gastrointestinal'), ('CONSTIPATION','Gastrointestinal'),
('GASTROINTESTINAL HAEMORRHAGE','Gastrointestinal'),
('HEPATIC FAILURE','Hepatobiliary'), ('HEPATITIS','Hepatobiliary'),
('DIABETIC KETOACIDOSIS','Metabolic'), ('LACTIC ACIDOSIS','Metabolic'),
('HYPOGLYCAEMIA','Metabolic'), ('HYPERKALAEMIA','Metabolic'), ('HYPONATRAEMIA','Metabolic'),
('DEHYDRATION','Metabolic'), ('WEIGHT DECREASED','Investigations'),
('ACUTE KIDNEY INJURY','Renal'),
('AGRANULOCYTOSIS','Blood'), ('NEUTROPENIA','Blood'), ('THROMBOCYTOPENIA','Blood'),
('PANCYTOPENIA','Blood'), ('ANAEMIA','Blood'),
('RASH','Skin'), ('PRURITUS','Skin'), ('URTICARIA','Skin'), ('ANGIOEDEMA','Skin'),
('STEVENS-JOHNSON SYNDROME','Skin'), ('TOXIC EPIDERMAL NECROLYSIS','Skin'),
('ALOPECIA','Skin'), ('PHOTOSENSITIVITY REACTION','Skin'),
('DYSPNOEA','Respiratory'), ('COUGH','Respiratory'), ('PULMONARY FIBROSIS','Respiratory'),
('PNEUMONIA','Infection'), ('RESPIRATORY DEPRESSION','Respiratory'),
('PYREXIA','General'), ('FATIGUE','General'), ('MALAISE','General'),
('DRUG INEFFECTIVE','General'), ('OFF LABEL USE','General'), ('AMPUTATION','Procedural'),
('FOETAL MALFORMATION','Congenital'), ('CONGENITAL ANOMALY','Congenital');

SELECT
  (SELECT COUNT(*) FROM ref_token_strip)      AS strip_tokens,
  (SELECT COUNT(*) FROM ref_brand_ingredient) AS brand_mappings,
  (SELECT COUNT(*) FROM ref_meddra_soc)       AS pt_soc_mappings;
