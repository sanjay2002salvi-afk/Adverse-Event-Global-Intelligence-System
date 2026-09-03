const pptx = require("pptxgenjs");
const p = new pptx();
p.layout = "LAYOUT_WIDE";                 // 13.333 x 7.5
const W = 13.333, H = 7.5;

// ---- palette: clinical calm + one alert colour ------------------------------
const DEEP = "073B4C";   // deep clinical teal-navy (dominant)
const TEAL = "058C9B";   // supporting teal
const MINT = "9FD8CB";   // pale teal for dark-slide body text
const CORAL = "EF6351";  // THE signal colour, used sparingly
const PAPER = "FFFFFF";
const WASH = "F1F5F6";   // card tint on light slides
const INK = "0E2B33";
const MUTE = "5B7480";

const HEAD = "Cambria", BODY = "Calibri";

function darkSlide() { const s = p.addSlide(); s.background = { color: DEEP }; return s; }
function lightSlide() { const s = p.addSlide(); s.background = { color: PAPER }; return s; }

// eyebrow label, repeated motif across content slides
function eyebrow(s, txt, color) {
  s.addText(txt.toUpperCase(), {
    x: 0.9, y: 0.52, w: 11.5, h: 0.32, fontFace: BODY, fontSize: 13,
    bold: true, color: color || TEAL, charSpacing: 2.4, margin: 0,
  });
}
function title(s, txt, opts) {
  opts = opts || {};
  s.addText(txt, {
    x: 0.9, y: opts.y || 0.95, w: opts.w || 11.5, h: opts.h || 1.15,
    fontFace: HEAD, fontSize: opts.size || 40, bold: true,
    color: opts.color || INK, margin: 0, valign: "top",
  });
}
// numbered circle motif
function numDot(s, n, x, y, fill, txtColor) {
  s.addShape(p.ShapeType.ellipse, { x, y, w: 0.62, h: 0.62, fill: { color: fill } });
  s.addText(String(n), {
    x, y, w: 0.62, h: 0.62, align: "center", valign: "middle",
    fontFace: BODY, fontSize: 20, bold: true, color: txtColor, margin: 0,
  });
}
function card(s, x, y, w, h, fill) {
  s.addShape(p.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.12, fill: { color: fill || WASH },
    shadow: { type: "outer", angle: 90, blur: 10, offset: 0.05, color: "9AAEB5", opacity: 0.35 },
  });
}

/* ============================ 1 · TITLE ================================= */
{
  const s = darkSlide();
  s.addShape(p.ShapeType.ellipse, { x: 10.0, y: -1.5, w: 6.2, h: 6.2, fill: { color: "0A4A5E" } });
  s.addShape(p.ShapeType.ellipse, { x: 11.4, y: 3.9, w: 3.4, h: 3.4, fill: { color: "0A4A5E" } });
  s.addText("AEGIS", {
    x: 0.9, y: 2.0, w: 9, h: 1.5, fontFace: HEAD, fontSize: 88, bold: true,
    color: PAPER, margin: 0, charSpacing: 1,
  });
  s.addText("The evidence is already public.\nHow long does it sit there unread?", {
    x: 0.95, y: 3.45, w: 8.8, h: 1.7, fontFace: BODY, fontSize: 26, color: MINT,
    margin: 0, lineSpacing: 36,
  });
  s.addText("Sanjay Salvi  ·  Adverse Event Global Intelligence System", {
    x: 0.95, y: 5.9, w: 10, h: 0.4, fontFace: BODY, fontSize: 15, color: "6E9AA8", margin: 0,
  });
  s.addNotes("AEGIS = Adverse Event Global Intelligence System. One line: it reads the FDA's database of reported drug side effects and finds the drug-and-side-effect pairs that show up together far more often than chance would explain.");
}


/* ====================== 1b · THE QUESTION ============================== */
{
  const s = lightSlide();
  eyebrow(s, "The question nobody asks");
  s.addText([
    { text: "Every few months a drug gets\na new safety warning.\n", options: { color: INK } },
    { text: "Almost every time, the evidence\nwas already public for years.", options: { color: CORAL } },
  ], {
    x: 0.9, y: 1.62, w: 11.5, h: 2.95, fontFace: HEAD, fontSize: 36, bold: true,
    margin: 0, lineSpacing: 47,
  });
  s.addText("Sitting in a free FDA database. Downloadable by anyone. Nobody was counting it in a way that made the pattern visible.", {
    x: 0.95, y: 4.78, w: 10.2, h: 1.0, fontFace: BODY, fontSize: 19, color: MUTE,
    margin: 0, lineSpacing: 28,
  });
  s.addText("Nobody measures that gap. This project does.", {
    x: 0.9, y: 6.0, w: 11.5, h: 0.7, fontFace: HEAD, fontSize: 27, bold: true, color: DEEP, margin: 0,
  });
  s.addNotes("This is the problem statement. Say it in these words. It reframes the project from 'I implemented a known statistical method' to 'I measured a systemic failure' — which is the difference between a textbook exercise and research.");
}

/* ====================== 2 · THE PROBLEM (statement) ===================== */
{
  const s = lightSlide();
  eyebrow(s, "The problem");
  s.addText([
    { text: "A new drug is tested on ", options: { color: INK } },
    { text: "3,000 people", options: { color: CORAL, bold: true } },
    { text: ".\nThen it is sold to ", options: { color: INK } },
    { text: "10 million", options: { color: CORAL, bold: true } },
    { text: ".", options: { color: INK } },
  ], {
    x: 0.9, y: 1.9, w: 11.5, h: 2.4, fontFace: HEAD, fontSize: 46, bold: true,
    margin: 0, lineSpacing: 60,
  });
  s.addText("Anything rarer than about 1 in 1,000 is invisible during trials. It only appears once the drug is on the market — in reports filed by doctors, pharmacists and patients.", {
    x: 0.95, y: 4.6, w: 9.6, h: 1.3, fontFace: BODY, fontSize: 20, color: MUTE,
    margin: 0, lineSpacing: 30,
  });
  s.addNotes("The gap between trial size and real-world use is the entire reason this field exists.");
}

/* ====================== 3 · REAL EXAMPLE ================================ */
{
  const s = lightSlide();
  eyebrow(s, "This is not hypothetical");
  title(s, "Montelukast");
  s.addText("A very common asthma and allergy drug. Widely prescribed to children.", {
    x: 0.9, y: 2.05, w: 7.2, h: 0.8, fontFace: BODY, fontSize: 20, color: MUTE, margin: 0, lineSpacing: 28,
  });

  card(s, 0.9, 3.05, 5.5, 3.0);
  s.addText("2020", { x: 1.3, y: 3.35, w: 4.7, h: 0.9, fontFace: HEAD, fontSize: 54, bold: true, color: CORAL, margin: 0 });
  s.addText("The FDA added its strongest possible warning — a boxed warning — for serious mental-health side effects, including suicidal thinking.", {
    x: 1.3, y: 4.35, w: 4.7, h: 1.5, fontFace: BODY, fontSize: 16, color: INK, margin: 0, lineSpacing: 24,
  });

  card(s, 6.9, 3.05, 5.5, 3.0);
  s.addText("Years earlier", { x: 7.3, y: 3.35, w: 4.7, h: 0.9, fontFace: HEAD, fontSize: 34, bold: true, color: TEAL, margin: 0 });
  s.addText("The reports describing exactly that pattern were already sitting in the FDA's public database — just never counted in a way that made the pattern visible.", {
    x: 7.3, y: 4.35, w: 4.7, h: 1.5, fontFace: BODY, fontSize: 16, color: INK, margin: 0, lineSpacing: 24,
  });
  s.addNotes("The data was public the whole time. The question this project asks: when would a disciplined statistical screen have flagged it?");
}

/* ====================== 4 · WHAT THE DATA IS =========================== */
{
  const s = lightSlide();
  eyebrow(s, "The raw material");
  title(s, "FAERS");
  s.addText("The FDA's public database of reported drug side effects. Over 20 million reports.", {
    x: 0.9, y: 2.05, w: 10.5, h: 0.8, fontFace: BODY, fontSize: 20, color: MUTE, margin: 0, lineSpacing: 28,
  });
  const rows = [
    ["Who files them", "Doctors, pharmacists, patients, drug companies"],
    ["What each says", "This patient took these drugs and had these reactions"],
    ["What it does NOT say", "How many people took the drug and were fine"],
  ];
  rows.forEach((r, i) => {
    const y = 3.15 + i * 1.25;
    numDot(s, i + 1, 0.9, y, i === 2 ? CORAL : TEAL, PAPER);
    s.addText(r[0], { x: 1.75, y, w: 3.6, h: 0.62, fontFace: BODY, fontSize: 17, bold: true, color: i === 2 ? CORAL : INK, margin: 0, valign: "middle" });
    s.addText(r[1], { x: 5.5, y, w: 6.9, h: 0.62, fontFace: BODY, fontSize: 17, color: MUTE, margin: 0, valign: "middle" });
  });
  s.addNotes("That third row is the whole analytical difficulty. No denominator.");
}

/* ====================== 5 · THE CENTRAL IDEA (dark) ==================== */
{
  const s = darkSlide();
  eyebrow(s, "The one idea everything rests on", MINT);
  s.addText("You cannot ask “how risky is this drug?”", {
    x: 0.9, y: 1.35, w: 11.5, h: 0.85, fontFace: HEAD, fontSize: 34, color: "7FB3C0", margin: 0, italic: true,
  });
  s.addText("You can ask: is this reaction reported\nmore with this drug than with all others?", {
    x: 0.9, y: 2.45, w: 11.5, h: 1.9, fontFace: HEAD, fontSize: 40, bold: true, color: PAPER,
    margin: 0, lineSpacing: 54,
  });
  s.addText("Both sides of that comparison come from the same database, so the missing denominator cancels out. That single move is what makes the whole field possible — and every statistic in this project is a variation on it.", {
    x: 0.95, y: 4.85, w: 10.2, h: 1.5, fontFace: BODY, fontSize: 19, color: MINT, margin: 0, lineSpacing: 28,
  });
  s.addNotes("Interviewers will push on this. The unknown denominator appears on both sides of the ratio and cancels.");
}

/* ====================== 6 · WHAT I BUILT =============================== */
{
  const s = lightSlide();
  eyebrow(s, "What I built");
  title(s, "A pipeline, end to end");
  const steps = [
    ["Ingest", "5.3M rows of raw FAERS-format files"],
    ["Clean", "Remove duplicate and withdrawn reports"],
    ["Resolve", "Turn brand names into real ingredients"],
    ["Model", "A warehouse built for counting"],
    ["Detect", "Four published statistics, in SQL"],
    ["Prove", "Score it against known answers"],
  ];
  steps.forEach((st, i) => {
    const col = i % 3, row = Math.floor(i / 3);
    const x = 0.9 + col * 4.0, y = 2.35 + row * 2.15;
    card(s, x, y, 3.6, 1.85);
    numDot(s, i + 1, x + 0.32, y + 0.3, i === 5 ? CORAL : TEAL, PAPER);
    s.addText(st[0], { x: x + 1.1, y: y + 0.36, w: 2.3, h: 0.45, fontFace: HEAD, fontSize: 22, bold: true, color: INK, margin: 0 });
    s.addText(st[1], { x: x + 0.32, y: y + 1.05, w: 3.0, h: 0.7, fontFace: BODY, fontSize: 14.5, color: MUTE, margin: 0, lineSpacing: 20 });
  });
  s.addNotes("Six stages. Every one is SQL except ingestion, which is thin Python.");
}

/* ====================== 7 · HARD PART 1 ================================ */
{
  const s = lightSlide();
  eyebrow(s, "Hard part 1 of 2");
  title(s, "The same report, counted twice");
  s.addText("When a report is updated, the FDA republishes the whole thing. Both copies sit in the file. Count rows and you count that patient twice — and updates are more likely for the serious cases, so the error inflates exactly what matters most.", {
    x: 0.9, y: 2.1, w: 6.6, h: 2.2, fontFace: BODY, fontSize: 19, color: MUTE, margin: 0, lineSpacing: 29,
  });
  card(s, 8.0, 2.1, 4.4, 3.3);
  s.addText("46,784", { x: 8.3, y: 2.6, w: 3.8, h: 1.1, fontFace: HEAD, fontSize: 60, bold: true, color: CORAL, margin: 0, align: "center" });
  s.addText("duplicate or withdrawn\nreports removed", { x: 8.3, y: 3.75, w: 3.8, h: 0.8, fontFace: BODY, fontSize: 16, color: INK, margin: 0, align: "center", lineSpacing: 22 });
  s.addText("11.1% of the raw data", { x: 8.3, y: 4.6, w: 3.8, h: 0.4, fontFace: BODY, fontSize: 15, bold: true, color: TEAL, margin: 0, align: "center" });
  s.addNotes("Most published FAERS analyses skip the withdrawn-cases file entirely.");
}

/* ====================== 8 · HARD PART 2 ================================ */
{
  const s = lightSlide();
  eyebrow(s, "Hard part 2 of 2");
  title(s, "One drug, six spellings");
  s.addText("People type whatever is on the box.", {
    x: 0.9, y: 2.05, w: 7, h: 0.5, fontFace: BODY, fontSize: 19, color: MUTE, margin: 0,
  });
  const names = ["SINGULAIR", "Singulair 10mg", "MONTELUKAST SODIUM", "montelukast", "MONTELUKAST SOD.", "Singulair (montelukast)"];
  names.forEach((n, i) => {
    const y = 2.68 + i * 0.58;
    s.addShape(p.ShapeType.roundRect, { x: 0.9, y, w: 4.5, h: 0.48, rectRadius: 0.08, fill: { color: WASH } });
    s.addText(n, { x: 1.15, y, w: 4.1, h: 0.48, fontFace: "Courier New", fontSize: 14, color: INK, margin: 0, valign: "middle" });
  });
  s.addShape(p.ShapeType.rightArrow, { x: 5.7, y: 3.9, w: 1.2, h: 0.5, fill: { color: TEAL } });
  card(s, 7.3, 3.35, 5.1, 1.6, DEEP);
  s.addText("MONTELUKAST", { x: 7.5, y: 3.65, w: 4.7, h: 0.5, fontFace: BODY, fontSize: 21, bold: true, color: PAPER, margin: 0, align: "center" });
  s.addText("one ingredient · one count", { x: 7.5, y: 4.22, w: 4.7, h: 0.4, fontFace: BODY, fontSize: 14, color: MINT, margin: 0, align: "center" });
  s.addText("Leave them separate and one real signal splits into six weak ones — and disappears. Nothing errors. It is simply absent.", {
    x: 0.9, y: 6.05, w: 11.5, h: 0.9, fontFace: BODY, fontSize: 18, color: CORAL, bold: true, margin: 0, lineSpacing: 26,
  });
  s.addNotes("This is the most dangerous failure mode in the project because it is silent.");
}

/* ====================== 9 · HOW DO YOU KNOW IT WORKS =================== */
{
  const s = darkSlide();
  eyebrow(s, "The question nobody else answers", MINT);
  s.addText("How do you know\nyour detector works?", {
    x: 0.9, y: 1.5, w: 11.5, h: 1.9, fontFace: HEAD, fontSize: 44, bold: true, color: PAPER, margin: 0, lineSpacing: 56,
  });
  s.addText("On real data you can't. Nobody knows the true list of dangerous drug pairs, so you publish your findings and hope.", {
    x: 0.95, y: 3.65, w: 10.6, h: 0.95, fontFace: BODY, fontSize: 20, color: "7FB3C0", margin: 0, lineSpacing: 29,
  });
  s.addText("So I built a test set where I know the answer.", {
    x: 0.95, y: 4.75, w: 10.6, h: 0.6, fontFace: HEAD, fontSize: 27, bold: true, color: MINT, margin: 0,
  });
  s.addText("A realistic synthetic dataset with 43 dangerous pairs deliberately hidden inside it, plus thousands of innocent ones. Then I measured how many the engine actually found.", {
    x: 0.95, y: 5.5, w: 10.6, h: 1.0, fontFace: BODY, fontSize: 18, color: "7FB3C0", margin: 0, lineSpacing: 26,
  });
  s.addNotes("This is the strongest thing about the project. Say it early in any interview.");
}


/* ====================== 9b · WHY IT IS HARD =========================== */
{
  const s = lightSlide();
  eyebrow(s, "Why this is genuinely hard");
  title(s, "1 real signal per 73 candidates");
  s.addText("Rarity is the whole difficulty. When almost everything you test is innocent, even a very accurate test drowns you in false alarms.", {
    x: 0.9, y: 2.1, w: 11.2, h: 1.0, fontFace: BODY, fontSize: 20, color: MUTE, margin: 0, lineSpacing: 29,
  });
  const bars = [
    ["Pairs examined", 3160, TEAL],
    ["Actually dangerous", 43, CORAL],
  ];
  bars.forEach((b, i) => {
    const y = 3.3 + i * 1.25;
    const w = Math.max(0.55, b[1] / 3160 * 8.6);
    s.addText(b[0], { x: 0.9, y, w: 2.6, h: 0.6, fontFace: BODY, fontSize: 17, color: INK, margin: 0, valign: "middle" });
    s.addShape(p.ShapeType.roundRect, { x: 3.7, y: y + 0.09, w, h: 0.44, rectRadius: 0.06, fill: { color: b[2] } });
    s.addText(String(b[1].toLocaleString()), {
      x: 3.7 + w + 0.18, y, w: 2.0, h: 0.6, fontFace: HEAD, fontSize: 22, bold: true,
      color: b[2], margin: 0, valign: "middle",
    });
  });
  s.addText("A screen that is 95% accurate would still hand back more false alarms than real findings. At this base rate, precision is decided by the false-positive rate — not by how many real ones you catch.", {
    x: 0.9, y: 6.0, w: 11.5, h: 1.1, fontFace: BODY, fontSize: 18, color: INK, margin: 0, lineSpacing: 26,
  });
  s.addNotes("If they ask one technical question, hope it is this one. Low base rate is why the naive approach fails and why measuring precision mattered.");
}

/* ====================== 10 · RESULTS =================================== */
{
  const s = lightSlide();
  eyebrow(s, "Results");
  title(s, "33 of 43 found. Zero false alarms.");
  const stats = [
    ["33 / 43", "hidden pairs found", TEAL],
    ["0", "false alarms in 3,160", DEEP],
    ["6", "held out of the answer key, and recovered", CORAL],
  ];
  stats.forEach((st, i) => {
    const x = 0.9 + i * 3.95;
    card(s, x, 2.5, 3.55, 2.35);
    s.addText(st[0], { x: x + 0.15, y: 2.85, w: 3.25, h: 1.0, fontFace: HEAD, fontSize: 44, bold: true, color: st[2], margin: 0, align: "center" });
    s.addText(st[1], { x: x + 0.15, y: 3.95, w: 3.25, h: 0.7, fontFace: BODY, fontSize: 16, color: INK, margin: 0, align: "center", lineSpacing: 21 });
  });
  s.addText("It missed 10 — and knowing exactly which ones is the more useful result.", {
    x: 0.9, y: 5.3, w: 11.5, h: 0.6, fontFace: HEAD, fontSize: 24, bold: true, color: DEEP, margin: 0,
  });
  s.addText("Every miss was a deliberately weak signal. The next slide shows precisely where the method gives out.", {
    x: 0.9, y: 6.05, w: 11.5, h: 0.8, fontFace: BODY, fontSize: 17, color: MUTE, margin: 0, lineSpacing: 24,
  });
  s.addNotes("Do NOT say 100% accurate. Say: no false alarms, and a measured detection floor. That is a stronger and more defensible claim.");
}

/* ====================== 10b · THE DETECTION CURVE ====================== */
{
  const s = lightSlide();
  eyebrow(s, "The honest part");
  title(s, "Where it stops working");
  s.addText("A perfect score on an easy test set proves nothing. So I hid the signals across a 23-fold range of strength and scored each band separately. Strength = the share of that drug's reports carrying the planted side effect.", {
    x: 0.9, y: 2.05, w: 11.2, h: 1.0, fontFace: BODY, fontSize: 19, color: MUTE, margin: 0, lineSpacing: 27,
  });
  s.addChart(p.ChartType.bar, [{
    name: "Found",
    labels: ["Strong\n16-34%", "Moderate\n7.5-12%", "Weak\n4-6%", "Very weak\n1.5-3%"],
    values: [100, 100, 20, 0],
  }], {
    x: 0.9, y: 3.15, w: 7.3, h: 3.1,
    barDir: "col", chartColors: [TEAL, TEAL, "E8A33D", CORAL],
    showTitle: false, showLegend: false,
    showValue: true, dataLabelPosition: "outEnd", dataLabelFormatCode: '0"%"',
    dataLabelColor: INK, dataLabelFontSize: 14, dataLabelFontFace: BODY, dataLabelFontBold: true,
    catAxisLabelColor: MUTE, catAxisLabelFontSize: 11, catAxisLabelFontFace: BODY,
    valAxisLabelColor: MUTE, valAxisLabelFontSize: 10, valAxisLabelFontFace: BODY,
    valAxisMinVal: 0, valAxisMaxVal: 110, valAxisMajorUnit: 25, valGridLine: { color: "E2E9EB", size: 1 },
    catGridLine: { style: "none" }, barGapWidthPct: 50,
  });
  card(s, 8.6, 3.15, 3.8, 3.1);
  s.addText("The number to quote", { x: 8.9, y: 3.45, w: 3.2, h: 0.4, fontFace: BODY, fontSize: 14, bold: true, color: TEAL, margin: 0 });
  s.addText("Not \u201c100% accurate\u201d.\n\n\u201cReliably detects a side effect present in 7.5% or more of a drug\u2019s reports \u2014 about a 2x reporting ratio \u2014 with no false alarms in 3,160 candidates.\u201d\n\nA method with no stated limit has not been characterised.", {
    x: 8.9, y: 3.88, w: 3.2, h: 2.3, fontFace: BODY, fontSize: 13, color: INK, margin: 0, lineSpacing: 19,
  });
  s.addNotes("Every missed pair still passed 2 of the 3 tests. They fail only the one demanding a LARGE effect - the same rule keeping false alarms at zero. That trade-off is the answer if they push.");
}

/* ====================== 10c · NOVEL SIGNALS ============================ */
{
  const s = lightSlide();
  eyebrow(s, "Why it is worth running", CORAL);
  title(s, "Six from outside its own benchmark");
  s.addText("A detector that only rediscovers its own benchmark has not been shown to generalise. So six pairs were deliberately withheld from the 27-item FDA reference set. All six came back \u2014 and all six are FDA-labelled in reality. A capability check, not a discovery.", {
    x: 0.9, y: 2.05, w: 11.2, h: 0.9, fontFace: BODY, fontSize: 19, color: MUTE, margin: 0, lineSpacing: 27,
  });
  const rows = [
    ["Sertraline", "Low blood sodium", "3.0x"],
    ["Levothyroxine", "Irregular heartbeat", "2.7x"],
    ["Apixaban", "Gastrointestinal bleeding", "2.6x"],
    ["Duloxetine", "Liver inflammation", "2.3x"],
    ["Prednisone", "Pneumonia", "2.2x"],
    ["Adalimumab", "Pneumonia", "2.2x"],
  ];
  rows.forEach((r, i) => {
    const col = i % 2, row = Math.floor(i / 2);
    const x = 0.9 + col * 5.85, y = 3.15 + row * 1.15;
    card(s, x, y, 5.5, 0.92);
    s.addText(r[0], { x: x + 0.28, y, w: 2.0, h: 0.92, fontFace: BODY, fontSize: 16, bold: true, color: INK, margin: 0, valign: "middle" });
    s.addText(r[1], { x: x + 2.3, y, w: 2.3, h: 0.92, fontFace: BODY, fontSize: 14, color: MUTE, margin: 0, valign: "middle" });
    s.addText(r[2], { x: x + 4.55, y, w: 0.75, h: 0.92, fontFace: HEAD, fontSize: 19, bold: true, color: CORAL, margin: 0, valign: "middle", align: "right" });
  });
  s.addText("All six are labelled in the real world \u2014 adalimumab carries a boxed warning for serious infections. They were withheld from the reference set on purpose, so the pipeline had something outside its own benchmark to return. It proves the capability, not a discovery.", {
    x: 0.9, y: 6.45, w: 11.5, h: 0.9, fontFace: BODY, fontSize: 14, color: CORAL, italic: true, margin: 0, lineSpacing: 19,
  });
  s.addNotes("Volunteer the caveat in the same breath - a pharmacology-literate interviewer will know adalimumab and apixaban are labelled, and saying it first is the difference between rigour and an overclaim. On real FDA data this same query returns genuine review candidates, each still needing a human pharmacologist.");
}

/* ====================== 11 · THE BUG =================================== */
{
  const s = lightSlide();
  eyebrow(s, "The most interesting thing I got wrong");
  title(s, "Significant ≠ important", { size: 38 });
  s.addText("Requiring only 2 of the 3 tests flags 61 pairs. Just 43 are real.", {
    x: 0.9, y: 2.05, w: 11.2, h: 0.5, fontFace: BODY, fontSize: 20, color: MUTE, margin: 0,
  });
  card(s, 0.9, 2.85, 5.5, 2.6);
  s.addText("What went wrong", { x: 1.25, y: 3.1, w: 4.8, h: 0.4, fontFace: BODY, fontSize: 15, bold: true, color: CORAL, margin: 0 });
  s.addText("Two of the three tests only ask “is this effect real?” — not “is it big?” With 373,000 cases even an 8% bump passes as real, so trivial effects got flagged. 24 false alarms.", {
    x: 1.25, y: 3.6, w: 4.8, h: 1.6, fontFace: BODY, fontSize: 16, color: INK, margin: 0, lineSpacing: 24,
  });
  card(s, 6.9, 2.85, 5.5, 2.6);
  s.addText("The fix", { x: 7.25, y: 3.1, w: 4.8, h: 0.4, fontFace: BODY, fontSize: 15, bold: true, color: TEAL, margin: 0 });
  s.addText("Require all three to agree. Only one demands a LARGE effect, so making it mandatory sets a floor on size, not just certainty.", {
    x: 7.25, y: 3.6, w: 4.8, h: 1.6, fontFace: BODY, fontSize: 16, color: INK, margin: 0, lineSpacing: 24,
  });
  s.addText("False alarms 18 → 0.  Real pairs found 43 → 33.", {
    x: 0.9, y: 5.75, w: 11.5, h: 0.6, fontFace: HEAD, fontSize: 25, bold: true, color: DEEP, margin: 0,
  });
  s.addText("A real trade, not a free lunch — the 10 lost are 4 weak-tier and 6 very weak. As data grows, “statistically significant” stops meaning “worth caring about.”", {
    x: 0.9, y: 6.45, w: 11.5, h: 0.6, fontFace: BODY, fontSize: 16, color: MUTE, italic: true, margin: 0,
  });
  s.addNotes("Best interview answer in the deck. It shows measurement caught something reading the code never would.");
}

/* ====================== 12 · DETECTION SPEED CHART ===================== */
{
  const s = lightSlide();
  eyebrow(s, "How fast");
  title(s, "22 of the 33 surfaced within six months");
  s.addChart(p.ChartType.bar, [{
    name: "Signals",
    labels: ["Same quarter", "1 quarter", "2 quarters", "3-4 quarters", "5+ quarters"],
    values: [9, 7, 6, 3, 8],
  }], {
    x: 0.9, y: 2.35, w: 7.4, h: 3.9,
    barDir: "col", chartColors: [TEAL],
    showTitle: false, showLegend: false,
    showValue: true, dataLabelPosition: "outEnd",
    dataLabelColor: INK, dataLabelFontSize: 15, dataLabelFontFace: BODY, dataLabelFontBold: true,
    catAxisLabelColor: MUTE, catAxisLabelFontSize: 12, catAxisLabelFontFace: BODY,
    valAxisLabelColor: MUTE, valAxisLabelFontSize: 11, valAxisLabelFontFace: BODY,
    valGridLine: { color: "E2E9EB", size: 1 }, catGridLine: { style: "none" },
    valAxisMinVal: 0, valAxisMaxVal: 11, barGapWidthPct: 55,
  });
  card(s, 8.85, 2.35, 3.55, 3.9);
  s.addText("Why the spread?", { x: 9.15, y: 2.65, w: 3.0, h: 0.4, fontFace: BODY, fontSize: 15, bold: true, color: TEAL, margin: 0 });
  s.addText("Rare, distinctive reactions stand out immediately.\n\nCommon ones — like depression, reported with almost every drug — climb out of a noisier background.\n\nThe long tail is the weak signals: less excess reporting means more quarters of evidence needed.", {
    x: 9.15, y: 3.2, w: 3.0, h: 2.9, fontFace: BODY, fontSize: 13, color: INK, margin: 0, lineSpacing: 19,
  });
  s.addNotes("Montelukast to nightmare: 1 quarter. Montelukast to depression: 6 quarters. Same drug, same planted strength.");
}

/* ============ 13 · WHAT IT CANNOT CLAIM (two slides, 3 each) ============ */
{
  const LIMS = [
    ["These are not real-world findings", "Every number here comes from a synthetic corpus with planted answers \u2014 the only way to compute a real precision figure or draw a detection curve at all. The same SQL runs on real FAERS; that run has not been done."],
    ["It is not proof of cause", "The illness itself, news coverage, or lawsuits can all create the same pattern with no causal link whatsoever."],
    ["It cannot measure risk", "Without knowing how many people took the drug safely, no percentage risk can be calculated from this data. Ever."],
    ["It has not beaten the FDA", "Regulators act on trials and expert panels, deliberately and slowly. A statistical screen seeing something first is expected, not better judgement."],
    ["It misses weak signals \u2014 and I can say which", "Below a 7.5% injection rate it degrades sharply; at 3% and below it sees nothing. That is the price of the threshold keeping false alarms at zero."],
    ["Zero false alarms is measured on today\u2019s list", "Across all 25 quarters, 3 unplanted pairs briefly crossed on thin early counts and fell back below. Ever-flagged precision is 33/36. Both numbers are published."],
  ];
  [0, 1].forEach((half) => {
    const s = lightSlide();
    eyebrow(s, "Intellectual honesty", CORAL);
    title(s, half === 0 ? "What this does not prove" : "What this does not prove (2 of 2)");
    LIMS.slice(half * 3, half * 3 + 3).forEach((l, i) => {
      const y = 2.3 + i * 1.45;
      numDot(s, half * 3 + i + 1, 0.9, y, CORAL, PAPER);
      s.addText(l[0], { x: 1.75, y: y - 0.05, w: 10.4, h: 0.5, fontFace: BODY, fontSize: 21, bold: true, color: INK, margin: 0 });
      s.addText(l[1], { x: 1.75, y: y + 0.48, w: 10.4, h: 0.85, fontFace: BODY, fontSize: 15, color: MUTE, margin: 0, lineSpacing: 21 });
    });
    if (half === 1) {
      s.addText("This finds things worth looking at. It does not decide anything.", {
        x: 0.9, y: 6.62, w: 11.5, h: 0.6, fontFace: HEAD, fontSize: 22, bold: true, color: DEEP, margin: 0,
      });
    }
    s.addNotes("Volunteering limitations is the single most credible thing you can do in a technical interview. Lead with the first one \u2014 the corpus is synthetic \u2014 before anyone asks.");
  });
}

/* ====================== 14 · CLOSE (dark) ============================== */
{
  const s = darkSlide();
  s.addShape(p.ShapeType.ellipse, { x: -2.0, y: 4.0, w: 6.0, h: 6.0, fill: { color: "0A4A5E" } });
  eyebrow(s, "In one sentence", MINT);
  s.addText("A database that reads millions of\nside-effect reports and points at the\nhandful worth a human's attention.", {
    x: 0.9, y: 1.5, w: 11.5, h: 2.6, fontFace: HEAD, fontSize: 36, bold: true, color: PAPER, margin: 0, lineSpacing: 52,
  });
  const tech = [["MySQL", "warehouse + all statistics"], ["Power BI", "analyst dashboard"], ["Python", "file loading only"]];
  tech.forEach((t, i) => {
    const x = 0.9 + i * 3.95;
    s.addShape(p.ShapeType.roundRect, { x, y: 4.75, w: 3.55, h: 1.35, rectRadius: 0.12, fill: { color: "0A4A5E" } });
    s.addText(t[0], { x: x + 0.15, y: 4.95, w: 3.25, h: 0.45, fontFace: BODY, fontSize: 20, bold: true, color: PAPER, margin: 0, align: "center" });
    s.addText(t[1], { x: x + 0.15, y: 5.45, w: 3.25, h: 0.5, fontFace: BODY, fontSize: 14, color: MINT, margin: 0, align: "center" });
  });
  s.addText("github.com/sanjay2002salvi-afk/Adverse-Event-Global-Intelligence-System", {
    x: 0.9, y: 6.5, w: 11.5, h: 0.4, fontFace: BODY, fontSize: 14, color: "6E9AA8", margin: 0,
  });
  s.addNotes("Close on the one-sentence version. If they remember one thing, make it this.");
}

p.writeFile({ fileName: require("path").join(__dirname, "AEGIS-explained.pptx") })
 .then(f => console.log("written:", f));
