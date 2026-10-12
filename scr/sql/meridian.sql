CREATE DATABASE IF NOT EXISTS meridian_claims;

USE meridian_claims;

SELECT DATABASE();

-- Meridian Health Plans - Claims Analytics
-- Database design: RAW -> CLEAN/STAGING -> STAR SCHEMA -> REPORTING
-- Target: MySQL 8.0+
-- IMPORTANT:
-- 1) Run this script in MySQL Workbench.
-- 2) This script creates database objects; it does not import CSV files by itself.
-- 3) Your Python ETL pipeline should load original CSV rows into raw_* tables,
--    clean/standardize them into clean_* tables, then load the star schema.
-- 4) Review source column names and business rules before enabling any INSERT section.
-- 5) Do not run DROP DATABASE on a database containing work you need to keep.

CREATE DATABASE IF NOT EXISTS meridian_claims
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE meridian_claims;

-- ============================================================
-- 1. ETL BATCH / AUDIT CONTROL
-- ============================================================
CREATE TABLE IF NOT EXISTS etl_batch (
    batch_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    feed_type ENUM('claims_header','claim_lines','premiums') NOT NULL,
    started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at DATETIME NULL,
    status ENUM('STARTED','SUCCESS','FAILED') NOT NULL DEFAULT 'STARTED',
    rows_read BIGINT NOT NULL DEFAULT 0,
    rows_loaded BIGINT NOT NULL DEFAULT 0,
    rows_rejected BIGINT NOT NULL DEFAULT 0,
    error_message TEXT NULL,
    UNIQUE KEY uq_batch_file (feed_month, source_file, feed_type)
);

CREATE TABLE IF NOT EXISTS etl_cleaning_audit (
    audit_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    check_name VARCHAR(100) NOT NULL,
    rows_checked BIGINT NOT NULL DEFAULT 0,
    rows_flagged BIGINT NOT NULL DEFAULT 0,
    notes VARCHAR(1000) NULL,
    audited_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id)
);

-- ============================================================
-- 2. RAW LAYER
-- Keep the source record as JSON so source columns can change month-to-month.
-- The Python pipeline should insert one JSON object per CSV row.
-- ============================================================
CREATE TABLE IF NOT EXISTS raw_claims_header (
    raw_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    source_row_number BIGINT NULL,
    loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    raw_record JSON NOT NULL,
    CONSTRAINT fk_raw_header_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_raw_header_month (feed_month),
    KEY ix_raw_header_file (source_file)
);

CREATE TABLE IF NOT EXISTS raw_claim_lines (
    raw_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    source_row_number BIGINT NULL,
    loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    raw_record JSON NOT NULL,
    CONSTRAINT fk_raw_lines_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_raw_lines_month (feed_month),
    KEY ix_raw_lines_file (source_file)
);

CREATE TABLE IF NOT EXISTS raw_premiums (
    raw_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    source_row_number BIGINT NULL,
    loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    raw_record JSON NOT NULL,
    CONSTRAINT fk_raw_premiums_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_raw_premiums_month (feed_month),
    KEY ix_raw_premiums_file (source_file)
);

-- ============================================================
-- 3. CLEAN LAYER
-- Typed, standardized records. Source-specific mappings belong in Python.
-- No primary key is imposed on claim_id in clean_claims_header because
-- the same claim may appear in multiple monthly feeds or have adjustments.
-- ============================================================
CREATE TABLE IF NOT EXISTS clean_claims_header (
    clean_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    claim_id VARCHAR(100) NULL,
    member_id VARCHAR(100) NULL,
    provider_id VARCHAR(100) NULL,
    claim_status VARCHAR(50) NULL,
    service_from_date DATE NULL,
    service_to_date DATE NULL,
    received_date DATE NULL,
    processed_date DATE NULL,
    total_billed DECIMAL(14,2) NULL,
    total_allowed DECIMAL(14,2) NULL,
    total_paid DECIMAL(14,2) NULL,
    denial_code VARCHAR(50) NULL,
    original_claim_id VARCHAR(100) NULL,
    record_hash CHAR(64) NULL,
    is_valid TINYINT(1) NOT NULL DEFAULT 1,
    validation_notes VARCHAR(1000) NULL,
    cleaned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_clean_header_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_clean_header_claim (claim_id),
    KEY ix_clean_header_member (member_id),
    KEY ix_clean_header_provider (provider_id),
    KEY ix_clean_header_month (feed_month),
    KEY ix_clean_header_hash (record_hash)
);

CREATE TABLE IF NOT EXISTS clean_claim_lines (
    clean_line_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    claim_id VARCHAR(100) NULL,
    line_number BIGINT NULL,
    procedure_code VARCHAR(30) NULL,
    modifier VARCHAR(30) NULL,
    units DECIMAL(12,2) NULL,
    billed_amount DECIMAL(14,2) NULL,
    allowed_amount DECIMAL(14,2) NULL,
    paid_amount DECIMAL(14,2) NULL,
    line_status VARCHAR(50) NULL,
    record_hash CHAR(64) NULL,
    is_valid TINYINT(1) NOT NULL DEFAULT 1,
    validation_notes VARCHAR(1000) NULL,
    cleaned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_clean_lines_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_clean_lines_claim (claim_id),
    KEY ix_clean_lines_month (feed_month),
    KEY ix_clean_lines_hash (record_hash)
);

CREATE TABLE IF NOT EXISTS clean_premiums (
    clean_premium_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    member_id VARCHAR(100) NULL,
    premium_month CHAR(7) NULL,
    plan_id VARCHAR(100) NULL,
    premium_amount DECIMAL(14,2) NULL,
    payment_status VARCHAR(50) NULL,
    record_hash CHAR(64) NULL,
    is_valid TINYINT(1) NOT NULL DEFAULT 1,
    validation_notes VARCHAR(1000) NULL,
    cleaned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_clean_premiums_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_clean_premiums_member (member_id),
    KEY ix_clean_premiums_month (premium_month),
    KEY ix_clean_premiums_hash (record_hash)
);

-- Optional quarantine table for records that fail validation.
CREATE TABLE IF NOT EXISTS etl_rejects (
    reject_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id BIGINT NULL,
    feed_month CHAR(7) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    source_row_number BIGINT NULL,
    reject_reason VARCHAR(1000) NOT NULL,
    rejected_record JSON NULL,
    rejected_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_reject_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    KEY ix_rejects_month (feed_month)
);

-- ============================================================
-- 4. STAR SCHEMA: DIMENSIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS dim_member (
    member_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    member_id VARCHAR(100) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_member_id (member_id)
);

CREATE TABLE IF NOT EXISTS dim_provider (
    provider_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    provider_id VARCHAR(100) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_provider_id (provider_id)
);

CREATE TABLE IF NOT EXISTS dim_claim_status (
    status_key INT AUTO_INCREMENT PRIMARY KEY,
    claim_status VARCHAR(50) NOT NULL,
    UNIQUE KEY uq_dim_claim_status (claim_status)
);

CREATE TABLE IF NOT EXISTS dim_plan (
    plan_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    plan_id VARCHAR(100) NOT NULL,
    UNIQUE KEY uq_dim_plan_id (plan_id)
);

CREATE TABLE IF NOT EXISTS dim_date (
    date_key INT PRIMARY KEY, -- YYYYMMDD; use 0 for unknown only if deliberately seeded
    full_date DATE NOT NULL,
    year_num SMALLINT NOT NULL,
    quarter_num TINYINT NOT NULL,
    month_num TINYINT NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    UNIQUE KEY uq_dim_date_full_date (full_date)
);

-- Seed date dimension for 2020-2035. Re-running does not overwrite existing dates.
-- MySQL's default recursive CTE limit is 1000; raise it for this date range.
SET SESSION cte_max_recursion_depth = 10000;
INSERT IGNORE INTO dim_date
    (date_key, full_date, year_num, quarter_num, month_num, month_name)
WITH RECURSIVE dates AS (
    SELECT DATE('2020-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM dates
    WHERE dt < '2035-12-31'
)
SELECT
    YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt),
    dt,
    YEAR(dt),
    QUARTER(dt),
    MONTH(dt),
    MONTHNAME(dt)
FROM dates;

-- ============================================================
-- 5. STAR SCHEMA: FACT TABLES
-- Fact grain:
-- fact_claims = one selected/current claim record per claim_id.
-- fact_claim_lines = one selected/current line per claim_id + line_number.
-- fact_premiums = one record per member + premium month + plan.
-- ============================================================
CREATE TABLE IF NOT EXISTS fact_claims (
    claim_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    claim_id VARCHAR(100) NOT NULL,
    member_key BIGINT NULL,
    provider_key BIGINT NULL,
    status_key INT NULL,
    service_from_date_key INT NULL,
    service_to_date_key INT NULL,
    received_date_key INT NULL,
    processed_date_key INT NULL,
    source_feed_month CHAR(7) NULL,
    total_billed DECIMAL(14,2) NULL,
    total_allowed DECIMAL(14,2) NULL,
    total_paid DECIMAL(14,2) NULL,
    denial_code VARCHAR(50) NULL,
    original_claim_id VARCHAR(100) NULL,
    last_updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_fact_claims_claim_id (claim_id),
    KEY ix_fact_claims_member (member_key),
    KEY ix_fact_claims_provider (provider_key),
    KEY ix_fact_claims_status (status_key),
    KEY ix_fact_claims_feed_month (source_feed_month),
    CONSTRAINT fk_fact_claim_member FOREIGN KEY (member_key) REFERENCES dim_member(member_key),
    CONSTRAINT fk_fact_claim_provider FOREIGN KEY (provider_key) REFERENCES dim_provider(provider_key),
    CONSTRAINT fk_fact_claim_status FOREIGN KEY (status_key) REFERENCES dim_claim_status(status_key),
    CONSTRAINT fk_fact_claim_service_from FOREIGN KEY (service_from_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_claim_service_to FOREIGN KEY (service_to_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_claim_received FOREIGN KEY (received_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_claim_processed FOREIGN KEY (processed_date_key) REFERENCES dim_date(date_key)
);

CREATE TABLE IF NOT EXISTS fact_claim_lines (
    claim_line_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    claim_id VARCHAR(100) NOT NULL,
    line_number BIGINT NOT NULL,
    procedure_code VARCHAR(30) NULL,
    modifier VARCHAR(30) NULL,
    units DECIMAL(12,2) NULL,
    billed_amount DECIMAL(14,2) NULL,
    allowed_amount DECIMAL(14,2) NULL,
    paid_amount DECIMAL(14,2) NULL,
    line_status VARCHAR(50) NULL,
    source_feed_month CHAR(7) NULL,
    record_hash CHAR(64) NULL,
    UNIQUE KEY uq_fact_claim_line (claim_id, line_number),
    KEY ix_fact_lines_feed_month (source_feed_month),
    CONSTRAINT fk_fact_line_claim FOREIGN KEY (claim_id) REFERENCES fact_claims(claim_id)
);

CREATE TABLE IF NOT EXISTS fact_premiums (
    premium_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    member_key BIGINT NOT NULL,
    plan_key BIGINT NULL,
    premium_month CHAR(7) NOT NULL,
    premium_amount DECIMAL(14,2) NULL,
    payment_status VARCHAR(50) NULL,
    source_feed_month CHAR(7) NULL,
    UNIQUE KEY uq_fact_premium (member_key, premium_month, plan_key),
    KEY ix_fact_premium_month (premium_month),
    CONSTRAINT fk_fact_premium_member FOREIGN KEY (member_key) REFERENCES dim_member(member_key),
    CONSTRAINT fk_fact_premium_plan FOREIGN KEY (plan_key) REFERENCES dim_plan(plan_key)
);

-- ============================================================
-- 6. REPORTING VIEWS
-- Views expose a simple reporting layer for Power BI / SQL analysis.
-- ============================================================
CREATE OR REPLACE VIEW vw_claims_reporting AS
SELECT
    f.claim_id,
    m.member_id,
    p.provider_id,
    s.claim_status,
    d1.full_date AS service_from_date,
    d2.full_date AS service_to_date,
    d3.full_date AS received_date,
    d4.full_date AS processed_date,
    f.source_feed_month,
    f.total_billed,
    f.total_allowed,
    f.total_paid,
    f.denial_code,
    f.original_claim_id
FROM fact_claims f
LEFT JOIN dim_member m ON f.member_key = m.member_key
LEFT JOIN dim_provider p ON f.provider_key = p.provider_key
LEFT JOIN dim_claim_status s ON f.status_key = s.status_key
LEFT JOIN dim_date d1 ON f.service_from_date_key = d1.date_key
LEFT JOIN dim_date d2 ON f.service_to_date_key = d2.date_key
LEFT JOIN dim_date d3 ON f.received_date_key = d3.date_key
LEFT JOIN dim_date d4 ON f.processed_date_key = d4.date_key;

CREATE OR REPLACE VIEW vw_claim_lines_reporting AS
SELECT
    l.claim_id,
    l.line_number,
    l.procedure_code,
    l.modifier,
    l.units,
    l.billed_amount,
    l.allowed_amount,
    l.paid_amount,
    l.line_status,
    l.source_feed_month
FROM fact_claim_lines l;

CREATE OR REPLACE VIEW vw_premiums_reporting AS
SELECT
    m.member_id,
    p.plan_id,
    f.premium_month,
    f.premium_amount,
    f.payment_status,
    f.source_feed_month
FROM fact_premiums f
JOIN dim_member m ON f.member_key = m.member_key
LEFT JOIN dim_plan p ON f.plan_key = p.plan_key;

CREATE OR REPLACE VIEW vw_monthly_claims_summary AS
SELECT
    source_feed_month,
    COUNT(*) AS claim_count,
    SUM(COALESCE(total_billed, 0)) AS billed_amount,
    SUM(COALESCE(total_allowed, 0)) AS allowed_amount,
    SUM(COALESCE(total_paid, 0)) AS paid_amount,
    SUM(CASE WHEN LOWER(COALESCE(claim_status, '')) LIKE '%denied%' THEN 1 ELSE 0 END) AS denied_claim_count
FROM vw_claims_reporting
GROUP BY source_feed_month;

CREATE OR REPLACE VIEW vw_monthly_premium_summary AS
SELECT
    premium_month,
    COUNT(*) AS premium_record_count,
    COUNT(DISTINCT member_id) AS member_count,
    SUM(COALESCE(premium_amount, 0)) AS premium_amount,
    SUM(CASE WHEN LOWER(COALESCE(payment_status, '')) IN ('paid','complete','completed','success') THEN COALESCE(premium_amount,0) ELSE 0 END) AS collected_premium_amount
FROM vw_premiums_reporting
GROUP BY premium_month;

-- ============================================================
-- 7. DATA QUALITY CHECKS
-- Run after the Python pipeline has loaded data.
-- ============================================================

-- Object inventory
SHOW TABLES;

-- Raw / clean / fact row counts
SELECT 'raw_claims_header' AS object_name, COUNT(*) AS total_rows FROM raw_claims_header
UNION ALL SELECT 'raw_claim_lines', COUNT(*) FROM raw_claim_lines
UNION ALL SELECT 'raw_premiums', COUNT(*) FROM raw_premiums
UNION ALL SELECT 'clean_claims_header', COUNT(*) FROM clean_claims_header
UNION ALL SELECT 'clean_claim_lines', COUNT(*) FROM clean_claim_lines
UNION ALL SELECT 'clean_premiums', COUNT(*) FROM clean_premiums
UNION ALL SELECT 'fact_claims', COUNT(*) FROM fact_claims
UNION ALL SELECT 'fact_claim_lines', COUNT(*) FROM fact_claim_lines
UNION ALL SELECT 'fact_premiums', COUNT(*) FROM fact_premiums
UNION ALL SELECT 'etl_cleaning_audit', COUNT(*) FROM etl_cleaning_audit;

-- Duplicate claim IDs in clean layer: investigate before selecting a current record.
SELECT claim_id, COUNT(*) AS occurrences
FROM clean_claims_header
WHERE claim_id IS NOT NULL AND TRIM(claim_id) <> ''
GROUP BY claim_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 100;

-- Missing required identifiers
SELECT 'claims_header' AS source_name, COUNT(*) AS flagged_rows
FROM clean_claims_header
WHERE claim_id IS NULL OR TRIM(claim_id) = ''
UNION ALL
SELECT 'claim_lines', COUNT(*)
FROM clean_claim_lines
WHERE claim_id IS NULL OR TRIM(claim_id) = '' OR line_number IS NULL
UNION ALL
SELECT 'premiums', COUNT(*)
FROM clean_premiums
WHERE member_id IS NULL OR TRIM(member_id) = ''
   OR premium_month IS NULL OR plan_id IS NULL;

-- Invalid amounts
SELECT 'claims_header_negative_amounts' AS check_name, COUNT(*) AS flagged_rows
FROM clean_claims_header
WHERE COALESCE(total_billed,0) < 0
   OR COALESCE(total_allowed,0) < 0
   OR COALESCE(total_paid,0) < 0
UNION ALL
SELECT 'claim_lines_negative_amounts', COUNT(*)
FROM clean_claim_lines
WHERE COALESCE(billed_amount,0) < 0
   OR COALESCE(allowed_amount,0) < 0
   OR COALESCE(paid_amount,0) < 0
UNION ALL
SELECT 'premiums_negative_amounts', COUNT(*)
FROM clean_premiums
WHERE COALESCE(premium_amount,0) < 0;

-- Fact-to-dimension relationship checks
SELECT
    COUNT(*) AS total_claims,
    SUM(member_key IS NULL) AS claims_without_member_dimension,
    SUM(provider_key IS NULL) AS claims_without_provider_dimension,
    SUM(status_key IS NULL) AS claims_without_status_dimension
FROM fact_claims;

-- Claim lines with no parent claim (should be prevented by foreign key)
SELECT COUNT(*) AS lines_without_parent_claim
FROM fact_claim_lines l
LEFT JOIN fact_claims c ON l.claim_id = c.claim_id
WHERE c.claim_id IS NULL;

-- Monthly reporting outputs
SELECT * FROM vw_monthly_claims_summary ORDER BY source_feed_month;
SELECT * FROM vw_monthly_premium_summary ORDER BY premium_month;

-- ============================================================
-- 8. MONTHLY LOAD CHECKLIST
-- For every new month, the Python ETL should:
--   A. Create/update one etl_batch row per incoming file.
--   B. Insert each untouched source row into the appropriate raw_* table.
--   C. Standardize column names and data types; record invalid rows in etl_rejects.
--   D. Insert standardized rows into clean_* with record_hash and validation notes.
--   E. Upsert new member/provider/status/plan dimension values.
--   F. Resolve duplicate/adjusted claims using an agreed business rule.
--   G. Load facts in order: fact_claims, fact_claim_lines, fact_premiums.
--   H. Update etl_batch status/counts and write results to etl_cleaning_audit.
--   I. Run the checks and reporting views above.
--
-- Do not use INSERT IGNORE to silently discard conflicting claims.
-- Decide and document the business rule for claim adjustments first.
-- ============================================================
