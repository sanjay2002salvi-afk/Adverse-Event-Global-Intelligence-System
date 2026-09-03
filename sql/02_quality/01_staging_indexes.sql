/* =============================================================================
   01_staging_indexes.sql — index staging AFTER bulk load, never before
   -----------------------------------------------------------------------------
   Indexes are created here rather than in the CREATE TABLE statements in
   sql/01_staging/ for a concrete reason: maintaining a secondary index during a
   LOAD DATA of several million rows forces a B-tree insert per row and roughly
   triples load time. Loading into a heap and building the index once afterwards
   lets InnoDB sort-build the index in bulk.

   Measured on the demo corpus (~5.2M staging rows): the post-load build shown
   here sustains ~120,000 rows/s. See docs/engineering/performance.md.
   -------------------------------------------------------------------------- */

USE aegis;

ALTER TABLE stg_demo
  ADD KEY ix_demo_case    (caseid, caseversion),
  ADD KEY ix_demo_primary (primaryid),
  ADD KEY ix_demo_quarter (src_quarter);

ALTER TABLE stg_drug
  ADD KEY ix_drug_primary (primaryid),
  ADD KEY ix_drug_name    (drugname(64)),
  ADD KEY ix_drug_ai      (prod_ai(64)),
  ADD KEY ix_drug_role    (role_cod);

ALTER TABLE stg_reac
  ADD KEY ix_reac_primary (primaryid),
  ADD KEY ix_reac_pt      (pt(64));

ALTER TABLE stg_outc ADD KEY ix_outc_primary (primaryid);
ALTER TABLE stg_rpsr ADD KEY ix_rpsr_primary (primaryid);
ALTER TABLE stg_ther ADD KEY ix_ther_primary (primaryid, dsg_drug_seq);
ALTER TABLE stg_indi ADD KEY ix_indi_primary (primaryid, indi_drug_seq);
ALTER TABLE stg_deleted_cases ADD KEY ix_del_case (caseid);

SELECT 'staging indexes built' AS status;
