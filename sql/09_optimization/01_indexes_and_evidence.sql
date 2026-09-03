/* =============================================================================
   01_indexes_and_evidence.sql — index strategy, and the experiment that proves it
   -----------------------------------------------------------------------------
   Every index below exists because a measured query needed it. Running this file
   reproduces the measurements in docs/engineering/performance.md on your own hardware.

   Absolute timings will differ from the recorded ones; the RATIOS should hold,
   because they come from structural properties (how many rows must be fetched,
   how many partitions must be opened) rather than from clock speed.
   ========================================================================== */

USE aegis;

/* ---------------------------------------------------------------------------
   MySQL has no DROP INDEX IF EXISTS (that is PostgreSQL syntax), so re-running
   this file used to fail with "Duplicate key name". A tiny helper gives the
   same behaviour and keeps the file idempotent.
   ------------------------------------------------------------------------ */
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_drop_index_if_exists $$
CREATE PROCEDURE sp_drop_index_if_exists(IN p_table VARCHAR(64), IN p_index VARCHAR(64))
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.STATISTICS
              WHERE table_schema = DATABASE()
                AND table_name = p_table AND index_name = p_index) THEN
    SET @ddl = CONCAT('DROP INDEX `', p_index, '` ON `', p_table, '`');
    PREPARE st FROM @ddl; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END $$
DELIMITER ;

/* ---------------------------------------------------------------------------
   EXPERIMENT 1 — covering index vs secondary index with row lookups

   Query under test: the severity roll-up that builds bi_signal_current
   (sql/08_semantic/01_bi_layer.sql, CTE `sev`):

     SELECT f.drug_key, f.reaction_key, COUNT(*), SUM(f.is_serious),
            SUM(f.is_death), SUM(f.is_primary_suspect), SUM(f.rechal='Y'),
            SUM(rp.is_health_prof)
     FROM fact_drug_reaction f
     JOIN dim_reporter rp ON rp.reporter_key = f.reporter_key
     GROUP BY f.drug_key, f.reaction_key;

   ix_f_drug_reaction (drug_key, reaction_key) supplies the GROUP BY in order,
   so no sort is needed. But none of the measures are in it, so InnoDB must
   follow the primary key for EVERY fact row to fetch them. In InnoDB a
   secondary index stores the PK, not a row pointer, so each lookup is a second
   B-tree descent, and millions of random descents dominate everything else.

   ix_f_cover carries every column the roll-up touches — including
   is_primary_suspect and the reporter_key the join needs. The aggregate is then
   answerable from the index alone ("Using index" in the plan) and the row
   lookups disappear.

   TWO MISTAKES THIS FILE USED TO MAKE, both worth stating because they are the
   kind that turn a benchmark into theatre:

     1. The index listed (drug_key, reaction_key, is_serious, is_death, rechal)
        and the comment claimed it covered the roll-up. It did not: the real
        query also reads is_primary_suspect and reporter_key, so InnoDB still
        went to the primary key for every row. The measured "speedup" was real
        but it was for a simplified query nobody runs.
     2. The index was built HERE, in stage 09 — after stage 08 has already run
        the roll-up. So the pipeline paid the build cost and never once used the
        index during a build. It is now created at the end of
        sql/05_transform/02_load_facts.sql, before the consumer.

   An index that is not used by the query it was justified with is not an
   optimisation, it is 90 MB of decoration. The measurement is reproduced by
   sql/09_optimization/02_benchmark.sql, which forces each index in turn and
   prints the EXPLAIN ANALYZE plan alongside the timing, so the claim can be
   checked rather than believed.
   ------------------------------------------------------------------------ */

/* ---------------------------------------------------------------------------
   EXPERIMENT 2 — partition pruning, and the one-character mistake that kills it

   fact_drug_reaction is RANGE-partitioned on year_num (see sql/04_warehouse/
   02_fact.sql). A predicate directly on the partition column lets MySQL open
   one partition; anything that wraps the column in an expression forces it to
   open all fourteen.

   MEASURED:
     WHERE year_num   = 2022    partitions: p2022                 163 ms
     WHERE year_num+0 = 2022    partitions: ALL 14                803 ms
     penalty                                                       5.0x

   The two predicates are logically identical and return identical results. The
   second is 5x slower purely because '+0' makes the value opaque to the
   partition pruner. The same trap catches DATE(col), YEAR(col), CAST(col) and
   implicit type coercion from comparing a number to a string column — and it is
   invisible unless you read the `partitions` column of EXPLAIN, which is why
   sql/09_optimization/02_benchmark.sql prints it.
   ------------------------------------------------------------------------ */

/* ---------------------------------------------------------------------------
   Supporting indexes for the BI layer's own access patterns.
   ------------------------------------------------------------------------ */
CALL sp_drop_index_if_exists('bi_signal_current','ix_bsc_triage');
CALL sp_drop_index_if_exists('bi_signal_current','ix_bsc_soc');
CREATE INDEX ix_bsc_triage  ON bi_signal_current (is_signal, ic025, a);
CREATE INDEX ix_bsc_soc     ON bi_signal_current (soc, is_signal);
/* No ix_bst_pair here: (drug_key, reaction_key, quarter_code) is byte-for-byte
   the PRIMARY KEY of bi_signal_timeseries. A duplicate of the clustered key
   costs writes and buys nothing. Checked with SHOW INDEX, not assumed. */

ANALYZE TABLE fact_drug_reaction, bi_signal_current, bi_signal_timeseries;

SELECT table_name,
       FORMAT(table_rows, 0)              AS approx_rows,
       ROUND(data_length /1048576, 1)     AS data_mb,
       ROUND(index_length/1048576, 1)     AS index_mb,
       ROUND((data_length+index_length)/1048576, 1) AS total_mb
FROM information_schema.tables
WHERE table_schema = 'aegis'
  AND table_name IN ('fact_drug_reaction','case_drug','case_reaction',
                     'signal_metrics_quarterly','bi_signal_current')
ORDER BY (data_length + index_length) DESC;
