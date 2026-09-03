/* =============================================================================
   02_benchmark.sql — reproduce the performance claims on your own machine
   -----------------------------------------------------------------------------
   Run:  mysql -u aegis -p aegis --table < sql/09_optimization/02_benchmark.sql

   Read the `actual time=` figures in the EXPLAIN ANALYZE output and the
   `partitions` column in the plain EXPLAIN output. Absolute numbers depend on
   your hardware; the ratios should reproduce.
   ========================================================================== */

USE aegis;

/* This is the ACTUAL severity roll-up from sql/08_semantic/01_bi_layer.sql,
   copied column for column. Benchmarking a simplified version of the query and
   then quoting the speedup for the real one is how index claims become fiction:
   the real query also reads is_primary_suspect and joins on reporter_key, and
   an index missing either of those is not covering no matter what the plan for
   the simplified query said. */
SELECT '=== 1a. severity roll-up WITHOUT covering index (row lookups) ===' AS benchmark;
EXPLAIN ANALYZE
SELECT f.drug_key, f.reaction_key, COUNT(*) n, SUM(f.is_serious) s,
       SUM(f.is_death) d, SUM(f.is_primary_suspect) ps, SUM(f.rechal='Y') r,
       SUM(rp.is_health_prof) hp
FROM fact_drug_reaction f FORCE INDEX (ix_f_drug_reaction)
JOIN dim_reporter rp ON rp.reporter_key = f.reporter_key
GROUP BY f.drug_key, f.reaction_key;

SELECT '=== 1b. same query WITH covering index ===' AS benchmark;
EXPLAIN ANALYZE
SELECT f.drug_key, f.reaction_key, COUNT(*) n, SUM(f.is_serious) s,
       SUM(f.is_death) d, SUM(f.is_primary_suspect) ps, SUM(f.rechal='Y') r,
       SUM(rp.is_health_prof) hp
FROM fact_drug_reaction f FORCE INDEX (ix_f_cover)
JOIN dim_reporter rp ON rp.reporter_key = f.reporter_key
GROUP BY f.drug_key, f.reaction_key;

SELECT '=== 2a. partition pruning ACTIVE — note partitions column ===' AS benchmark;
EXPLAIN SELECT COUNT(*) FROM fact_drug_reaction WHERE year_num = 2022;
EXPLAIN ANALYZE SELECT COUNT(*) FROM fact_drug_reaction WHERE year_num = 2022;

SELECT '=== 2b. partition pruning DEFEATED by an expression on the key ===' AS benchmark;
EXPLAIN SELECT COUNT(*) FROM fact_drug_reaction WHERE year_num + 0 = 2022;
EXPLAIN ANALYZE SELECT COUNT(*) FROM fact_drug_reaction WHERE year_num + 0 = 2022;

SELECT '=== 3. top signals, the dashboard default query ===' AS benchmark;
EXPLAIN ANALYZE
SELECT ingredient, pt, a, prr, ic025
FROM bi_signal_current
WHERE is_signal = 1
ORDER BY ic025 DESC
LIMIT 25;

SELECT '=== 4. storage footprint by object ===' AS benchmark;
SELECT table_name,
       FORMAT(table_rows,0) approx_rows,
       ROUND(data_length/1048576,1)  data_mb,
       ROUND(index_length/1048576,1) index_mb
FROM information_schema.tables
WHERE table_schema='aegis'
ORDER BY (data_length+index_length) DESC
LIMIT 12;
