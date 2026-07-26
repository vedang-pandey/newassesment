-- ============================================================
-- User Funnel Drop-off Analysis — PostgreSQL
-- ============================================================

-- 1. Schema
DROP TABLE IF EXISTS funnel_events;
CREATE TABLE funnel_events (
    user_id   TEXT NOT NULL,
    step      TEXT NOT NULL,
    ts        TIMESTAMP NOT NULL
);

-- 2. Load data (run from psql; adjust path to wherever the CSV lives)
-- \copy funnel_events(user_id, step, ts) FROM 'funnel_events.csv' WITH (FORMAT csv, HEADER true);

-- 3. Fixed stage order (drives "step ordering awareness" — steps are NOT
--    treated as an unordered category; every later query joins through this)
DROP TABLE IF EXISTS funnel_stage_order;
CREATE TABLE funnel_stage_order (
    step        TEXT PRIMARY KEY,
    stage_order INT NOT NULL,
    stage_label TEXT NOT NULL
);
INSERT INTO funnel_stage_order (step, stage_order, stage_label) VALUES
    ('visited_site',       1, 'Visited Site'),
    ('signup_started',     2, 'Signup Started'),
    ('details_filled',     3, 'Details Filled'),
    ('email_verified',     4, 'Email Verified'),
    ('purchase_completed', 5, 'Purchase Completed');

-- 4. Data quality handling: dedupe to one (earliest) event per user+step
--    before counting, so a user who fired the same event twice isn't
--    double counted.
DROP TABLE IF EXISTS funnel_events_dedup;
CREATE TABLE funnel_events_dedup AS
SELECT DISTINCT ON (user_id, step) user_id, step, ts
FROM funnel_events
ORDER BY user_id, step, ts;

-- ============================================================
-- CORE TASK: unique users per stage + stage-to-stage conversion rate
-- ============================================================
WITH stage_counts AS (
    SELECT
        o.stage_order,
        o.stage_label,
        COUNT(DISTINCT e.user_id) AS users
    FROM funnel_stage_order o
    LEFT JOIN funnel_events_dedup e ON e.step = o.step
    GROUP BY o.stage_order, o.stage_label
),
funnel AS (
    SELECT
        stage_order,
        stage_label,
        users,
        ROUND(100.0 * users / FIRST_VALUE(users) OVER (ORDER BY stage_order), 1)
            AS pct_of_start,
        ROUND(100.0 * users / NULLIF(LAG(users) OVER (ORDER BY stage_order), 0), 1)
            AS conversion_from_prev_pct,
        users - LAG(users) OVER (ORDER BY stage_order) AS users_lost
    FROM stage_counts
)
SELECT
    stage_order,
    stage_label AS stage,
    users,
    pct_of_start,
    COALESCE(conversion_from_prev_pct, 100.0) AS conversion_from_prev_pct,
    ROUND(100.0 - COALESCE(conversion_from_prev_pct, 100.0), 1) AS dropoff_pct,
    COALESCE(-users_lost, 0) AS users_lost
FROM funnel
ORDER BY stage_order;

-- ============================================================
-- AUTOMATED DROP-OFF FLAGGING
-- (single query that returns the biggest-leak stage — no manual reading)
-- ============================================================
WITH stage_counts AS (
    SELECT o.stage_order, o.stage_label,
           COUNT(DISTINCT e.user_id) AS users
    FROM funnel_stage_order o
    LEFT JOIN funnel_events_dedup e ON e.step = o.step
    GROUP BY o.stage_order, o.stage_label
),
transitions AS (
    SELECT
        LAG(stage_label) OVER (ORDER BY stage_order) AS from_stage,
        stage_label AS to_stage,
        LAG(users) OVER (ORDER BY stage_order) AS from_users,
        users AS to_users,
        ROUND(100.0 * (LAG(users) OVER (ORDER BY stage_order) - users)
              / NULLIF(LAG(users) OVER (ORDER BY stage_order), 0), 1) AS dropoff_pct
    FROM stage_counts
)
SELECT from_stage, to_stage, from_users, to_users,
       (from_users - to_users) AS users_lost, dropoff_pct
FROM transitions
WHERE from_stage IS NOT NULL
ORDER BY dropoff_pct DESC
LIMIT 1;

-- ============================================================
-- BONUS: average time-to-convert between consecutive stages
-- ============================================================
WITH first_ts AS (
    SELECT e.user_id, e.step, e.ts, o.stage_order
    FROM funnel_events_dedup e
    JOIN funnel_stage_order o ON o.step = e.step
),
pairs AS (
    SELECT
        a.user_id,
        oa.stage_label AS from_stage,
        ob.stage_label AS to_stage,
        oa.stage_order AS from_order,
        b.ts - a.ts AS gap
    FROM first_ts a
    JOIN first_ts b ON a.user_id = b.user_id AND b.stage_order = a.stage_order + 1
    JOIN funnel_stage_order oa ON oa.stage_order = a.stage_order
    JOIN funnel_stage_order ob ON ob.stage_order = b.stage_order
)
SELECT from_stage, to_stage,
       COUNT(*) AS n_users,
       ROUND(EXTRACT(EPOCH FROM AVG(gap)) / 60, 1) AS avg_minutes
FROM pairs
GROUP BY from_stage, to_stage, from_order
ORDER BY from_order;

-- ============================================================
-- BONUS: segment comparison (even/odd numeric part of user_id as proxy segment)
-- ============================================================
WITH segmented AS (
    SELECT
        user_id,
        step,
        CASE WHEN (SUBSTRING(user_id FROM '[0-9]+')::INT % 2) = 0
             THEN 'Segment A (even ID)' ELSE 'Segment B (odd ID)' END AS segment
    FROM funnel_events_dedup
),
seg_counts AS (
    SELECT segment,
           COUNT(DISTINCT user_id) FILTER (WHERE step = 'visited_site')       AS entered,
           COUNT(DISTINCT user_id) FILTER (WHERE step = 'purchase_completed') AS purchased
    FROM segmented
    GROUP BY segment
)
SELECT segment, entered, purchased,
       ROUND(100.0 * purchased / NULLIF(entered, 0), 1) AS overall_conversion_pct
FROM seg_counts
ORDER BY segment;
