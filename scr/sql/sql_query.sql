
-- ============================================================
-- MERIDIAN CLAIMS ETL PROJECT
-- FINANCE AND OPERATIONS REPORTING
-- Database: meridian_claims
--
-- Reports:
-- 1. Profit or Loss by Plan
-- 2. Cost per Member
-- 3. Claim Processing Time
-- 4. Denial Reasons
-- ============================================================


-- ============================================================
-- SECTION 1: SELECT DATABASE AND VERIFY TABLES
-- ============================================================

USE meridian_claims;

-- Confirm that the required tables exist
SHOW TABLES;

-- Inspect the important table structures
DESCRIBE fact_claims;
DESCRIBE fact_premiums;
DESCRIBE dim_plan;
DESCRIBE dim_member;
DESCRIBE dim_date;
DESCRIBE dim_claim_status;
DESCRIBE stg_claims_header_monthly;


-- ============================================================
-- REPORT 1: FINANCE - PROFIT OR LOSS BY PLAN
--
-- Simplified calculation:
-- Profit/Loss = Premium Revenue - Claims Paid
--
-- Assumption:
-- Claims are associated with the member's plan in the
-- same calendar month.

-- ============================================================

WITH premium_monthly AS (
    -- Aggregate premiums by member, plan and month
    SELECT
        fp.member_key,
        fp.plan_key,
        dd.year_num,
        dd.month_num,
        SUM(fp.premium_amount) AS premium_revenue
    FROM fact_premiums AS fp
    JOIN dim_date AS dd
        ON fp.premium_date_key = dd.date_key
    WHERE fp.member_key IS NOT NULL
      AND fp.plan_key IS NOT NULL
    GROUP BY
        fp.member_key,
        fp.plan_key,
        dd.year_num,
        dd.month_num
),

member_plan_count AS (
    -- Count distinct plans for each member and month
    SELECT
        member_key,
        year_num,
        month_num,
        COUNT(DISTINCT plan_key) AS plan_count
    FROM premium_monthly
    GROUP BY
        member_key,
        year_num,
        month_num
),

claims_monthly AS (
    -- Aggregate paid claims by member and service month
    SELECT
        fc.member_key,
        dd.year_num,
        dd.month_num,
        SUM(COALESCE(fc.total_paid, 0)) AS claims_paid
    FROM fact_claims AS fc
    JOIN dim_date AS dd
        ON fc.service_from_date_key = dd.date_key
    WHERE fc.member_key IS NOT NULL
    GROUP BY
        fc.member_key,
        dd.year_num,
        dd.month_num
),

plan_finance AS (
    -- Allocate claims only to an unambiguous monthly plan
    SELECT
        pm.plan_key,
        SUM(pm.premium_revenue) AS premium_revenue,
        SUM(COALESCE(cm.claims_paid, 0)) AS claims_paid
    FROM premium_monthly AS pm
    JOIN member_plan_count AS mpc
        ON pm.member_key = mpc.member_key
       AND pm.year_num = mpc.year_num
       AND pm.month_num = mpc.month_num
       AND mpc.plan_count = 1
    LEFT JOIN claims_monthly AS cm
        ON pm.member_key = cm.member_key
       AND pm.year_num = cm.year_num
       AND pm.month_num = cm.month_num
    GROUP BY pm.plan_key
)

SELECT
    dp.plan_id,
    ROUND(pf.premium_revenue, 2) AS premium_revenue,
    ROUND(pf.claims_paid, 2) AS claims_paid,
    ROUND(
        pf.premium_revenue - pf.claims_paid,
        2
    ) AS profit_or_loss
FROM plan_finance AS pf
JOIN dim_plan AS dp
    ON pf.plan_key = dp.plan_key
ORDER BY profit_or_loss DESC;


-- ============================================================
-- REPORT 2: FINANCE - COST PER MEMBER
--
-- Measures:
-- 1. Number of distinct claims
-- 2. Total amount paid for claims
-- 3. Average paid amount per claim
-- ============================================================

SELECT
    m.member_id,

    COUNT(DISTINCT f.claim_id) AS total_claims,

    ROUND(
        SUM(COALESCE(f.total_paid, 0)),
        2
    ) AS total_claim_cost,

    ROUND(
        SUM(COALESCE(f.total_paid, 0))
        / NULLIF(COUNT(DISTINCT f.claim_id), 0),
        2
    ) AS average_cost_per_claim

FROM fact_claims AS f

JOIN dim_member AS m
    ON f.member_key = m.member_key

GROUP BY
    m.member_key,
    m.member_id

ORDER BY total_claim_cost DESC;


-- Overall average claim cost per member
-- This is different from the average cost per claim.

SELECT
    ROUND(
        SUM(COALESCE(total_paid, 0)),
        2
    ) AS total_claim_cost,

    COUNT(DISTINCT member_key) AS total_members,

    ROUND(
        SUM(COALESCE(total_paid, 0))
        / NULLIF(COUNT(DISTINCT member_key), 0),
        2
    ) AS average_cost_per_member

FROM fact_claims;


-- ============================================================
-- REPORT 3: OPERATIONS - CLAIM PROCESSING TIME
--
-- Processing time = Processed Date - Received Date
-- Output: Individual claim processing time in days
-- ============================================================

SELECT
    f.claim_id,

    received.full_date AS received_date,

    processed.full_date AS processed_date,

    DATEDIFF(
        processed.full_date,
        received.full_date
    ) AS processing_days,

    s.claim_status

FROM fact_claims AS f

LEFT JOIN dim_date AS received
    ON f.received_date_key = received.date_key

LEFT JOIN dim_date AS processed
    ON f.processed_date_key = processed.date_key

LEFT JOIN dim_claim_status AS s
    ON f.status_key = s.status_key

ORDER BY processing_days DESC;


-- Overall claim processing performance
-- Excludes missing dates and negative processing durations.

SELECT
    COUNT(*) AS total_claims,

    ROUND(
        AVG(
            DATEDIFF(
                processed.full_date,
                received.full_date
            )
        ),
        2
    ) AS average_processing_days,

    MIN(
        DATEDIFF(
            processed.full_date,
            received.full_date
        )
    ) AS minimum_processing_days,

    MAX(
        DATEDIFF(
            processed.full_date,
            received.full_date
        )
    ) AS maximum_processing_days

FROM fact_claims AS f

JOIN dim_date AS received
    ON f.received_date_key = received.date_key

JOIN dim_date AS processed
    ON f.processed_date_key = processed.date_key

WHERE processed.full_date >= received.full_date;


-- ============================================================
-- REPORT 4: OPERATIONS - DENIAL REASONS
--
-- Measures:
-- 1. Denied records per denial code
-- 2. Percentage of all denied records
--

-- ============================================================

SELECT
    COALESCE(
        NULLIF(TRIM(denial_code), ''),
        'No denial code'
    ) AS denial_reason,

    COUNT(*) AS denied_claims,

    ROUND(
        100.0 * COUNT(*)
        / NULLIF(SUM(COUNT(*)) OVER (), 0),
        2
    ) AS percentage_of_denied_claims

FROM stg_claims_header_monthly

WHERE LOWER(TRIM(claim_status)) = 'denied'

GROUP BY
    COALESCE(
        NULLIF(TRIM(denial_code), ''),
        'No denial code'
    )

ORDER BY denied_claims DESC;


-- ============================================================
-- FINAL VERIFICATION
-- Confirm the row counts in the final fact tables.
-- ============================================================

SELECT
    'fact_claims' AS table_name,
    COUNT(*) AS total_rows
FROM fact_claims

UNION ALL

SELECT
    'fact_premiums',
    COUNT(*)
FROM fact_premiums

UNION ALL

SELECT
    'fact_claim_lines',
    COUNT(*)
FROM fact_claim_lines;


