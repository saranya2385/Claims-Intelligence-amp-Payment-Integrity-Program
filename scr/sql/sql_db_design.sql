-- =====================================================
-- MERIDIAN CLAIMS ETL PROJECT
-- SECTION 1: DATABASE SETUP
-- Purpose: Create the database if it does not exist
-- =====================================================

CREATE DATABASE IF NOT EXISTS meridian_claims;

-- Select the project database
USE meridian_claims;

-- Display all tables in the database
SHOW TABLES;

-- =====================================================
-- SECTION 2: CREATE RAW TABLES
-- Purpose: Store the original monthly source data
-- =====================================================

USE meridian_claims;

-- 2.1 Raw claims header table
CREATE TABLE IF NOT EXISTS raw_claims_header_monthly (
    claim_id TEXT,
    member_id TEXT,
    provider_id TEXT,
    claim_type TEXT,
    place_of_service TEXT,
    service_from_date TEXT,
    service_to_date TEXT,
    received_date TEXT,
    processed_date TEXT,
    primary_diagnosis TEXT,
    secondary_diagnosis TEXT,
    total_billed TEXT,
    total_allowed TEXT,
    total_paid TEXT,
    member_responsibility TEXT,
    claim_status TEXT,
    denial_code TEXT,
    submission_channel TEXT,
    original_claim_id TEXT,
    _feed_month TEXT,
    _source_file TEXT,
    telehealth_flag TEXT
);

-- 2.2 Raw claims lines table
CREATE TABLE IF NOT EXISTS raw_claim_lines_monthly (
    claim_id TEXT,
    line_number TEXT,
    procedure_code TEXT,
    modifier TEXT,
    units TEXT,
    billed_amount TEXT,
    allowed_amount TEXT,
    paid_amount TEXT,
    line_status TEXT,
    _feed_month TEXT,
    _source_file TEXT
);

-- 2.3 Raw premiums table
CREATE TABLE IF NOT EXISTS raw_premiums_monthly (
    member_id TEXT,
    premium_month TEXT,
    plan_id TEXT,
    premium_amount TEXT,
    payment_status TEXT,
    _feed_month TEXT,
    _source_file TEXT
);

-- Verify that the raw tables exist
SHOW TABLES LIKE 'raw%';

-- Inspect the raw claims header structure
DESCRIBE raw_claims_header_monthly;

-- Inspect the raw claims lines structure
DESCRIBE raw_claim_lines_monthly;

-- Inspect the raw premiums structure
DESCRIBE raw_premiums_monthly;

-- =====================================================
-- SECTION 3: VERIFY RAW AND STAGING TABLES
-- Purpose: Confirm table existence and row counts
-- =====================================================

USE meridian_claims;

-- 3.1 Check whether raw tables exist
SHOW TABLES LIKE 'raw%';

-- 3.2 Count records in the raw tables
SELECT
    'raw_claims_header_monthly' AS table_name,
    COUNT(*) AS total_rows
FROM raw_claims_header_monthly

UNION ALL

SELECT
    'raw_claim_lines_monthly',
    COUNT(*)
FROM raw_claim_lines_monthly

UNION ALL

SELECT
    'raw_premiums_monthly',
    COUNT(*)
FROM raw_premiums_monthly;

-- 3.3 Inspect the staging table structures
DESCRIBE stg_claims_header_monthly;
DESCRIBE stg_claim_lines_monthly;
DESCRIBE stg_premiums_monthly;

-- 3.4 Count staging records
SELECT
    'stg_claims_header_monthly' AS table_name,
    COUNT(*) AS total_rows
FROM stg_claims_header_monthly

UNION ALL

SELECT
    'stg_claim_lines_monthly',
    COUNT(*)
FROM stg_claim_lines_monthly

UNION ALL

SELECT
    'stg_premiums_monthly',
    COUNT(*)
FROM stg_premiums_monthly;

-- 3.5 View sample staging records
SELECT *
FROM stg_claims_header_monthly
LIMIT 10;

SELECT *
FROM stg_claim_lines_monthly
LIMIT 10;

SELECT *
FROM stg_premiums_monthly
LIMIT 10;

-- =====================================================
-- SECTION 4: DATA QUALITY CHECKS
-- Purpose: Identify possible duplicate records
-- =====================================================

USE meridian_claims;

-- 4.1 Check repeated premium records
-- Business key: member_id + premium_month + plan_id

SELECT
    member_id,
    premium_month,
    plan_id,
    COUNT(*) AS duplicate_count
FROM stg_premiums_monthly
GROUP BY
    member_id,
    premium_month,
    plan_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

-- 4.2 Compare total header rows with distinct claim IDs

SELECT
    COUNT(*) AS total_claim_rows,
    COUNT(DISTINCT claim_id) AS unique_claims
FROM stg_claims_header_monthly;

-- 4.3 Find repeated claim IDs

SELECT
    claim_id,
    COUNT(*) AS record_count
FROM stg_claims_header_monthly
GROUP BY claim_id
HAVING COUNT(*) > 1
ORDER BY record_count DESC
LIMIT 10;

-- 4.4 Examine duplicate claims by feed month

SELECT
    claim_id,
    _feed_month,
    COUNT(*) AS record_count
FROM stg_claims_header_monthly
WHERE claim_id IN (
    'CLM1033930',
    'CLM1013201',
    'CLM1046736',
    'CLM1100862',
    'CLM1060254',
    'CLM1002252',
    'CLM1101183',
    'CLM1097381',
    'CLM1013945',
    'CLM1085586'
)
GROUP BY claim_id, _feed_month
ORDER BY claim_id, _feed_month;

-- =====================================================
-- SECTION 5: FACT TABLE VERIFICATION
-- Purpose: Check the cleaned/latest output tables
-- =====================================================

USE meridian_claims;

-- 5.1 Count the latest staging and fact outputs

SELECT
    'stg_claims_header_monthly' AS table_name,
    COUNT(*) AS total_rows
FROM stg_claims_header_monthly

UNION ALL

SELECT
    'stg_claim_lines_monthly',
    COUNT(*)
FROM stg_claim_lines_monthly

UNION ALL

SELECT
    'stg_premiums_monthly',
    COUNT(*)
FROM stg_premiums_monthly

UNION ALL

SELECT
    'fact_claims_latest',
    COUNT(*)
FROM fact_claims_latest

UNION ALL

SELECT
    'fact_claim_lines_latest',
    COUNT(*)
FROM fact_claim_lines_latest

UNION ALL

SELECT
    'etl_cleaning_audit',
    COUNT(*)
FROM etl_cleaning_audit;

-- 5.2 Check claim uniqueness in the latest output

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT claim_id) AS unique_claims
FROM fact_claims_latest;

-- 5.3 Inspect latest claim records

SELECT *
FROM fact_claims_latest
LIMIT 10;

-- 5.4 Inspect latest claim line records

SELECT *
FROM fact_claim_lines_latest
LIMIT 10;

-- =====================================================
-- SECTION 6: CREATE DIMENSION TABLES
-- Purpose: Prepare lookup tables for the data model
-- =====================================================

USE meridian_claims;

-- 6.1 Member dimension
CREATE TABLE IF NOT EXISTS dim_member (
    member_key INT AUTO_INCREMENT PRIMARY KEY,
    member_id VARCHAR(100) NOT NULL UNIQUE
);

-- 6.2 Provider dimension
CREATE TABLE IF NOT EXISTS dim_provider (
    provider_key INT AUTO_INCREMENT PRIMARY KEY,
    provider_id VARCHAR(100) NOT NULL UNIQUE
);

-- 6.3 Claim status dimension
CREATE TABLE IF NOT EXISTS dim_claim_status (
    status_key INT AUTO_INCREMENT PRIMARY KEY,
    claim_status VARCHAR(100) NOT NULL UNIQUE
);

-- 6.4 Plan dimension
CREATE TABLE IF NOT EXISTS dim_plan (
    plan_key INT AUTO_INCREMENT PRIMARY KEY,
    plan_id VARCHAR(100) NOT NULL UNIQUE
);

-- 6.5 Date dimension
CREATE TABLE IF NOT EXISTS dim_date (
    date_key INT PRIMARY KEY,
    full_date DATE NOT NULL UNIQUE,
    year_num INT NOT NULL,
    month_num INT NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    quarter_num INT NOT NULL
);

-- Verify the dimension tables
SHOW TABLES;

-- =====================================================
-- SECTION 7: POPULATE DIMENSIONS
-- Purpose: Insert unique reference values
-- INSERT IGNORE avoids inserting duplicate unique keys
-- =====================================================

USE meridian_claims;

-- 7.1 Populate members from claims
INSERT IGNORE INTO dim_member (member_id)
SELECT DISTINCT TRIM(member_id)
FROM stg_claims_header_monthly
WHERE member_id IS NOT NULL
  AND TRIM(member_id) <> '';

-- 7.2 Include members found only in premiums
INSERT IGNORE INTO dim_member (member_id)
SELECT DISTINCT TRIM(member_id)
FROM stg_premiums_monthly
WHERE member_id IS NOT NULL
  AND TRIM(member_id) <> '';

-- 7.3 Populate providers
INSERT IGNORE INTO dim_provider (provider_id)
SELECT DISTINCT TRIM(provider_id)
FROM stg_claims_header_monthly
WHERE provider_id IS NOT NULL
  AND TRIM(provider_id) <> '';

-- 7.4 Populate claim statuses
INSERT IGNORE INTO dim_claim_status (claim_status)
SELECT DISTINCT TRIM(claim_status)
FROM stg_claims_header_monthly
WHERE claim_status IS NOT NULL
  AND TRIM(claim_status) <> '';

-- 7.5 Populate plans
INSERT IGNORE INTO dim_plan (plan_id)
SELECT DISTINCT TRIM(plan_id)
FROM stg_premiums_monthly
WHERE plan_id IS NOT NULL
  AND TRIM(plan_id) <> '';

-- 7.6 Verify dimension record counts
SELECT
    'dim_member' AS table_name,
    COUNT(*) AS total_rows
FROM dim_member

UNION ALL

SELECT 'dim_provider', COUNT(*)
FROM dim_provider

UNION ALL

SELECT 'dim_claim_status', COUNT(*)
FROM dim_claim_status

UNION ALL

SELECT 'dim_plan', COUNT(*)
FROM dim_plan;

-- =====================================================
-- SECTION 8: POPULATE DATE DIMENSION
-- Purpose: Generate a calendar for date-based reporting
-- Date key format: YYYYMMDD
-- Requires MySQL 8.0+ for recursive CTE support
-- =====================================================

USE meridian_claims;

INSERT IGNORE INTO dim_date (
    date_key,
    full_date,
    year_num,
    month_num,
    month_name,
    quarter_num
)
WITH RECURSIVE calendar AS (
    -- Starting date
    SELECT DATE('2025-04-01') AS calendar_date

    UNION ALL

    -- Generate the next date until March 31, 2026
    SELECT DATE_ADD(calendar_date, INTERVAL 1 DAY)
    FROM calendar
    WHERE calendar_date < '2026-03-31'
)
SELECT
    YEAR(calendar_date) * 10000
        + MONTH(calendar_date) * 100
        + DAY(calendar_date) AS date_key,
    calendar_date AS full_date,
    YEAR(calendar_date) AS year_num,
    MONTH(calendar_date) AS month_num,
    MONTHNAME(calendar_date) AS month_name,
    QUARTER(calendar_date) AS quarter_num
FROM calendar;

-- Verify the date range
SELECT
    COUNT(*) AS total_dates,
    MIN(full_date) AS earliest_date,
    MAX(full_date) AS latest_date
FROM dim_date;

-- =====================================================
-- SECTION 9: FACT TABLE RELATIONSHIP VALIDATION
-- Purpose: Identify missing dimension matches
-- =====================================================

USE meridian_claims;

-- 9.1 Validate claims against dimensions

SELECT
    COUNT(*) AS total_claims,
    SUM(m.member_key IS NULL) AS missing_members,
    SUM(p.provider_key IS NULL) AS missing_providers,
    SUM(s.status_key IS NULL) AS missing_statuses,
    SUM(d1.date_key IS NULL) AS missing_service_from_dates,
    SUM(d2.date_key IS NULL) AS missing_service_to_dates,
    SUM(d3.date_key IS NULL) AS missing_received_dates,
    SUM(d4.date_key IS NULL) AS missing_processed_dates
FROM fact_claims AS f
LEFT JOIN dim_member AS m
    ON f.member_key = m.member_key
LEFT JOIN dim_provider AS p
    ON f.provider_key = p.provider_key
LEFT JOIN dim_claim_status AS s
    ON f.status_key = s.status_key
LEFT JOIN dim_date AS d1
    ON f.service_from_date_key = d1.date_key
LEFT JOIN dim_date AS d2
    ON f.service_to_date_key = d2.date_key
LEFT JOIN dim_date AS d3
    ON f.received_date_key = d3.date_key
LEFT JOIN dim_date AS d4
    ON f.processed_date_key = d4.date_key;

-- 9.2 Find claims with processed dates missing
-- from the date dimension

SELECT
    f.claim_id,
    f.processed_date_key
FROM fact_claims AS f
LEFT JOIN dim_date AS d
    ON f.processed_date_key = d.date_key
WHERE d.date_key IS NULL
LIMIT 20;

-- 9.3 Check null and non-null processed date keys

SELECT
    COUNT(*) AS total_claims,
    SUM(processed_date_key IS NULL) AS null_processed_dates,
    SUM(processed_date_key IS NOT NULL) AS claims_with_processed_dates
FROM fact_claims;

-- 9.4 Validate premiums against dimensions

SELECT
    COUNT(*) AS total_premiums,
    SUM(m.member_key IS NULL) AS missing_members,
    SUM(p.plan_key IS NULL) AS missing_plans,
    SUM(d.date_key IS NULL) AS missing_dates
FROM fact_premiums AS f
LEFT JOIN dim_member AS m
    ON f.member_key = m.member_key
LEFT JOIN dim_plan AS p
    ON f.plan_key = p.plan_key
LEFT JOIN dim_date AS d
    ON f.premium_date_key = d.date_key;

-- 9.5 Check that every claim line has a matching claim

SELECT
    COUNT(*) AS total_claim_lines,
    SUM(f.claim_id IS NULL) AS missing_claims
FROM fact_claim_lines AS fl
LEFT JOIN fact_claims AS f
    ON fl.claim_id = f.claim_id;

-- =====================================================
-- SECTION 10: FINAL DATABASE VERIFICATION
-- Purpose: Inspect tables, storage engines and constraints
-- =====================================================

USE meridian_claims;

-- 10.1 List all project tables
SHOW TABLES;

-- 10.2 Count records in the final fact tables
SELECT
    'fact_claims' AS table_name,
    COUNT(*) AS total_rows
FROM fact_claims

UNION ALL

SELECT
    'fact_claim_lines',
    COUNT(*)
FROM fact_claim_lines

UNION ALL

SELECT
    'fact_premiums',
    COUNT(*)
FROM fact_premiums;

-- 10.3 Inspect foreign key relationships
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    REFERENCED_TABLE_NAME,
    REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'meridian_claims'
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY TABLE_NAME, COLUMN_NAME;

-- 10.4 Check table storage engines
SELECT
    TABLE_NAME,
    ENGINE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'meridian_claims'
  AND TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;

-- 10.5 Inspect final fact table samples
SELECT *
FROM fact_claims
LIMIT 10;

SELECT *
FROM fact_claim_lines
LIMIT 10;

SELECT *
FROM fact_premiums
LIMIT 10;

select * from dim_member;
select * from dim_date;
