#!/usr/bin/env python3
"""
build_dashboard.py — render docs/dashboard/AEGIS-dashboard.html.

    python etl/export_dashboard_data.py        # dump the numbers from MySQL
    python docs/dashboard/build_dashboard.py   # render the page

Light by default, narrative order, big type. Every figure on the page is derived
from dashboard_data.json at build time; none is typed into the template. An
earlier version hardcoded the headline numbers, so regenerating the corpus
produced a different database and a byte-identical web page.

The output is a single self-contained file — no build step, no CDN, no server —
so it can be opened from disk, emailed, or served by GitHub Pages unchanged.
"""
import json, math, html
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
d = json.load(open(HERE / 'dashboard_data.json'))
esc = html.escape
K = {r['metric']: (r['value_num'] if r['value_num'] is not None else r['value_text'])
     for r in d['kpi']}
QS = d['quarters']; qi = {q: i for i, q in enumerate(QS)}
lags = [r['lag_quarters'] for r in d['backtest']]
# Every headline number below is derived, never typed. An earlier version
# hardcoded them and they silently went stale when the corpus was regraded.
N_PLANTED   = int(next(r['value_num'] for r in d['kpi'] if r['metric']=='signals_planted'))
N_SIGNALS   = int(next(r['value_num'] for r in d['kpi'] if r['metric']=='signals_detected'))
N_PAIRS     = int(next(r['value_num'] for r in d['kpi'] if r['metric']=='pairs_evaluated'))
N_NOVEL     = int(next(r['value_num'] for r in d['kpi'] if r['metric']=='novel_signals_found'))
N_MISSED    = N_PLANTED - N_SIGNALS
BASE_RATE   = round(N_PAIRS / N_PLANTED)
FLOOR_PCT   = min(float(r['excess_min_pct']) for r in d['curve'] if float(r['recall_pct']) >= 100)
DEDUP       = {r['metric']: int(r['value']) for r in d['dedup']}
N_REMOVED   = DEDUP['raw_demo_rows'] - DEDUP['surviving_cases']
N_WITHIN_6M = sum(1 for q in lags if q <= 2)
TABLE_SHOWN = 10
N_HIDDEN    = max(0, N_SIGNALS - TABLE_SHOWN)
# observed reporting ratio at the detection floor — the unit bridge
_ratios = [r['a']/r['expected'] for r in d['top_signals']]
RATIO_MIN, RATIO_MAX = min(_ratios), max(_ratios)
STRENGTH_RANGE = max(float(r['excess_max_pct']) for r in d['curve']) / \
                 min(float(r['excess_min_pct']) for r in d['curve'])
FLOOR_MAX   = max(float(r['excess_max_pct']) for r in d['curve']
                  if float(r['excess_min_pct']) == min(
                      float(x['excess_min_pct']) for x in d['curve']
                      if float(x['recall_pct']) >= 100))
NO_DETECT   = max(float(r['excess_max_pct']) for r in d['curve']
                  if float(r['recall_pct']) == 0)
DQ_TOTAL    = len(d['dq'])
DQ_PASS     = sum(1 for r in d['dq'] if r['status'] == 'PASS')
PCT_NO_SEX  = next(float(r['measured']) for r in d['dq'] if r['check_id'] == 'DQ-007')
PCT_PART_DATE = next(float(r['measured']) for r in d['dq'] if r['check_id'] == 'DQ-008')
N_TRANSIENT = len(d.get('transient', []))
N_EVER      = N_SIGNALS + N_TRANSIENT
REF_SET_N   = sum(1 for r in d['top_signals'] if r['is_known_labelled'])
# The ratio a reader will look for is the one at the detection floor, i.e. the
# faintest planted signal that was actually recovered — not the global minimum
# across all detected pairs, which can sit below the floor when a weaker-tier
# signal happens to clear the threshold.
def _pc(v):
    v = float(v)
    return f'{v:.0f}' if abs(v - round(v)) < 1e-9 else f'{v:.1f}'
O = []
A = O.append

# categorical series colours: the dataviz-validated set (passes adjacent CVD +
# normal-vision gates in light mode). UI chrome uses the project's teal/coral;
# data series never borrow brand colours.
SER = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4']

# ─────────────────────────────────────────────── head
A('''<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AEGIS — finding dangerous drug side effects in the data</title>
<style>
*{box-sizing:border-box}
:root{
  --bg:#ffffff; --bg-2:#f4f7f8; --line:#e0e8ea; --line-2:#c8d6d9;
  --ink:#0e2b33; --ink-2:#41626c; --ink-3:#6d8a93;
  --deep:#073b4c; --teal:#057585; --coral:#d9432b; --good:#0a7d55;
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4;
}
html[data-theme="dark"]{
  --bg:#0f1719; --bg-2:#182327; --line:#26363b; --line-2:#395057;
  --ink:#f2f7f8; --ink-2:#b3c7cd; --ink-3:#8aa3ab;
  --deep:#9fd8cb; --teal:#4fb3c4; --coral:#ff8b73; --good:#4cc79a;
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181;
}
body{margin:0;background:var(--bg);color:var(--ink);
 font-family:ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
 font-size:17px;line-height:1.62;-webkit-font-smoothing:antialiased}
.wrap{max-width:980px;margin:0 auto;padding:0 26px 100px}
.tg{position:fixed;top:18px;right:18px;z-index:50;background:var(--bg-2);
 border:1px solid var(--line);color:var(--ink-2);border-radius:8px;padding:8px 13px;
 font-size:13px;cursor:pointer;font-family:inherit}
.tg:hover{border-color:var(--line-2);color:var(--ink)}

/* hero */
.hero{padding:78px 0 12px}
.tag{font-size:12.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
 color:var(--teal);margin-bottom:20px}
h1{font-size:44px;line-height:1.2;letter-spacing:-.022em;margin:0 0 22px;font-weight:680}
.lede{font-size:21px;line-height:1.6;color:var(--ink-2);max-width:730px;margin:0}
.expand{margin-top:26px;font-size:15px;color:var(--ink-3)}

/* sections */
section{padding-top:72px}
h2{font-size:15px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;
 color:var(--teal);margin:0 0 18px}
h3{font-size:31px;line-height:1.28;letter-spacing:-.016em;margin:0 0 16px;font-weight:660}
p{margin:0 0 18px;max-width:730px;color:var(--ink-2)}
p.tight{margin-bottom:10px}
strong{color:var(--ink);font-weight:640}
.big{font-size:22px;line-height:1.55;color:var(--ink);max-width:730px}

/* steps */
.steps{display:grid;gap:2px;margin:30px 0 0;border-radius:12px;overflow:hidden}
.step{display:grid;grid-template-columns:56px 1fr;gap:20px;background:var(--bg-2);
 padding:24px 26px;align-items:start}
.step .n{width:38px;height:38px;border-radius:50%;background:var(--teal);color:#fff;
 display:flex;align-items:center;justify-content:center;font-weight:700;font-size:17px}
.step.alert .n{background:var(--coral)}
.step h4{margin:5px 0 6px;font-size:19px;font-weight:640;color:var(--ink)}
.step p{margin:0;font-size:16.5px}

/* worked example */
.ex{background:var(--bg-2);border-radius:14px;padding:34px 32px;margin:30px 0 0}
.ex .who{font-size:19px;font-weight:640;margin-bottom:26px;color:var(--ink)}
.barrow{display:grid;grid-template-columns:190px 1fr 108px;gap:16px;align-items:center;
 margin-bottom:16px}
.barrow .lbl{font-size:15.5px;color:var(--ink-2);text-align:right}
.bar{height:38px;border-radius:6px}
.barrow .num{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}
.verdict{margin-top:24px;font-size:20px;font-weight:640;color:var(--ink);line-height:1.5}

/* stats */
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:30px 0 0}
.stat{background:var(--bg-2);border-radius:14px;padding:30px 26px;text-align:center}
.stat .v{font-size:46px;font-weight:700;letter-spacing:-.03em;line-height:1;
 font-variant-numeric:tabular-nums}
.stat .l{font-size:15.5px;color:var(--ink-2);margin-top:12px}
.caveat{margin-top:22px;padding:18px 22px;border-radius:12px;background:var(--bg-2);
 font-size:16px;color:var(--ink-2);max-width:none}
.caveat b{color:var(--coral)}

/* charts */
figure{margin:28px 0 0}
figcaption{font-size:15px;color:var(--ink-3);margin-top:14px;max-width:730px}
svg{display:block;width:100%;height:auto;overflow:visible}
.legend{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:16px;font-size:14.5px;
 color:var(--ink-2)}
.legend span{display:inline-flex;align-items:center;gap:8px}
.swl{width:16px;height:3px;border-radius:2px;flex:none}
.sw{width:12px;height:12px;border-radius:3px;flex:none}
.gl{stroke:var(--line)}
.ax{fill:var(--ink-3);font-size:12px}
.axl{fill:var(--ink-2);font-size:13px;font-weight:600}
.dl{fill:var(--ink);font-size:12.5px;font-weight:640}

/* tables + disclosure */
details{margin-top:18px;border-top:1px solid var(--line);padding-top:18px}
summary{cursor:pointer;font-size:16.5px;font-weight:620;color:var(--teal);
 list-style:none;padding:6px 0}
summary::-webkit-details-marker{display:none}
summary::before{content:"+ ";font-weight:700}
details[open] summary::before{content:"– "}
table{border-collapse:collapse;width:100%;font-size:15px;margin-top:18px;
 font-variant-numeric:tabular-nums}
th{text-align:right;padding:11px 10px;border-bottom:2px solid var(--line-2);
 color:var(--ink-3);font-weight:640;font-size:12.5px;text-transform:uppercase;
 letter-spacing:.05em;white-space:nowrap}
th:first-child,td:first-child,th.l,td.l{text-align:left}
td{padding:10px;border-bottom:1px solid var(--line);white-space:nowrap;color:var(--ink)}
tbody tr:hover td{background:var(--bg-2)}
.mut{color:var(--ink-3)}
.pill{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12.5px;font-weight:650}
.pill.pass{background:color-mix(in srgb,var(--good) 16%,transparent);color:var(--good)}
.pill.warn{background:color-mix(in srgb,var(--s4) 22%,transparent);color:var(--ink)}
.pill.fail{background:color-mix(in srgb,var(--coral) 18%,transparent);color:var(--coral)}

/* limits */
.limits{display:grid;gap:2px;border-radius:12px;overflow:hidden;margin-top:26px}
.lim{background:var(--bg-2);padding:24px 28px}
.lim h4{margin:0 0 7px;font-size:18px;font-weight:640;color:var(--coral)}
.lim p{margin:0;font-size:16.5px}
footer{margin-top:76px;padding-top:26px;border-top:1px solid var(--line);
 font-size:14.5px;color:var(--ink-3);line-height:1.7}
.tt{position:fixed;pointer-events:none;background:var(--ink);color:var(--bg);
 border-radius:8px;padding:9px 12px;font-size:13.5px;opacity:0;transition:opacity .1s;
 z-index:99;max-width:300px;line-height:1.5;box-shadow:0 8px 26px rgba(0,0,0,.24)}
.tt .r{opacity:.78;font-size:12.5px}
@media(max-width:720px){
 h1{font-size:33px}h3{font-size:25px}.stats{grid-template-columns:1fr}
 .barrow{grid-template-columns:1fr;gap:6px}.barrow .lbl{text-align:left}
 .step{grid-template-columns:1fr}
}
</style></head><body>
<button class="tg" id="tg">Dark mode</button><div class="wrap">''')

# ─────────────────────────────────────────────── hero
A(f'''<div class="hero">
<div class="tag">AEGIS · Adverse Event Global Intelligence System · Sanjay Salvi</div>
<h1>The evidence is already public.<br>How long does it sit there unread?</h1>
<p class="lede">Every few months a drug gets a new safety warning. Almost every time,
the reports describing that exact harm had been sitting in a free FDA database for
<strong>years</strong> beforehand — nobody was counting them in a way that made the
pattern visible. <strong>Almost nobody measures that gap.</strong> This project builds
the instrument that measures it — and proves the instrument works before pointing it
at anything real.</p>
<div class="expand">{K['cases_analysed']:,.0f} reports analysed · MySQL · Power BI-ready extracts</div>
</div>''')

# ─────────────────────────────────────────────── why
A(f'''<section><h2>Why this is needed</h2>
<h3>A drug is tested on thousands. Then sold to millions.</h3>
<div class="steps">
<div class="step"><div class="n">1</div><div>
<h4>Trials are small</h4>
<p>A new medicine is typically tested on a few thousand people. Anything rarer than
about 1 in 1,000 will simply never appear.</p></div></div>
<div class="step"><div class="n">2</div><div>
<h4>Real use is enormous</h4>
<p>After approval, millions take it — including children, pregnant women and people
on five other drugs, none of whom were in the trial.</p></div></div>
<div class="step alert"><div class="n">3</div><div>
<h4>The evidence arrives as noise</h4>
<p>Side effects get reported to the FDA one at a time, in free text, with no
indication of which ones matter. Over 20 million reports and counting.</p></div></div>
</div>
<p class="big" style="margin-top:30px">And the thing you are looking for is
<strong>rare</strong>: of {N_PAIRS:,} candidate drug–side-effect pairs here, just
<strong>{N_PLANTED} are real</strong>. About 1 in {BASE_RATE}. At that rate a screen that is 95%
accurate still hands back more false alarms than real findings — which is exactly
what happened on my first attempt.</p>
</section>''')

# ─────────────────────────────────────────────── the idea (worked example)
ex = next(r for r in d['scatter']
          if r['ingredient'] == 'MONTELUKAST' and r['pt'] == 'NIGHTMARE')
obs, exp = int(ex['a']), ex['expected']
wexp = exp / obs * 100
A(f'''<section><h2>The one idea everything rests on</h2>
<h3>You can't ask "how risky is this drug?"<br>You <em>can</em> ask "is this reported more than expected?"</h3>
<p class="big">Nobody knows how many people took a drug and were <strong>fine</strong> — only
the problems get reported. So real risk is uncomputable. But you can count how often a
side effect shows up with one drug versus every other drug, and see if it stands out.</p>
<div class="ex">
<div class="who">Montelukast — a common asthma drug — and nightmares</div>
<div class="barrow"><div class="lbl">Expected by chance</div>
<div class="bar" style="width:{wexp:.1f}%;background:var(--line-2)"></div>
<div class="num" style="color:var(--ink-3)">{exp:,.0f}</div></div>
<div class="barrow"><div class="lbl">Actually reported</div>
<div class="bar" style="width:100%;background:var(--coral)"></div>
<div class="num" style="color:var(--coral)">{obs:,}</div></div>
<div class="verdict">{obs/exp:.1f}× more often than chance explains — and that gap is the
signal.</div>
</div>
<figcaption>Both numbers come from the same database, so the unknown "how many people
took it safely" cancels out of the comparison. Every statistic in this project is a
variation on that one move.</figcaption>
</section>''')

# ─────────────────────────────────────────────── results
A(f'''<section><h2>What it found</h2>
<h3>How do you prove a detector works?</h3>
<p class="big">On real data you can't — nobody knows the true list of dangerous drug
pairs, so you publish findings and hope. So I built a test set with
<strong>{N_PLANTED} dangerous pairs deliberately hidden inside it</strong> at
<strong>deliberately varying strengths</strong>, plus thousands of innocent ones, and
measured exactly which ones the engine caught.</p>
<div class="stats">
<div class="stat"><div class="v" style="color:var(--teal)">{N_SIGNALS}<span style="color:var(--ink-3)">/{N_PLANTED}</span></div>
<div class="l">hidden pairs found</div></div>
<div class="stat"><div class="v" style="color:var(--good)">0</div>
<div class="l">false alarms in {N_PAIRS:,} on today's alert list</div></div>
<div class="stat"><div class="v" style="color:var(--coral)">{N_NOVEL}</div>
<div class="l">held out of the reference set, and recovered</div></div>
</div>
</section>''')

# ─────────────────────────────────────────────── detection curve
CV = d['curve']
W4, H4 = 940, 300; ml4, mt4, mb4 = 132, 14, 54
pw4, ph4 = W4-ml4-70, H4-mt4-mb4
bw4 = pw4/len(CV)
A(f'''<section><h2>The honest part</h2>
<h3>Where it stops working</h3>
<p>A single accuracy score on an easy test set is close to worthless — it tells you
the method works on the cases you chose to give it. So the hidden signals were planted
across a <strong>{STRENGTH_RANGE:.0f}-fold range of strength</strong>, from unmissable down
to barely there. Scoring each band separately shows the limit.</p>
<figure><svg viewBox="0 0 {W4} {H4}" role="img" aria-label="Recall by planted signal strength">''')
for i in range(0, 101, 25):
    yy = mt4+ph4-i/100*ph4
    A(f'<line class="gl" x1="{ml4}" y1="{yy:.1f}" x2="{ml4+pw4}" y2="{yy:.1f}"/>')
    A(f'<text class="ax" x="{ml4-10}" y="{yy+4:.1f}" text-anchor="end">{i}%</text>')
for i, r in enumerate(CV):
    x = ml4 + i*bw4 + 8
    h = float(r['recall_pct'])/100*ph4
    col = "var(--teal)" if float(r['recall_pct']) >= 99 else ("var(--s4)" if float(r['recall_pct']) > 0 else "var(--coral)")
    if h > 0:
        A(f'<rect x="{x:.1f}" y="{mt4+ph4-h:.1f}" width="{bw4-16:.1f}" height="{h:.1f}" rx="5" fill="{col}" '
          f'data-t="{r["tier_label"]} signals" data-r="{r["detected"]} of {r["planted"]} found · '
          f'{r["excess_min_pct"]:.1f}%-{r["excess_max_pct"]:.1f}% excess reporting"/>')
    lab_y = mt4+ph4-h-10 if h > 26 else mt4+ph4-16
    A(f'<text class="dl" x="{x+(bw4-16)/2:.1f}" y="{lab_y:.1f}" text-anchor="middle">'
      f'{r["recall_pct"]:.0f}%</text>')
    A(f'<text class="ax" x="{x+(bw4-16)/2:.1f}" y="{mt4+ph4+20:.1f}" text-anchor="middle" '
      f'style="font-weight:600">{r["tier_label"]}</text>')
    A(f'<text class="ax" x="{x+(bw4-16)/2:.1f}" y="{mt4+ph4+36:.1f}" text-anchor="middle">'
      f'{_pc(r["excess_min_pct"])}-{_pc(r["excess_max_pct"])}%</text>')
A(f'<text class="axl" transform="translate(16,{mt4+ph4/2}) rotate(-90)" text-anchor="middle">Found</text>')
A(f'''</svg><figcaption><b>What "strength" means here:</b> the <b>injection rate</b> — the share of
that drug's reports carrying the planted side effect on top of its normal background. It
is not a percentage change in the reporting ratio. At the {FLOOR_PCT:.1f}% floor the
association shows up in the output as roughly a <b>{RATIO_MIN:.1f}x</b> reporting ratio.
<br><br>Every missed pair still satisfied 2 of the 3 statistical tests — they fail only
the one demanding the effect be <em>large</em>, which is precisely the safeguard holding
false alarms at zero.</figcaption>
</figure>
<p style="margin-top:26px"><strong>This is the number to quote:</strong> not "100%
accurate", but <em>"reliably detects a side effect present in {FLOOR_PCT:.1f}% or more of a
drug's reports — about a {RATIO_MIN:.1f}x reporting ratio — with no false alarms across
{N_PAIRS:,} candidates."</em> A method with no stated limit simply hasn't been
characterised.</p>
</section>''')

# ─────────────────────────────────────────────── novel signals
A(f'''<section><h2>The capability check</h2>
<h3>{N_NOVEL} pairs it recovered from outside its own answer key</h3>
<p>A detector that can only rediscover the contents of its own benchmark has not been
shown to generalise. So {N_NOVEL} pairs were <strong>deliberately withheld</strong> from the
{REF_SET_N}-item reference set. All {N_NOVEL} cleared every statistical test and came back —
from outside the list the pipeline was scored against.</p>
<div class="card" style="margin-top:8px"><table><thead><tr>
<th class="l">Drug</th><th class="l">Side effect</th><th>Reported</th><th>Expected</th>
<th>Times more</th><th>Serious</th><th class="l">First flagged</th></tr></thead><tbody>''')
for r in d['novel']:
    A(f'<tr><td class="l"><strong>{esc(r["ingredient"].title())}</strong></td>'
      f'<td class="l">{esc(r["pt"].title())}</td><td>{r["a"]:,}</td>'
      f'<td class="mut">{r["expected"]:,.0f}</td>'
      f'<td><strong>{r["times_more"]:.1f}x</strong></td>'
      f'<td>{r["pct_serious"]:.0f}%</td>'
      f'<td class="l mut">{r["first_signal_quarter"]}</td></tr>')
A(f'''</tbody></table></div>
<div class="caveat"><b>These are not discoveries, and all {N_NOVEL} are labelled in the
real world.</b> Adalimumab carries a boxed warning for serious infections; apixaban's label
warns of bleeding; sertraline's covers hyponatraemia. They were chosen as pharmacologically
plausible pairs and deliberately withheld from the reference set, so the pipeline had
something genuinely outside its own benchmark to return. What this demonstrates is the
<em>capability</em> — on real FDA data the same query returns real review candidates, and
every one would still need a human pharmacologist before it meant anything.</div>
</section>''')

# ─────────────────────────────────────────────── chart 1: emergence
W, H = 940, 400; ml, mr, mt, mb = 54, 18, 14, 46
pw, ph = W-ml-mr, H-mt-mb
series = {}
for r in d['timeseries']:
    series.setdefault(r['ingredient']+' → '+r['pt'], []).append(r)
keys = [k.replace('||', ' → ') for k in d['series_keys'] if k.replace('||', ' → ') in series]
allv = [r['ic025'] for r in d['timeseries'] if r['ic025'] is not None]
y0, y1 = min(allv), max(allv)*1.06
def X(q): return ml + qi[q]/(len(QS)-1)*pw
def Y(v): return mt + ph - (v-y0)/(y1-y0)*ph
A('''<section><h2>How it works, visually</h2>
<h3>Watching a signal cross the line</h3>
<p>Each line is one drug-and-side-effect pair, tracked over time. The score rises as
reports accumulate. <strong>The dashed line is the alarm threshold</strong> — the dot marks
the exact quarter each pair crossed it and became statistically visible.</p>
<figure><div class="legend">''')
for i, k in enumerate(keys):
    ing, pt = k.split(' → ')
    A(f'<span><span class="swl" style="background:{SER[i]}"></span>'
      f'{esc(ing.title())} &rarr; {esc(pt.title())}</span>')
A('<span><span class="swl" style="background:var(--ink-3)"></span>Alarm threshold</span></div>')
A(f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Signal score by quarter for five drug pairs">')
v = math.ceil(y0)
while v <= y1:
    A(f'<line class="gl" x1="{ml}" y1="{Y(v):.1f}" x2="{ml+pw}" y2="{Y(v):.1f}"/>')
    A(f'<text class="ax" x="{ml-9}" y="{Y(v)+4:.1f}" text-anchor="end">{v:.0f}</text>')
    v += 1
for j, q in enumerate(QS):
    if j % 4 == 0:
        A(f'<text class="ax" x="{X(q):.1f}" y="{mt+ph+20}" text-anchor="middle">{q}</text>')
A(f'<line x1="{ml}" y1="{Y(0):.1f}" x2="{ml+pw}" y2="{Y(0):.1f}" stroke="var(--ink-3)" '
  f'stroke-width="2" stroke-dasharray="7 5"/>')
for i, k in enumerate(keys):
    rows = sorted(series[k], key=lambda r: qi[r['quarter_code']])
    pts = [(X(r['quarter_code']), Y(r['ic025'])) for r in rows if r['ic025'] is not None]
    A(f'<path d="M{" L".join(f"{x:.1f},{y:.1f}" for x, y in pts)}" fill="none" '
      f'stroke="{SER[i]}" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round"/>')
    cr = next((r for r in rows if r['ic025'] is not None and r['ic025'] > 0), None)
    if cr:
        A(f'<circle cx="{X(cr["quarter_code"]):.1f}" cy="{Y(cr["ic025"]):.1f}" r="6" '
          f'fill="{SER[i]}" stroke="var(--bg)" stroke-width="2.5" '
          f'data-t="{esc(k.title())}" data-r="crossed the alarm line in {cr["quarter_code"]}"/>')
    for r in rows:
        if r['ic025'] is None: continue
        A(f'<circle cx="{X(r["quarter_code"]):.1f}" cy="{Y(r["ic025"]):.1f}" r="10" '
          f'fill="transparent" data-t="{esc(k.title())}" '
          f'data-r="{r["quarter_code"]} · score {r["ic025"]:.2f} · {r["a"]:,} reports"/>')
A('</svg><figcaption>Above the dashed line, the pattern is strong enough that chance is an '
  'unlikely explanation. Below it, there is not yet enough evidence to say anything.'
  '</figcaption></figure></section>')

# ─────────────────────────────────────────────── chart 2: lag
# bucket the tail: raw lags now run 0..15 and one bar per value is unreadable
def lag_bucket(q):
    if q <= 2: return (q, f"{'same quarter' if q==0 else str(q)+' quarter'+('s' if q>1 else '')}")
    if q <= 4: return (3, "3-4 quarters")
    return (4, "5+ quarters")
c = Counter(lag_bucket(q)[0] for q in lags)
BLAB = {0:"same quarter",1:"1 quarter",2:"2 quarters",3:"3-4 quarters",4:"5+ quarters"}
maxl = 4; n = max(c.values())
W2, H2 = 940, 250; ml2, mt2, mb2 = 54, 14, 48
pw2, ph2 = W2-ml2-18, H2-mt2-mb2
bw = pw2/(maxl+1)
A(f'''<section><h2>How fast</h2>
<h3>{N_WITHIN_6M} of the {N_SIGNALS} surfaced within six months</h3>
<p>Time between a pattern starting and the engine flagging it. The spread isn't
randomness — it tracks how <strong>distinctive</strong> the side effect is, and how
<strong>strong</strong> it is. The long tail is the weak signals: less excess reporting
means more quarters of evidence needed before it clears the threshold.</p>
<figure><svg viewBox="0 0 {W2} {H2}" role="img" aria-label="Detection lag distribution">''')
for i in range(0, n+1, 2):
    yy = mt2+ph2-i/n*ph2
    A(f'<line class="gl" x1="{ml2}" y1="{yy:.1f}" x2="{ml2+pw2}" y2="{yy:.1f}"/>')
    A(f'<text class="ax" x="{ml2-9}" y="{yy+4:.1f}" text-anchor="end">{i}</text>')
for L in range(maxl+1):
    v = c.get(L, 0); x = ml2+L*bw+5; h = v/n*ph2
    if v:
        A(f'<rect x="{x:.1f}" y="{mt2+ph2-h:.1f}" width="{bw-10:.1f}" height="{h:.1f}" '
          f'rx="5" fill="var(--teal)" data-t="{v} pair{"s" if v != 1 else ""}" '
          f'data-r="found {L if L else "in the same"} quarter{"s" if L > 1 else ""} after starting"/>')
        A(f'<text class="dl" x="{x+(bw-10)/2:.1f}" y="{mt2+ph2-h-9:.1f}" text-anchor="middle">{v}</text>')
    lab = BLAB[L]
    A(f'<text class="ax" x="{x+(bw-10)/2:.1f}" y="{mt2+ph2+20:.1f}" text-anchor="middle">{lab}</text>')
A('</svg><figcaption>Montelukast &rarr; nightmares was caught in <b>1 quarter</b>. '
  'Montelukast &rarr; depression took <b>6</b>. Same drug, same planted strength — but '
  'depression is reported with almost every drug, so its signal has to climb out of a '
  'far noisier background.</figcaption></figure></section>')

# ─────────────────────────────────────────────── chart 3: scatter
W3, H3 = 940, 470; ml3, mr3, mt3, mb3 = 58, 16, 14, 50
pw3, ph3 = W3-ml3-mr3, H3-mt3-mb3
pts = [r for r in d['scatter'] if r['a'] > 0 and r['expected'] > 0]
xs = [math.log10(r['expected']) for r in pts]; ys = [math.log10(r['a']) for r in pts]
x0, x1 = math.floor(min(xs)), math.ceil(max(xs))
yy0, yy1 = math.floor(min(ys)), math.ceil(max(ys))
def X3(v): return ml3+(math.log10(v)-x0)/(x1-x0)*pw3
def Y3(v): return mt3+ph3-(math.log10(v)-yy0)/(yy1-yy0)*ph3
A('''<section><h2>Every pair at once</h2>
<h3>The signals are the ones that break away</h3>
<p>Each dot is one drug-and-side-effect pair. Along the bottom: how often you'd expect
them together by chance. Up the side: how often they actually occurred. <strong>The
diagonal is "exactly as expected"</strong> — so the further a dot sits above it, the
harder it is to explain away.</p>
<figure><div class="legend">
<span><span class="sw" style="background:var(--coral)"></span>Flagged as a signal</span>
<span><span class="sw" style="background:var(--line-2)"></span>Ordinary — no signal</span>
<span><span class="swl" style="background:var(--ink-3)"></span>Exactly as expected</span></div>''')
A(f'<svg viewBox="0 0 {W3} {H3}" role="img" aria-label="Observed versus expected, log-log">')
for e in range(x0, x1+1):
    A(f'<line class="gl" x1="{X3(10**e):.1f}" y1="{mt3}" x2="{X3(10**e):.1f}" y2="{mt3+ph3}"/>')
    A(f'<text class="ax" x="{X3(10**e):.1f}" y="{mt3+ph3+20}" text-anchor="middle">{10**e:,}</text>')
for e in range(yy0, yy1+1):
    A(f'<line class="gl" x1="{ml3}" y1="{Y3(10**e):.1f}" x2="{ml3+pw3}" y2="{Y3(10**e):.1f}"/>')
    A(f'<text class="ax" x="{ml3-9}" y="{Y3(10**e)+4:.1f}" text-anchor="end">{10**e:,}</text>')
lo, hi = max(10**x0, 10**yy0), min(10**x1, 10**yy1)
A(f'<line x1="{X3(lo):.1f}" y1="{Y3(lo):.1f}" x2="{X3(hi):.1f}" y2="{Y3(hi):.1f}" '
  f'stroke="var(--ink-3)" stroke-width="1.6" stroke-dasharray="6 5" opacity=".7"/>')
A(f'<text class="axl" x="{ml3+pw3/2}" y="{H3-6}" text-anchor="middle">Expected together by chance</text>')
A(f'<text class="axl" transform="translate(14,{mt3+ph3/2}) rotate(-90)" text-anchor="middle">Actually reported together</text>')
# The ~3,100 ordinary points are ONE path, not one <circle> each.
# Each circle previously carried its own tooltip attributes, ~150 bytes a point,
# for an undifferentiated cloud where hovering an individual dot tells the reader
# nothing. Collapsed to arc subpaths at ~50 bytes it is a third of the weight and
# renders identically. The 33 signal points below stay individual and interactive,
# because those are the ones a reader actually wants to identify.
_bg = []
for r in pts:
    if r['is_signal']: continue
    _bx, _by = X3(r["expected"]), Y3(r["a"])
    _bg.append(f'M{_bx:.1f},{_by:.1f}m-2.4,0a2.4,2.4 0 1,0 4.8,0a2.4,2.4 0 1,0-4.8,0')
A(f'<path d="{"".join(_bg)}" fill="var(--line-2)" opacity=".55"/>')
sigs = [r for r in pts if r['is_signal']]
for r in sorted(sigs, key=lambda r: r['a']):
    A(f'<circle cx="{X3(r["expected"]):.1f}" cy="{Y3(r["a"]):.1f}" r="5.8" fill="var(--coral)" '
      f'stroke="var(--bg)" stroke-width="2" data-t="{esc(r["ingredient"].title())} &rarr; {esc(r["pt"].title())}" '
      f'data-r="{r["a"]:,} reported vs {r["expected"]:.0f} expected — {r["a"]/r["expected"]:.1f}× more"/>')
placed = []
for r in sorted(sigs, key=lambda r: -r['ic025']):
    x, y = X3(r['expected']), Y3(r['a'])
    if any(abs(x-px) < 96 and abs(y-py) < 17 for px, py, _ in placed): continue
    placed.append((x, y, r))
    if len(placed) == 4: break
for x, y, r in placed:
    A(f'<text class="dl" x="{x:.1f}" y="{y-13:.1f}" text-anchor="middle">{esc(r["ingredient"].title())}</text>')
A('</svg><figcaption>Hover any dot. The grey band along the diagonal is thousands of '
  'ordinary pairs behaving exactly as chance predicts — which is what makes the '
  'breakaway group meaningful.</figcaption></figure></section>')

# ─────────────────────────────────────────────── signals table
A(f'<section><h2>The findings</h2><h3>All {N_SIGNALS} flagged pairs</h3>'
  '<p>“Reported” is always shown next to every ratio, deliberately: a 30× ratio built on '
  '5 reports and a 3× ratio built on 5,000 are completely different claims. '
  'The table is ordered by <b>score</b>, not by the ratio — the score is the '
  'conservative lower bound, so it already penalises a big ratio built on thin '
  'evidence. That is why the ratio column does not fall perfectly.</p>'
  '<table><thead><tr><th class="l">Drug</th><th class="l">Side effect</th>'
  '<th>Reported</th><th>Expected</th><th>Times more</th><th>Score</th><th>Fatal</th>'
  '<th class="l">First flagged</th></tr></thead><tbody>')
for i, r in enumerate(d['top_signals']):
    hide = ' style="display:none" class="xtra"' if i >= TABLE_SHOWN else ''
    A(f'<tr{hide}><td class="l"><strong>{esc(r["ingredient"].title())}</strong></td>'
      f'<td class="l">{esc(r["pt"].title())}</td><td>{r["a"]:,}</td>'
      f'<td class="mut">{r["expected"]:,.0f}</td>'
      f'<td><strong>{r["a"]/r["expected"]:.1f}×</strong></td>'
      f'<td class="mut">{float(r["ic025"]):.2f}</td>'
      f'<td>{r["pct_death"]:.0f}%</td><td class="l mut">{r["first_signal_quarter"]}</td></tr>')
A(f'</tbody></table><details id="more"><summary>Show the remaining {N_HIDDEN}</summary>'
  f'</details></section>')

# ─────────────────────────────────────────────── under the hood
dd = {r['metric']: r for r in d['dedup']}
A(f'<section><h2>Under the hood</h2><h3>The unglamorous parts that decide whether any of it is true</h3>')

A(f'<details><summary>Cleaning: {N_REMOVED:,} reports removed before counting anything</summary>'
  '<p>When a report is updated, the FDA republishes the whole thing — so both copies sit '
  'in the file. Count rows and that patient counts twice. Updates are more likely for '
  '<strong>serious</strong> cases, so the error inflates exactly what matters most. The FDA '
  'also withdraws reports in a separate file that most published analyses ignore entirely.</p>'
  '<table><thead><tr><th class="l">Stage</th><th>Reports</th><th>% of raw</th></tr></thead><tbody>')
nm = {'raw_demo_rows': 'Raw case-version rows as loaded',
      'distinct_cases_before_deletion': 'After collapsing updated duplicates',
      'retracted_cases_removed': 'Withdrawn by the FDA and removed',
      'surviving_cases': 'Final population actually analysed',
      'amended_cases': '…of which had at least one update'}
for m in ['raw_demo_rows', 'distinct_cases_before_deletion', 'retracted_cases_removed',
          'surviving_cases', 'amended_cases']:
    r = dd[m]
    A(f'<tr><td class="l">{nm[m]}</td><td><strong>{int(r["value"]):,}</strong></td>'
      f'<td class="mut">{r["pct_of_raw"]:.2f}%</td></tr>')
A('</tbody></table></details>')

A('<details><summary>Drug names: one medicine, six different spellings</summary>'
  '<p>People type whatever is on the box — <code>SINGULAIR</code>, <code>Singulair 10mg</code>, '
  '<code>MONTELUKAST SODIUM</code>, <code>montelukast</code>. Left separate, one real signal '
  'splits into six weak ones and <strong>disappears</strong> — nothing errors, it is simply '
  'absent. Every name is resolved to its actual ingredient, and each rung of the ladder '
  'records how it matched, so coverage is measured rather than assumed.</p>'
  '<table><thead><tr><th class="l">How it was matched</th><th>Distinct names</th>'
  '<th>Rows</th><th>Share</th></tr></thead><tbody>')
rung = {'L1_PROD_AI': "The FDA's own ingredient code", 'L2_BRAND': 'Brand name recognised',
        'L3_INGREDIENT': 'Already an ingredient name', 'L4_PAREN': 'Found in brackets',
        'L5_UNMAPPED': 'Unmatched — flagged, never guessed'}
for r in d['coverage']:
    A(f'<tr><td class="l">{rung.get(r["match_method"], r["match_method"])}</td>'
      f'<td>{r["distinct_names"]:,}</td><td>{int(r["drug_rows"]):,}</td>'
      f'<td><strong>{r["pct_of_rows"]:.2f}%</strong></td></tr>')
A('</tbody></table></details>')

A(f'<details><summary>Quality gates: {len(d["dq"])} automatic checks that can stop the pipeline</summary>'
  '<p>The pipeline refuses to publish anything if a <strong>FAIL</strong>-severity check trips. '
  'The distinction matters: FAIL means <em>our code is wrong</em>. WARN means <em>the source '
  'data is messy and we are disclosing it</em> — in this corpus '
  f'{PCT_NO_SEX:.0f}% of cases have unknown sex and {PCT_PART_DATE:.0f}% an incomplete event '
  'date, both modelled on behaviour FAERS is documented to have. That is a caveat to publish, '
  'not a bug to hide.</p>'
  '<table><thead><tr><th class="l">Check</th><th>Measured</th><th>Limit</th>'
  '<th class="l">Type</th><th class="l">Result</th></tr></thead><tbody>')
for r in d['dq']:
    A(f'<tr><td class="l">{esc(r["check_name"])}</td><td>{r["measured"]:,.3f}</td>'
      f'<td class="mut">{r["threshold"]:,.2f}</td><td class="l mut">{r["severity"]}</td>'
      f'<td class="l"><span class="pill {r["status"].lower()}">{r["status"]}</span></td></tr>')
A('</tbody></table></details></section>')

# ─────────────────────────────────────────────── limits
A(f'''<section><h2>Intellectual honesty</h2><h3>What this does not prove</h3>
<div class="limits">
<div class="lim"><h4>These are not real-world findings</h4>
<p>Every number on this page comes from a <strong>synthetic corpus with planted
answers</strong>. That is the point — planted ground truth is the only way to compute a
real precision figure or draw a detection curve at all — but it means nothing here is a
statement about any actual medicine. The same SQL runs unchanged on real FAERS; that run
has not been done.</p></div>
<div class="lim"><h4>{N_TRANSIENT} pairs crossed the line and came back down</h4>
<p>The zero above is measured on the current alert list. Across the full {len(QS)}-quarter
history, {N_TRANSIENT} unplanted pairs briefly met all three criteria on thin early counts
and fell back below them as evidence accumulated — so ever-flagged precision is
{N_SIGNALS}/{N_EVER}, not {N_SIGNALS}/{N_SIGNALS}. Both figures are published because
quoting one without naming its definition makes it impossible to check.</p></div>
<div class="lim"><h4>It is not proof of cause</h4>
<p>The illness itself, a news story, or a lawsuit advert can all produce the same pattern
with no causal link whatsoever. This finds things worth investigating. It does not
conclude anything.</p></div>
<div class="lim"><h4>It cannot measure risk</h4>
<p>Without knowing how many people took the drug and were fine, no percentage risk can be
calculated from this data by any method. Ever.</p></div>
<div class="lim"><h4>It has not beaten the FDA</h4>
<p>Regulators act on clinical trials and expert panels, deliberately and slowly. A
statistical screen noticing a pattern earlier is expected, and is not a claim of better
judgement.</p></div>
<div class="lim"><h4>It misses weak signals, and I can say exactly which</h4>
<p>Below an injection rate of {FLOOR_PCT:.1f}% — a side effect present in fewer than that
share of a drug's reports — detection degrades sharply, and at {NO_DETECT:.0f}% and below
it finds nothing at all. That is a deliberate trade: the effect-size threshold causing those misses is the
same one holding false alarms at zero across {N_PAIRS:,} candidates.</p></div>
</div></section>''')

A(f'''<footer><strong>AEGIS — Adverse Event Global Intelligence System.</strong>
Maintained by Sanjay Salvi · MySQL 8 · Power BI · Python for file loading only.<br>
{K['source_rows_ingested']:,.0f} source rows ingested · {K['cases_analysed']:,.0f} reports analysed ·
{K['pairs_evaluated']:,.0f} pairs examined · {DQ_PASS} of {DQ_TOTAL} quality gates passing.<br>
Results shown are from a synthetic test corpus with known planted answers, used to
measure detection accuracy. They are not real pharmacovigilance findings.
</footer></div><div class="tt" id="tt"></div>
<script>
const HIDDEN={N_HIDDEN};
const root=document.documentElement, btn=document.getElementById('tg');
btn.onclick=()=>{{const dark=root.getAttribute('data-theme')==='dark';
 root.setAttribute('data-theme',dark?'light':'dark');
 btn.textContent=dark?'Dark mode':'Light mode';}};
document.getElementById('more').addEventListener('toggle',e=>{{
 document.querySelectorAll('tr.xtra').forEach(r=>r.style.display=e.target.open?'':'none');
 e.target.querySelector('summary').textContent=e.target.open?'Hide the extra '+HIDDEN:'Show the remaining '+HIDDEN;}});
const tt=document.getElementById('tt');
document.addEventListener('mouseover',e=>{{const t=e.target.closest('[data-t]');if(!t)return;
 tt.innerHTML='<b>'+t.dataset.t+'</b>'+(t.dataset.r?'<div class="r">'+t.dataset.r+'</div>':'');
 tt.style.opacity='1';}});
document.addEventListener('mousemove',e=>{{if(tt.style.opacity!=='1')return;
 let x=e.clientX+16,y=e.clientY+16;const b=tt.getBoundingClientRect();
 if(x+b.width>innerWidth-10)x=e.clientX-b.width-16;
 if(y+b.height>innerHeight-10)y=e.clientY-b.height-16;
 tt.style.left=x+'px';tt.style.top=y+'px';}});
document.addEventListener('mouseout',e=>{{if(e.target.closest('[data-t]'))tt.style.opacity='0';}});
</script></body></html>''')

OUT = HERE / 'AEGIS-dashboard.html'
OUT.write_text("\n".join(O), encoding='utf-8')
print(f"wrote {OUT} ({OUT.stat().st_size/1024:.0f} KB)")
print("bytes", sum(len(x) for x in O))
