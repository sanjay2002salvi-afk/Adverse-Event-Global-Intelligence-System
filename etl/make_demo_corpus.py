"""
make_demo_corpus.py — generate a synthetic, FAERS-shaped corpus.

    python etl/make_demo_corpus.py                  # default 2019Q1..2025Q1
    python etl/make_demo_corpus.py --cases 25000    # bigger

======================  READ THIS BEFORE QUOTING ANY NUMBER  ==================
The corpus this produces is SYNTHETIC. It is not FDA data and no result derived
from it is a real pharmacovigilance finding. Its purpose is threefold:

  1. REPRODUCIBILITY. Anyone can clone this repo and run the entire pipeline in
     under five minutes without downloading 40 GB from the FDA.
  2. CORRECTNESS TESTING. Because we plant known drug-reaction associations at
     known strengths starting in known quarters, we have ground truth. The test
     suite asserts that the signal engine recovers the planted pairs and does
     not fire on the unplanted ones. You cannot do that with real data, where
     the truth is unknown.
  3. SHAPE FIDELITY. The generator reproduces the specific dirtiness of real
     FAERS — case-version duplicates, retracted cases, partial dates, free-text
     drug names in six different surface forms, unescaped '$' — so the cleaning
     layer is exercised rather than bypassed.

For real findings, run etl/download_faers.py and etl/load_staging.py instead.
The SQL is identical; only the source of the staging rows changes.
==============================================================================

The planted associations are modelled on genuine, documented drug-safety
findings (see sql/07_backtest/01_fda_safety_actions.sql for the real FDA action
dates and citations). The *association* is real; the *reports* are fabricated.
"""
from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from aegis_common import REPO_ROOT, quarter_range, log  # noqa: E402

SEED = 20260817

# --------------------------------------------------------------------------- #
# Catalogues
# --------------------------------------------------------------------------- #
# (canonical_ingredient, popularity_weight, [surface forms as reporters type them])
DRUGS = [
    ("MONTELUKAST",   9,  ["SINGULAIR", "MONTELUKAST SODIUM", "montelukast", "SINGULAIR 10MG", "MONTELUKAST SOD."]),
    ("LEVOFLOXACIN",  7,  ["LEVAQUIN", "LEVOFLOXACIN", "levofloxacin hemihydrate", "LEVAQUIN (LEVOFLOXACIN)"]),
    ("CIPROFLOXACIN", 7,  ["CIPRO", "CIPROFLOXACIN HCL", "ciprofloxacin", "CIPRO XR"]),
    ("CANAGLIFLOZIN", 5,  ["INVOKANA", "CANAGLIFLOZIN", "canagliflozin"]),
    ("FEBUXOSTAT",    4,  ["ULORIC", "FEBUXOSTAT", "febuxostat"]),
    ("ONDANSETRON",   8,  ["ZOFRAN", "ONDANSETRON HCL", "ondansetron", "ZOFRAN ODT"]),
    ("VARENICLINE",   4,  ["CHANTIX", "VARENICLINE TARTRATE", "varenicline"]),
    ("CLOZAPINE",     5,  ["CLOZARIL", "CLOZAPINE", "clozapine", "FAZACLO"]),
    ("AMIODARONE",    5,  ["CORDARONE", "AMIODARONE HCL", "amiodarone", "PACERONE"]),
    ("ATORVASTATIN", 10,  ["LIPITOR", "ATORVASTATIN CALCIUM", "atorvastatin", "LIPITOR 20 MG"]),
    ("METFORMIN",    10,  ["GLUCOPHAGE", "METFORMIN HCL", "metformin hydrochloride", "GLUCOPHAGE XR"]),
    ("WARFARIN",      8,  ["COUMADIN", "WARFARIN SODIUM", "warfarin", "JANTOVEN"]),
    ("METHOTREXATE",  6,  ["TREXALL", "METHOTREXATE SODIUM", "methotrexate", "RHEUMATREX"]),
    ("ISOTRETINOIN",  4,  ["ACCUTANE", "ISOTRETINOIN", "isotretinoin", "CLARAVIS"]),
    ("VALPROATE",     5,  ["DEPAKOTE", "VALPROIC ACID", "DIVALPROEX SODIUM", "valproate sodium"]),
    ("TRAMADOL",      7,  ["ULTRAM", "TRAMADOL HCL", "tramadol hydrochloride"]),
    ("OMEPRAZOLE",    9,  ["PRILOSEC", "OMEPRAZOLE MAGNESIUM", "omeprazole"]),
    ("SITAGLIPTIN",   5,  ["JANUVIA", "SITAGLIPTIN PHOSPHATE", "sitagliptin"]),
    ("HYDROXYCHLOROQUINE", 5, ["PLAQUENIL", "HYDROXYCHLOROQUINE SULFATE", "hydroxychloroquine"]),
    ("LISINOPRIL",   10,  ["ZESTRIL", "LISINOPRIL", "lisinopril", "PRINIVIL"]),
    ("AMLODIPINE",   10,  ["NORVASC", "AMLODIPINE BESYLATE", "amlodipine"]),
    ("LEVOTHYROXINE",11,  ["SYNTHROID", "LEVOTHYROXINE SODIUM", "levothyroxine"]),
    ("GABAPENTIN",    8,  ["NEURONTIN", "GABAPENTIN", "gabapentin"]),
    ("SERTRALINE",    8,  ["ZOLOFT", "SERTRALINE HCL", "sertraline"]),
    ("IBUPROFEN",     9,  ["ADVIL", "IBUPROFEN", "MOTRIN", "ibuprofen"]),
    ("PREDNISONE",    8,  ["DELTASONE", "PREDNISONE", "prednisone"]),
    ("ALBUTEROL",     8,  ["VENTOLIN", "ALBUTEROL SULFATE", "PROVENTIL", "salbutamol"]),
    ("INSULIN GLARGINE", 6, ["LANTUS", "INSULIN GLARGINE", "BASAGLAR"]),
    ("APIXABAN",      6,  ["ELIQUIS", "APIXABAN", "apixaban"]),
    ("ADALIMUMAB",    5,  ["HUMIRA", "ADALIMUMAB", "adalimumab"]),
    ("ESOMEPRAZOLE",  7,  ["NEXIUM", "ESOMEPRAZOLE MAGNESIUM", "esomeprazole"]),
    ("ROSUVASTATIN",  8,  ["CRESTOR", "ROSUVASTATIN CALCIUM", "rosuvastatin"]),
    ("DULOXETINE",    6,  ["CYMBALTA", "DULOXETINE HCL", "duloxetine"]),
    ("PANTOPRAZOLE",  7,  ["PROTONIX", "PANTOPRAZOLE SODIUM", "pantoprazole"]),
    ("CLOPIDOGREL",   7,  ["PLAVIX", "CLOPIDOGREL BISULFATE", "clopidogrel"]),
    ("FUROSEMIDE",    8,  ["LASIX", "FUROSEMIDE", "furosemide"]),
    ("TAMSULOSIN",    5,  ["FLOMAX", "TAMSULOSIN HCL", "tamsulosin"]),
    ("ALLOPURINOL",   5,  ["ZYLOPRIM", "ALLOPURINOL", "allopurinol"]),
    ("CELECOXIB",     5,  ["CELEBREX", "CELECOXIB", "celecoxib"]),
    ("AZITHROMYCIN",  7,  ["ZITHROMAX", "AZITHROMYCIN", "azithromycin", "Z-PAK"]),
]

# MedDRA Preferred Terms, grouped so background noise is clinically plausible.
REACTIONS = [
    # neuropsychiatric
    ("DEPRESSION", 6), ("SUICIDAL IDEATION", 3), ("ANXIETY", 6), ("INSOMNIA", 7),
    ("NIGHTMARE", 2), ("AGGRESSION", 2), ("HALLUCINATION", 2), ("CONFUSIONAL STATE", 4),
    ("SOMNOLENCE", 5), ("DIZZINESS", 8), ("HEADACHE", 9), ("TREMOR", 4),
    ("SEIZURE", 3), ("PARAESTHESIA", 4), ("MEMORY IMPAIRMENT", 3),
    # cardiac
    ("MYOCARDIAL INFARCTION", 4), ("ATRIAL FIBRILLATION", 3), ("TACHYCARDIA", 5),
    ("ELECTROCARDIOGRAM QT PROLONGED", 2), ("TORSADE DE POINTES", 1),
    ("CARDIAC ARREST", 2), ("BRADYCARDIA", 2), ("HYPOTENSION", 5), ("HYPERTENSION", 5),
    # musculoskeletal
    ("TENDON RUPTURE", 1), ("TENDONITIS", 1), ("MYALGIA", 6), ("RHABDOMYOLYSIS", 2),
    ("ARTHRALGIA", 7), ("MUSCULAR WEAKNESS", 4), ("BACK PAIN", 5),
    # gastrointestinal / hepatic
    ("NAUSEA", 10), ("VOMITING", 8), ("DIARRHOEA", 8), ("ABDOMINAL PAIN", 7),
    ("PANCREATITIS", 2), ("CLOSTRIDIUM DIFFICILE COLITIS", 1),
    ("HEPATIC FAILURE", 2), ("HEPATITIS", 2), ("GASTROINTESTINAL HAEMORRHAGE", 3),
    ("CONSTIPATION", 6),
    # metabolic / renal
    ("DIABETIC KETOACIDOSIS", 2), ("LACTIC ACIDOSIS", 1), ("HYPOGLYCAEMIA", 4),
    ("ACUTE KIDNEY INJURY", 4), ("HYPERKALAEMIA", 3), ("HYPONATRAEMIA", 3),
    ("WEIGHT DECREASED", 4), ("DEHYDRATION", 4),
    # haematological
    ("AGRANULOCYTOSIS", 1), ("NEUTROPENIA", 3), ("THROMBOCYTOPENIA", 3),
    ("PANCYTOPENIA", 2), ("ANAEMIA", 5), ("HAEMORRHAGE", 4),
    # dermatological / immune
    ("RASH", 8), ("PRURITUS", 7), ("URTICARIA", 5), ("ANGIOEDEMA", 3),
    ("STEVENS-JOHNSON SYNDROME", 1), ("TOXIC EPIDERMAL NECROLYSIS", 1),
    ("ALOPECIA", 4), ("PHOTOSENSITIVITY REACTION", 2),
    # respiratory / other
    ("DYSPNOEA", 7), ("COUGH", 6), ("PULMONARY FIBROSIS", 1),
    ("PNEUMONIA", 4), ("PYREXIA", 6), ("FATIGUE", 9), ("MALAISE", 5),
    ("DRUG INEFFECTIVE", 8), ("OFF LABEL USE", 5),
    # obstetric / congenital
    ("FOETAL MALFORMATION", 1), ("CONGENITAL ANOMALY", 1),
    # amputation
    ("AMPUTATION", 1), ("AORTIC ANEURYSM", 1), ("SEROTONIN SYNDROME", 1),
    ("RESPIRATORY DEPRESSION", 2), ("MYOCARDITIS", 1),
]

# Planted ground truth: (ingredient, reaction_pt, emergence_quarter, peak_excess_rate)
# The excess rate ramps linearly from the emergence quarter to the end of the
# window, mimicking how a real signal accumulates as awareness spreads.
PLANTED_SIGNALS = [
    # ========================================================================
    # GRADED GROUND TRUTH
    #
    # v1 of this corpus planted every signal at 16-34% excess reporting. The
    # detector scored 100% precision and 100% recall against it — a real result,
    # but on a uniformly EASY test set. A perfect score on generous inputs tells
    # you nothing about where the method actually breaks, which is the more
    # useful thing to know.
    #
    # This version plants signals across four strength tiers spanning a 20x
    # range, from unmissable down to genuinely marginal. Scoring recall per tier
    # produces a DETECTION CURVE rather than a single number, and the curve is
    # what characterises the method honestly: it names the excess-reporting rate
    # below which this pipeline stops seeing things.
    #
    # Second change: some pairs below are deliberately NOT in
    # sql/07_backtest/01_fda_safety_actions.sql. In v1 every planted signal was
    # already FDA-labelled by construction, so "signals not yet known to
    # regulators" was permanently zero and the project could not demonstrate its
    # own stated value. These NOVEL pairs fix that — they are pharmacologically
    # plausible associations with no entry in our regulatory reference set, so
    # the pipeline has something genuinely unlabelled to surface.
    #
    # (ingredient, reaction, emergence quarter, peak excess reporting rate)
    # ========================================================================

    # ---- TIER 1: STRONG (>= 0.15) — all correspond to real FDA actions -------
    ("MONTELUKAST",        "SUICIDAL IDEATION",              "2019Q2", 0.28),
    ("MONTELUKAST",        "NIGHTMARE",                      "2019Q2", 0.24),
    ("MONTELUKAST",        "DEPRESSION",                     "2019Q3", 0.22),
    ("LEVOFLOXACIN",       "TENDON RUPTURE",                 "2019Q1", 0.30),
    ("LEVOFLOXACIN",       "AORTIC ANEURYSM",                "2020Q1", 0.18),
    ("CIPROFLOXACIN",      "TENDON RUPTURE",                 "2019Q1", 0.22),
    ("CANAGLIFLOZIN",      "DIABETIC KETOACIDOSIS",          "2019Q1", 0.32),
    ("CANAGLIFLOZIN",      "AMPUTATION",                     "2019Q4", 0.20),
    ("FEBUXOSTAT",         "MYOCARDIAL INFARCTION",          "2019Q1", 0.26),
    ("ONDANSETRON",        "ELECTROCARDIOGRAM QT PROLONGED", "2020Q2", 0.24),
    ("ONDANSETRON",        "TORSADE DE POINTES",             "2020Q3", 0.16),
    ("CLOZAPINE",          "AGRANULOCYTOSIS",                "2019Q1", 0.34),
    ("CLOZAPINE",          "MYOCARDITIS",                    "2020Q1", 0.20),
    ("AMIODARONE",         "PULMONARY FIBROSIS",             "2019Q1", 0.28),
    ("ATORVASTATIN",       "RHABDOMYOLYSIS",                 "2019Q1", 0.18),
    ("METFORMIN",          "LACTIC ACIDOSIS",                "2019Q1", 0.20),
    ("WARFARIN",           "GASTROINTESTINAL HAEMORRHAGE",   "2019Q1", 0.24),
    ("METHOTREXATE",       "PANCYTOPENIA",                   "2019Q1", 0.26),
    ("ISOTRETINOIN",       "DEPRESSION",                     "2019Q1", 0.22),
    ("VALPROATE",          "FOETAL MALFORMATION",            "2019Q1", 0.30),
    ("TRAMADOL",           "SEROTONIN SYNDROME",             "2020Q1", 0.22),
    ("TRAMADOL",           "RESPIRATORY DEPRESSION",         "2020Q2", 0.18),
    ("OMEPRAZOLE",         "CLOSTRIDIUM DIFFICILE COLITIS",  "2019Q3", 0.16),
    ("SITAGLIPTIN",        "PANCREATITIS",                   "2019Q2", 0.20),
    ("HYDROXYCHLOROQUINE", "ELECTROCARDIOGRAM QT PROLONGED", "2020Q2", 0.26),
    ("ALLOPURINOL",        "STEVENS-JOHNSON SYNDROME",       "2019Q1", 0.18),
    ("VARENICLINE",        "SUICIDAL IDEATION",              "2019Q1", 0.20),

    # ---- TIER 2: MODERATE (0.07-0.14) — HELD OUT of the reference set --------
    ("APIXABAN",           "GASTROINTESTINAL HAEMORRHAGE",   "2019Q2", 0.12),
    ("SERTRALINE",         "HYPONATRAEMIA",                  "2019Q3", 0.10),
    ("LEVOTHYROXINE",      "ATRIAL FIBRILLATION",            "2019Q2", 0.09),
    ("PREDNISONE",         "PNEUMONIA",                      "2020Q1", 0.08),
    ("ADALIMUMAB",         "PNEUMONIA",                      "2019Q4", 0.075),

    # ---- TIER 3: WEAK (0.035-0.069) — where methods start to struggle --------
    ("CELECOXIB",          "MYOCARDIAL INFARCTION",          "2019Q2", 0.060),
    ("IBUPROFEN",          "GASTROINTESTINAL HAEMORRHAGE",   "2019Q1", 0.055),
    ("FUROSEMIDE",         "ACUTE KIDNEY INJURY",            "2019Q3", 0.050),
    ("INSULIN GLARGINE",   "HYPOGLYCAEMIA",                  "2019Q2", 0.045),
    ("DULOXETINE",         "HEPATITIS",                      "2020Q1", 0.040),

    # ---- TIER 4: VERY WEAK (< 0.035) — expected to be largely missed ---------
    ("AZITHROMYCIN",       "ELECTROCARDIOGRAM QT PROLONGED", "2019Q2", 0.030),
    ("CLOPIDOGREL",        "HAEMORRHAGE",                    "2019Q3", 0.028),
    ("TAMSULOSIN",         "HYPOTENSION",                    "2019Q2", 0.024),
    ("ROSUVASTATIN",       "MYALGIA",                        "2019Q1", 0.020),
    ("PANTOPRAZOLE",       "HYPONATRAEMIA",                  "2020Q1", 0.018),
    ("GABAPENTIN",         "SOMNOLENCE",                     "2019Q2", 0.015),
]


def signal_tier(rate):
    """Strength band a planted signal belongs to. Recall is reported per band —
    a single overall number hides exactly the information that matters."""
    if rate >= 0.15:  return "1_strong"
    if rate >= 0.07:  return "2_moderate"
    if rate >= 0.035: return "3_weak"
    return "4_very_weak"

COUNTRIES = ["US"] * 55 + ["JP", "DE", "GB", "FR", "CA", "IT", "ES", "BR", "IN", "AU", "NL", "CN"]
OCCP = ["MD"] * 30 + ["CN"] * 25 + ["PH"] * 15 + ["OT"] * 12 + ["HP"] * 10 + ["LW"] * 5 + [""] * 3
ROLE = ["PS"] * 30 + ["SS"] * 20 + ["C"] * 45 + ["I"] * 5
OUTC = ["OT"] * 30 + ["HO"] * 28 + ["DE"] * 8 + ["LT"] * 8 + ["DS"] * 6 + ["RI"] * 5 + ["CA"] * 2
ROUTES = ["ORAL", "INTRAVENOUS", "SUBCUTANEOUS", "TOPICAL", "INTRAMUSCULAR", "UNKNOWN", ""]

HEADERS = {
    "DEMO": "primaryid$caseid$caseversion$i_f_code$event_dt$mfr_dt$init_fda_dt$fda_dt$rept_cod$auth_num$mfr_num$mfr_sndr$lit_ref$age$age_cod$age_grp$sex$e_sub$wt$wt_cod$rept_dt$to_mfr$occp_cod$reporter_country$occr_country",
    "DRUG": "primaryid$caseid$drug_seq$role_cod$drugname$prod_ai$val_vbm$route$dose_vbm$cum_dose_chr$cum_dose_unit$dechal$rechal$lot_num$exp_dt$nda_num$dose_amt$dose_unit$dose_form$dose_freq",
    "REAC": "primaryid$caseid$pt$drug_rec_act",
    "OUTC": "primaryid$caseid$outc_cod",
    "RPSR": "primaryid$caseid$rpsr_cod",
    "THER": "primaryid$caseid$dsg_drug_seq$start_dt$end_dt$dur$dur_cod",
    "INDI": "primaryid$caseid$indi_drug_seq$indi_pt",
}


def weighted(items):
    pool = []
    for name, w, *rest in items:
        pool.extend([(name, rest[0] if rest else None)] * w)
    return pool


def qindex(q: str) -> int:
    return int(q[:4]) * 4 + int(q[-1]) - 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default="2019Q1")
    ap.add_argument("--end", default="2025Q1")
    ap.add_argument("--cases", type=int, default=15000, help="cases per quarter")
    args = ap.parse_args()

    rng = random.Random(SEED)
    quarters = quarter_range(args.start, args.end)
    out_root = REPO_ROOT / "data" / "demo"
    out_root.mkdir(parents=True, exist_ok=True)

    drug_pool = weighted([(d[0], d[1], d[2]) for d in DRUGS])
    DRUG_FORMS = [(d[0], d[2]) for d in DRUGS]

    # prod_ai fill rate varies BY DRUG, not uniformly by row.
    # In real FAERS, whether FDA has coded an active ingredient depends on the
    # product and the submitting organisation, so some drugs carry prod_ai on
    # nearly every report and others carry it on none. A uniform fill rate is
    # unrealistic and — more importantly — it lets every drug resolve at rung L1
    # of the standardisation ladder, leaving rungs L2-L5 completely untested.
    # Varying it by drug forces the brand-match and ingredient-match rungs to do
    # real work, which is the point of having them.
    PRODAI_FILL = [0.0, 0.0, 0.15, 0.55, 0.90]
    prodai_rate = {d[0]: PRODAI_FILL[i % len(PRODAI_FILL)] for i, d in enumerate(DRUGS)}
    reac_pool = weighted([(r[0], r[1]) for r in REACTIONS])
    signal_map: dict[str, list[tuple[str, int, float]]] = {}
    for ing, pt, emq, peak in PLANTED_SIGNALS:
        signal_map.setdefault(ing, []).append((pt, qindex(emq), peak))

    last_qi = qindex(quarters[-1])
    caseid_seq = 10_000_000
    total = {"demo": 0, "drug": 0, "reac": 0, "outc": 0, "indi": 0, "ther": 0, "rpsr": 0}

    log(f"Generating {len(quarters)} quarters x {args.cases:,} cases -> {out_root}")

    for q in quarters:
        qi = qindex(q)
        yy, qn = q[2:4], q[-1]
        qdir = out_root / q / "ascii"
        qdir.mkdir(parents=True, exist_ok=True)
        fh = {k: (qdir / f"{k}{yy}Q{qn}.txt").open("w", encoding="utf-8", newline="\n")
              for k in HEADERS}
        for k, f in fh.items():
            f.write(HEADERS[k] + "\n")
        del_fh = (qdir / f"ADR{yy}Q{qn}_DELETED.txt").open("w", encoding="utf-8", newline="\n")
        del_fh.write("caseid\n")

        month0 = {"1": 1, "2": 4, "3": 7, "4": 10}[qn]

        for _ in range(args.cases):
            caseid_seq += 1
            caseid = str(caseid_seq)

            # ---- case versions: ~12% of cases are amended, producing a second
            # row with the same caseid and a higher caseversion. Downstream we
            # must keep only the max version, or every amended case is counted
            # twice. This is the single most common FAERS analysis error.
            versions = [1] if rng.random() > 0.12 else [1, 2]

            # ---- patient attributes
            sex = rng.choices(["F", "M", "UNK", ""], weights=[46, 42, 8, 4])[0]
            age_cod = rng.choices(["YR", "MON", "DEC", ""], weights=[86, 5, 3, 6])[0]
            age = "" if age_cod == "" else (
                str(rng.randint(1, 95)) if age_cod == "YR" else str(rng.randint(1, 30))
            )
            country = rng.choice(COUNTRIES)

            # ---- partial / missing dates, exactly as reporters supply them
            mm = month0 + rng.randint(0, 2)
            dd = rng.randint(1, 28)
            r = rng.random()
            if r < 0.62:
                event_dt = f"20{yy}{mm:02d}{dd:02d}"
            elif r < 0.84:
                event_dt = f"20{yy}{mm:02d}"      # month precision only
            elif r < 0.93:
                event_dt = f"20{yy}"              # year precision only
            else:
                event_dt = ""                     # absent
            fda_dt = f"20{yy}{mm:02d}{dd:02d}"

            # ---- drugs on this case
            n_drugs = rng.choices([1, 2, 3, 4, 5, 6, 8], weights=[22, 24, 20, 14, 10, 7, 3])[0]
            chosen: list[tuple[str, str]] = []      # (ingredient, surface form)
            seen_ing = set()
            for _ in range(n_drugs):
                ing, forms = rng.choice(drug_pool)
                if ing in seen_ing:
                    continue
                seen_ing.add(ing)
                chosen.append((ing, rng.choice(forms)))

            # ---- 9% of cases list the SAME ingredient twice under two different
            # surface forms (e.g. SINGULAIR on drug_seq 1 and MONTELUKAST SODIUM
            # on drug_seq 4). This is common in real FAERS and it is the exact
            # scenario the case_drug collapse exists to handle — yet the earlier
            # generator deduplicated ingredients per case, so the collapse was
            # never exercised and the strongest-role resolution in
            # sql/05_transform/02_load_facts.sql was dead code on the fixture.
            # A test that cannot fail is not a test.
            if chosen and rng.random() < 0.09:
                ing, first_form = rng.choice(chosen)
                alt = [f for f in dict(DRUG_FORMS)[ing] if f != first_form]
                if alt:
                    chosen.append((ing, rng.choice(alt)))

            # ---- reactions: background draw
            n_reac = rng.choices([1, 2, 3, 4, 5, 6], weights=[30, 26, 19, 13, 8, 4])[0]
            reacs = {rng.choice(reac_pool)[0] for _ in range(n_reac)}

            # ---- planted signal injection, ramping with time since emergence
            #
            # Iterate UNIQUE ingredients, not `chosen`. The 9% duplicate-form
            # block above appends the same ingredient a second time, and
            # iterating `chosen` directly would run the Bernoulli draw twice for
            # it: effective rate 1-(1-p)^2, i.e. ~2p. That inflated the true
            # injected rate roughly 9% above the rate recorded in
            # tests/ground_truth.sql, which is the x-axis of the detection
            # curve. A ground truth that does not match what was actually
            # planted makes every recall figure downstream slightly optimistic.
            for ing in dict(chosen):
                for pt, em_qi, peak in signal_map.get(ing, []):
                    if qi < em_qi:
                        continue
                    ramp = min(1.0, (qi - em_qi + 1) / max(1, (last_qi - em_qi) * 0.55))
                    if rng.random() < peak * ramp:
                        reacs.add(pt)

            for ver in versions:
                primaryid = f"{caseid}{ver}"
                # DEMO
                fh["DEMO"].write("$".join([
                    primaryid, caseid, str(ver), "I" if ver == 1 else "F",
                    event_dt, "", fda_dt, fda_dt,
                    rng.choices(["EXP", "PER", "DIR"], weights=[62, 33, 5])[0],
                    "", f"MFR{rng.randint(1000, 9999)}",
                    rng.choice(["PFIZER", "NOVARTIS", "MERCK", "GSK", "SANOFI", "TEVA",
                                "ASTRAZENECA", "ABBVIE", "LILLY", "JANSSEN", ""]),
                    "", age, age_cod, "", sex, "Y",
                    str(rng.randint(40, 130)) if rng.random() < 0.28 else "", "KG",
                    fda_dt, "", rng.choice(OCCP), country, country,
                ]) + "\n")
                total["demo"] += 1

                for seq, (ing, surface) in enumerate(chosen, start=1):
                    # 3% of rows carry an unescaped '$' in free text — the real
                    # corruption mode that shifts every subsequent field.
                    if rng.random() < 0.03:
                        surface = surface + "$" + rng.choice(["10MG", "PRN", "TAB"])
                    fh["DRUG"].write("$".join([
                        primaryid, caseid, str(seq), rng.choice(ROLE), surface,
                        ing if rng.random() < prodai_rate[ing] else "",  # varies by drug
                        rng.choice(["1", "2"]), rng.choice(ROUTES), "", "", "",
                        rng.choices(["Y", "N", "U", "D", ""], weights=[18, 10, 30, 6, 36])[0],
                        rng.choices(["Y", "N", "U", "D", ""], weights=[5, 8, 26, 4, 57])[0],
                        "", "", str(rng.randint(10000, 99999)),
                        str(rng.choice([5, 10, 20, 25, 40, 50, 100, 250, 500])),
                        "MG", rng.choice(["TABLET", "CAPSULE", "SOLUTION", ""]),
                        rng.choice(["QD", "BID", "TID", "PRN", ""]),
                    ]) + "\n")
                    total["drug"] += 1

                    if rng.random() < 0.55:
                        fh["INDI"].write("$".join([
                            primaryid, caseid, str(seq),
                            rng.choice(["HYPERTENSION", "TYPE 2 DIABETES MELLITUS", "ASTHMA",
                                        "PAIN", "DEPRESSION", "INFECTION", "PROPHYLAXIS",
                                        "RHEUMATOID ARTHRITIS", "GOUT", "PRODUCT USED FOR "
                                        "UNKNOWN INDICATION"]),
                        ]) + "\n")
                        total["indi"] += 1

                    if rng.random() < 0.45:
                        sd = f"20{yy}{max(1, mm - rng.randint(0, 6)):02d}{rng.randint(1, 28):02d}"
                        fh["THER"].write("$".join([
                            primaryid, caseid, str(seq), sd, "",
                            str(rng.randint(1, 400)), "DAY",
                        ]) + "\n")
                        total["ther"] += 1

                # sorted(): set iteration order varies with PYTHONHASHSEED, so an
                # unsorted loop made 50 of 200 output files differ byte-for-byte
                # between runs despite the fixed SEED. Analytical results were
                # unaffected, but the checksums in ingest_ledger were not stable.
                for pt in sorted(reacs):
                    fh["REAC"].write("$".join([primaryid, caseid, pt, ""]) + "\n")
                    total["reac"] += 1

                for oc in sorted({rng.choice(OUTC) for _ in range(rng.randint(1, 3))}):
                    fh["OUTC"].write("$".join([primaryid, caseid, oc]) + "\n")
                    total["outc"] += 1

                fh["RPSR"].write("$".join([
                    primaryid, caseid,
                    rng.choices(["FGN", "CSM", "HP", "LIT", "SDY", "OTH"],
                                weights=[30, 28, 22, 8, 6, 6])[0],
                ]) + "\n")
                total["rpsr"] += 1

            # ---- ~0.4% of cases are later retracted by FDA
            if rng.random() < 0.004:
                del_fh.write(caseid + "\n")

        for f in fh.values():
            f.close()
        del_fh.close()
        log(f"  {q} written")

    # ---- emit ground truth alongside the corpus -----------------------------
    # Written here, by the same code that plants the signals, so the truth table
    # and the data can never drift apart. A hand-maintained copy would.
    gt_path = REPO_ROOT / "tests" / "ground_truth.sql"
    gt_path.parent.mkdir(parents=True, exist_ok=True)
    rows = ",\n".join(
        f"  ('{ing}', '{pt}', '{emq}', {peak}, '{signal_tier(peak)}')"
        for ing, pt, emq, peak in PLANTED_SIGNALS
    )
    gt_path.write_text(
        "/* AUTO-GENERATED by etl/make_demo_corpus.py — do not edit by hand.\n"
        "   The ground truth for the demo corpus: which drug-reaction pairs were\n"
        "   deliberately planted, from which quarter, at what excess rate.\n"
        "   tests/02_detection_curve.sql scores the engine against this. */\n\n"
        "USE aegis;\n\n"
        "DROP TABLE IF EXISTS ground_truth_signals;\n"
        "CREATE TABLE ground_truth_signals (\n"
        "  ingredient        VARCHAR(128) NOT NULL,\n"
        "  pt                VARCHAR(255) NOT NULL,\n"
        "  emergence_quarter CHAR(6)      NOT NULL,\n"
        "  peak_excess_rate  DECIMAL(6,4) NOT NULL,\n"
        "  strength_tier     VARCHAR(16)  NOT NULL,\n"
        "  PRIMARY KEY (ingredient, pt)\n"
        ") ENGINE=InnoDB COMMENT='Planted associations in the synthetic demo corpus.';\n\n"
        "INSERT INTO ground_truth_signals\n"
        "  (ingredient, pt, emergence_quarter, peak_excess_rate, strength_tier) VALUES\n"
        f"{rows};\n\n"
        f"SELECT COUNT(*) AS planted_pairs FROM ground_truth_signals;\n",
        encoding="utf-8",
    )

    log("\nDemo corpus totals:")
    for k, v in total.items():
        log(f"  {k:<6} {v:>12,}")
    log(f"\nPlanted ground-truth pairs: {len(PLANTED_SIGNALS)} -> {gt_path.relative_to(REPO_ROOT)}")
    log("Next:  python etl/load_staging.py --demo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
