-- Exercise 13-02: an index on the join column of a recursive query.
-- A generated org chart of 111,111 people is traversed twice: the whole organisation, and one team of 11.
-- For each, we measure (from the execution plan, so it does not depend on machine speed):
--   whole_table_scans  how many times the recursive step scanned the WHOLE table (once per round)
--   index_lookups      how many index lookups it did instead (one per person it expanded)

-- Helpers (session-only). They turn an execution plan into STABLE numbers, so nothing depends on machine speed.
CREATE OR REPLACE FUNCTION pg_temp.plan_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r record; result text := '';
BEGIN
    PERFORM set_config('max_parallel_workers_per_gather', '0', true);   -- parallel plans report per-worker averages
    FOR r IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) ' || q LOOP
        result := result || r."QUERY PLAN" || E'\n';
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.scans_of(plan text, rel text) RETURNS int         -- scan nodes on a table
LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM regexp_matches(plan, 'Scan[^\n]* on ' || rel || '[ (]', 'g')
$$;

CREATE OR REPLACE FUNCTION pg_temp.loops_of(plan text, node_pattern text) RETURNS bigint   -- how often a node ran
LANGUAGE sql AS $$
    SELECT COALESCE(SUM((m[1])::bigint), 0)
    FROM regexp_matches(plan, node_pattern || '[^\n]*loops=([0-9]+)', 'g') AS m
$$;

DROP TABLE IF EXISTS pg_temp.big_org;
DROP TABLE IF EXISTS pg_temp.index_results;

-- A generated org chart: 111,111 people in 6 levels (every manager has 10 reports). No index on manager_id yet.
CREATE TEMP TABLE big_org AS
SELECT g AS emp_id,
       CASE WHEN g = 1 THEN NULL ELSE (g - 2) / 10 + 1 END AS manager_id,
       'employee_' || g AS full_name,
       repeat('x', 60)  AS padding
FROM generate_series(1, 111111) AS g;
ALTER TABLE big_org ADD PRIMARY KEY (emp_id);
ANALYZE big_org;

CREATE TEMP TABLE index_results(ord int, scenario text, whole_table_scans bigint, index_lookups bigint,
                                result_rows bigint, max_depth int);

CREATE OR REPLACE FUNCTION pg_temp.measure(label text, first_ord int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE full_plan text; team_plan text; n bigint; d int;
BEGIN
    -- the whole organisation, from the top
    full_plan := pg_temp.plan_of($q$
        WITH RECURSIVE org(emp_id, depth) AS (
            SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
            UNION ALL
            SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id
        ) SELECT COUNT(*), MAX(depth) FROM org $q$);
    WITH RECURSIVE org(emp_id, depth) AS (
        SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
        UNION ALL
        SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id)
    SELECT COUNT(*), MAX(depth) INTO n, d FROM org;
    INSERT INTO index_results VALUES (first_ord, label || ': whole organisation',
        pg_temp.loops_of(full_plan, 'Seq Scan on big_org e'),
        pg_temp.loops_of(full_plan, 'Index Scan using idx_big_org_manager on big_org e'), n, d);

    -- one small team: employee 1112 and the 10 people under them
    team_plan := pg_temp.plan_of($q$
        WITH RECURSIVE team(emp_id, depth) AS (
            SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
            UNION ALL
            SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id
        ) SELECT COUNT(*), MAX(depth) FROM team $q$);
    WITH RECURSIVE team(emp_id, depth) AS (
        SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
        UNION ALL
        SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id)
    SELECT COUNT(*), MAX(depth) INTO n, d FROM team;
    INSERT INTO index_results VALUES (first_ord + 1, label || ': one team of 11',
        pg_temp.loops_of(team_plan, 'Seq Scan on big_org e'),
        pg_temp.loops_of(team_plan, 'Index Scan using idx_big_org_manager on big_org e'), n, d);
END $$;

DO $$ BEGIN PERFORM pg_temp.measure('no index', 1); END $$;
CREATE INDEX idx_big_org_manager ON big_org (manager_id);
ANALYZE big_org;
DO $$ BEGIN PERFORM pg_temp.measure('with index', 3); END $$;

-- Expected: with no index the whole table is scanned once per round (6 rounds for the organisation, 2 for the
-- team); with the index there are no whole-table scans, only one lookup per person expanded.
SELECT scenario, whole_table_scans, index_lookups, result_rows, max_depth
FROM index_results
ORDER BY ord;
