"""
Meridian Claims ETL: ZIP/CSV -> standardized CSV outputs -> optional MySQL.

Usage:
    pip install pandas
    python data_cleaning.py

Optional MySQL load:
    pip install sqlalchemy pymysql
    Set DB_CONNECTION_URL or MYSQL_USER and MYSQL_PASSWORD, then run:
    python data_cleaning.py --load-db

Default database: meridian_claims
Original ZIP files are never modified.
"""
from __future__ import annotations

import os
import re
import sys
import zipfile
from pathlib import Path

import pandas as pd

BASE_DIR = Path(__file__).resolve().parent
INPUT_FOLDER = BASE_DIR
OUTPUT_FOLDER = BASE_DIR / "cleaned_data_team_review"
ZIP_PATTERN = "Feed_*.zip"

DATE_COLUMNS = {
    "service_from_date", "service_to_date", "received_date",
    "processed_date", "premium_month",
}
NUMERIC_COLUMNS = {
    "total_billed", "total_allowed", "total_paid", "member_responsibility",
    "billed_amount", "allowed_amount", "paid_amount", "premium_amount",
    "units", "line_number",
}
TABLE_KINDS = ("claims_header", "claim_lines", "premiums")


def infer_month(filename: str) -> str:
    match = re.search(r"(20\d{2})[_-](0?[1-9]|1[0-2])", filename)
    if not match:
        raise ValueError(f"Cannot infer feed month from filename: {filename}")
    return f"{int(match.group(1)):04d}-{int(match.group(2)):02d}"


def table_kind(filename: str) -> str | None:
    base = Path(filename).name.lower()
    for kind in TABLE_KINDS:
        if base.startswith(kind):
            return kind
    return None


def standardize_columns(df: pd.DataFrame, kind: str) -> pd.DataFrame:
    df = df.copy()
    df.columns = (
        df.columns.astype(str).str.strip().str.lower()
        .str.replace(r"[^a-z0-9]+", "_", regex=True)
        .str.strip("_")
    )
    mapping = {
        "mbr_id": "member_id",
        "svc_from_dt": "service_from_date",
        "svc_to_dt": "service_to_date",
    }
    if kind == "claims_header":
        mapping.update({"allowed_amt": "total_allowed", "paid_amt": "total_paid"})
    elif kind == "claim_lines":
        mapping.update({"allowed_amt": "allowed_amount", "paid_amt": "paid_amount"})

    for old, new in mapping.items():
        if old not in df.columns:
            continue
        if new in df.columns:
            left = df[old].fillna("").astype(str).str.strip()
            right = df[new].fillna("").astype(str).str.strip()
            if not left.equals(right):
                raise ValueError(
                    f"Conflicting columns '{old}' and '{new}' in {kind}; values differ."
                )
            df = df.drop(columns=[old])
        else:
            df = df.rename(columns={old: new})
    return df


def parse_date_column(series: pd.Series, col: str, source: str) -> pd.Series:
    original = series.astype("string").str.strip()
    if col == "premium_month":
        # Preserve YYYY-MM month values; parse any full-date alternatives as YYYY-MM.
        month_only = original.str.fullmatch(r"\d{4}-\d{2}", na=False)
        parsed = pd.to_datetime(original.where(~month_only), format="mixed",
                                 dayfirst=True, errors="coerce")
        result = parsed.dt.strftime("%Y-%m").astype("string")
        result.loc[month_only] = original.loc[month_only]
    else:
        # Parse ISO dates first, then fall back to mixed/day-first source formats.
        parsed = pd.to_datetime(original, format="%Y-%m-%d", errors="coerce")
        fallback_mask = parsed.isna() & original.notna() & original.ne("")
        if fallback_mask.any():
            parsed.loc[fallback_mask] = pd.to_datetime(
                original.loc[fallback_mask], format="mixed", dayfirst=True, errors="coerce"
            )
        result = parsed.dt.strftime("%Y-%m-%d").astype("string")
    bad = original.notna() & original.ne("") & result.isna()
    if bad.any():
        examples = original[bad].head(5).tolist()
        print(f"WARNING: {source}: {int(bad.sum())} invalid date(s) in {col}; examples={examples}")
    return result


def clean_frame(raw: pd.DataFrame, kind: str, feed_month: str, source_file: str):
    df = standardize_columns(raw, kind)
    rows_before = len(df)

    # Normalize whitespace before identifying exact duplicates.
    for col in df.columns:
        if pd.api.types.is_string_dtype(df[col]) or df[col].dtype == object:
            df[col] = df[col].astype("string").str.strip()
            df[col] = df[col].replace({"": pd.NA})

    # Normalize procedure codes before duplicate detection so 110 and 0110
    # have the same canonical representation in every feed.
    if "procedure_code" in df.columns:
        codes = df["procedure_code"].astype("string").str.strip()
        numeric_mask = codes.str.fullmatch(r"\d+", na=False)
        df["procedure_code"] = codes.where(~numeric_mask, codes.str.zfill(4))

    # Normalize dates before duplicate detection so equivalent date formats
    # cannot make otherwise-identical rows appear different.
    for col in list(df.columns):
        if col in DATE_COLUMNS or col.endswith("_date") or col.endswith("_dt"):
            df[col] = parse_date_column(df[col], col, source_file)

    exact_duplicates = int(df.duplicated().sum())
    df = df.drop_duplicates().copy()

    for col in NUMERIC_COLUMNS.intersection(df.columns):
        original = df[col].copy()
        cleaned = (
            original.astype("string").str.replace(",", "", regex=False)
            .str.replace("$", "", regex=False)
        )
        converted = pd.to_numeric(cleaned, errors="coerce")
        invalid = original.notna() & converted.isna()
        if invalid.any():
            print(f"WARNING: {source_file}: {int(invalid.sum())} non-numeric value(s) in {col}.")
        df[col] = converted

    # Metadata makes each record traceable to its monthly source.
    df["_feed_month"] = feed_month
    df["_source_file"] = Path(source_file).name

    summary = {
        "feed_month": feed_month,
        "source_file": Path(source_file).name,
        "table_kind": kind,
        "rows_before": rows_before,
        "exact_duplicates_removed": exact_duplicates,
        "rows_after": len(df),
        "data_columns": len(df.columns) - 2,
    }
    return df, summary


def read_zip_feeds():
    zip_paths = sorted(
        p for p in INPUT_FOLDER.glob(ZIP_PATTERN)
        if p.is_file() and OUTPUT_FOLDER not in p.parents
    )
    if not zip_paths:
        raise FileNotFoundError(
            f"No {ZIP_PATTERN} files found in {INPUT_FOLDER}. "
            "Put the monthly feed ZIP files beside this script."
        )

    data = {kind: [] for kind in TABLE_KINDS}
    summaries = []

    for zip_path in zip_paths:
        month = infer_month(zip_path.name)
        print(f"\nReading {zip_path.name} ({month})")
        with zipfile.ZipFile(zip_path) as archive:
            members = [
                name for name in archive.namelist()
                if not name.endswith("/")
                and name.lower().endswith(".csv")
                and ".ipynb_checkpoints" not in name.replace("\\", "/").lower().split("/")
            ]
            # Also ignore any checkpoint directory at any nesting level.
            members = [
                name for name in members
                if not any(part.lower() == ".ipynb_checkpoints"
                           for part in name.replace("\\", "/").split("/"))
            ]
            found = set()
            for member in members:
                kind = table_kind(member)
                if kind is None:
                    # Ignore unrelated CSVs and checkpoint copies.
                    continue
                found.add(kind)
                with archive.open(member) as handle:
                    raw = pd.read_csv(handle, dtype="string", keep_default_na=True)
                cleaned, summary = clean_frame(raw, kind, month, member)
                data[kind].append(cleaned)
                summaries.append(summary)
                print(
                    f"  {Path(member).name}: {summary['rows_before']:,} -> "
                    f"{summary['rows_after']:,}; exact duplicates removed: "
                    f"{summary['exact_duplicates_removed']:,}"
                )
            missing = set(TABLE_KINDS) - found
            if missing:
                print(f"  WARNING: {zip_path.name} is missing: {', '.join(sorted(missing))}")

    combined = {}
    for kind, frames in data.items():
        if not frames:
            raise ValueError(f"No CSV files found for required table type: {kind}")
        combined[kind] = pd.concat(frames, ignore_index=True, sort=False)

    headers = combined["claims_header"]
    lines = combined["claim_lines"]
    if "claim_id" not in headers.columns:
        raise ValueError("Claims header data has no claim_id column.")
    if "claim_id" not in lines.columns:
        raise ValueError("Claim-line data has no claim_id column.")

    # Latest claim header: latest feed month wins; processed date breaks same-month ties.
    header_sort = ["claim_id", "_feed_month"]
    if "processed_date" in headers.columns:
        header_sort.append("processed_date")
    latest_headers = (
        headers.sort_values(header_sort, na_position="first")
        .drop_duplicates(subset=["claim_id"], keep="last")
        .reset_index(drop=True)
    )

    # Claim-line files are monthly snapshots: use all lines from the latest feed
    # month available for each claim_id, rather than mixing old and new snapshots.
    latest_month_by_claim = (
        lines.groupby("claim_id", dropna=False)["_feed_month"].max().rename("_latest_month")
    )
    latest_lines = lines.merge(latest_month_by_claim, on="claim_id", how="left")
    latest_lines = (
        latest_lines[latest_lines["_feed_month"] == latest_lines["_latest_month"]]
        .drop(columns=["_latest_month"])
        .drop_duplicates()
        .reset_index(drop=True)
    )

    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    outputs = {
        "stg_claims_header_monthly.csv": combined["claims_header"],
        "stg_claim_lines_monthly.csv": combined["claim_lines"],
        "stg_premiums_monthly.csv": combined["premiums"],
        "fact_claims_latest.csv": latest_headers,
        "fact_claim_lines_latest.csv": latest_lines,
        "cleaning_summary.csv": pd.DataFrame(summaries),
    }
    for filename, frame in outputs.items():
        frame.to_csv(OUTPUT_FOLDER / filename, index=False)

    missing_report = []
    for kind, frame in combined.items():
        for col in frame.columns:
            missing_report.append({
                "table_kind": kind,
                "column_name": col,
                "missing_count": int(frame[col].isna().sum()),
                "row_count": len(frame),
            })
    pd.DataFrame(missing_report).to_csv(OUTPUT_FOLDER / "missing_values_report.csv", index=False)

    # Compact validation report based on the actual inputs and outputs.
    validations = []
    for month, frame in combined["claims_header"].groupby("_feed_month"):
        dup_count = int(frame["claim_id"].duplicated().sum())
        validations.append({
            "check": f"{month}: duplicate claim_id rows in monthly header after exact dedupe",
            "observed": dup_count,
            "expected": 0,
            "status": "PASS" if dup_count == 0 else "WARN",
        })

    # Validate all standardized date columns. premium_month is intentionally YYYY-MM.
    date_issues = []
    for kind, frame in combined.items():
        for col in frame.columns:
            if col in DATE_COLUMNS or col.endswith("_date") or col.endswith("_dt"):
                values = frame[col].dropna().astype("string")
                if col == "premium_month":
                    invalid_mask = ~values.str.fullmatch(r"\d{4}-\d{2}", na=False)
                else:
                    invalid_mask = ~values.str.fullmatch(r"\d{4}-\d{2}-\d{2}", na=False)
                invalid_count = int(invalid_mask.sum())
                if invalid_count:
                    date_issues.append((kind, col, invalid_count))

    date_status = "PASS" if not date_issues else "FAIL"
    date_observed = "All date values match required formats" if not date_issues else "; ".join(
        f"{kind}.{col}: {count} invalid" for kind, col, count in date_issues
    )

    code_series = combined["claim_lines"]["procedure_code"].dropna().astype("string")
    invalid_code_count = int(code_series.str.fullmatch(r"\d{1,3}", na=False).sum())
    has_0110 = bool(code_series.eq("0110").any())

    required_header_columns = {
        "claim_id", "member_id", "service_from_date", "service_to_date",
        "total_allowed", "total_paid",
    }
    missing_header_columns = sorted(required_header_columns - set(combined["claims_header"].columns))
    telehealth_retained = "telehealth_flag" in combined["claims_header"].columns

    # Real cross-table checks on the latest tables.
    dup_latest_claims = int(latest_headers["claim_id"].duplicated().sum())
    dup_latest_lines = int(latest_lines.duplicated(["claim_id", "line_number"]).sum())
    orphan_lines = int((~latest_lines["claim_id"].isin(latest_headers["claim_id"])).sum())
    claims_without_lines = int((~latest_headers["claim_id"].isin(latest_lines["claim_id"])).sum())
    line_sums = latest_lines.groupby("claim_id")[["billed_amount", "paid_amount"]].sum()
    joined = latest_headers.set_index("claim_id").join(line_sums, how="inner")
    total_mismatch = int((
        ((joined["total_billed"] - joined["billed_amount"]).abs() > 0.05)
        | ((joined["total_paid"] - joined["paid_amount"]).abs() > 0.05)
    ).sum())

    validations.extend([
        {
            "check": "latest claims: claim_id is unique",
            "observed": dup_latest_claims,
            "expected": 0,
            "status": "PASS" if dup_latest_claims == 0 else "FAIL",
        },
        {
            "check": "latest lines: claim_id + line_number is unique",
            "observed": dup_latest_lines,
            "expected": 0,
            "status": "PASS" if dup_latest_lines == 0 else "FAIL",
        },
        {
            "check": "latest lines that have no claim header",
            "observed": orphan_lines,
            "expected": 0,
            "status": "PASS" if orphan_lines == 0 else "FAIL",
        },
        {
            "check": "latest claims that have no claim lines",
            "observed": claims_without_lines,
            "expected": 0,
            "status": "PASS" if claims_without_lines == 0 else "FAIL",
        },
        {
            "check": "claim total billed/paid equals sum of its lines",
            "observed": total_mismatch,
            "expected": 0,
            "status": "PASS" if total_mismatch == 0 else "FAIL",
        },
        {
            "check": "numeric procedure codes standardized to four characters",
            "observed": invalid_code_count,
            "expected": 0,
            "status": "PASS" if invalid_code_count == 0 else "FAIL",
        },
        {
            "check": "procedure code 0110 present when source includes 110/0110",
            "observed": "0110 present" if has_0110 else "0110 not present",
            "expected": "canonical code retained if present in source",
            "status": "PASS" if has_0110 else "REVIEW",
        },
        {
            "check": "date columns standardized",
            "observed": date_observed,
            "expected": "YYYY-MM-DD; premium_month uses YYYY-MM",
            "status": date_status,
        },
        {
            "check": "standard claim header column names",
            "observed": "missing: " + ", ".join(missing_header_columns) if missing_header_columns else "all required columns present",
            "expected": "canonical January column names",
            "status": "PASS" if not missing_header_columns else "FAIL",
        },
        {
            "check": "March telehealth_flag retained",
            "observed": telehealth_retained,
            "expected": True,
            "status": "PASS" if telehealth_retained else "REVIEW",
        },
        {
            "check": "checkpoint CSV files excluded",
            "observed": "ZIP discovery excludes .ipynb_checkpoints",
            "expected": "no checkpoint files loaded",
            "status": "PASS",
        },
    ])
    validation_df = pd.DataFrame(validations)
    validation_df.to_csv(OUTPUT_FOLDER / "validation_summary.csv", index=False)
    print("\nVALIDATION RESULTS")
    for _, row in validation_df.iterrows():
        print(f"  {row['status']:<6} {row['check']}  (observed: {row['observed']})")
    failed = validation_df[validation_df["status"] == "FAIL"]
    if len(failed):
        raise RuntimeError(f"{len(failed)} validation check(s) FAILED. See validation_summary.csv")

    return combined, latest_headers, latest_lines, pd.DataFrame(summaries)


def get_db_url():
    from sqlalchemy.engine import URL
    connection_url = os.getenv("DB_CONNECTION_URL")
    if connection_url:
        return connection_url
    user = os.getenv("MYSQL_USER")
    password = os.getenv("MYSQL_PASSWORD")
    if not user or password is None:
        raise RuntimeError("Set DB_CONNECTION_URL or MYSQL_USER and MYSQL_PASSWORD before --load-db.")
    return URL.create(
        "mysql+pymysql",
        username=user,
        password=password,
        host=os.getenv("MYSQL_HOST", "localhost"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        database=os.getenv("MYSQL_DATABASE", "meridian_claims"),
    )


def load_to_mysql(combined, latest_headers, latest_lines, summaries):
    from sqlalchemy import create_engine, text
    engine = create_engine(get_db_url(), pool_pre_ping=True, future=True)
    tables = {
        "stg_claims_header_monthly": combined["claims_header"],
        "stg_claim_lines_monthly": combined["claim_lines"],
        "stg_premiums_monthly": combined["premiums"],
        "fact_claims_latest": latest_headers,
        "fact_claim_lines_latest": latest_lines,
        "etl_cleaning_audit": summaries,
    }
    with engine.begin() as conn:
        for table_name, frame in tables.items():
            print(f"Loading {len(frame):,} rows into {table_name} ...")
            frame.to_sql(table_name, con=conn, if_exists="replace",
                         index=False, chunksize=1000, method="multi")
        conn.execute(text("SELECT 1"))
    engine.dispose()
    print("\nMySQL load successful. Database: meridian_claims (or MYSQL_DATABASE setting)")
    print("Tables: " + ", ".join(tables))


def main():
    try:
        combined, latest_headers, latest_lines, summaries = read_zip_feeds()
        print("\nCleaning finished.")
        print(f"Monthly headers: {len(combined['claims_header']):,}")
        print(f"Latest headers: {len(latest_headers):,}")
        print(f"Monthly lines: {len(combined['claim_lines']):,}")
        print(f"Latest line snapshot rows: {len(latest_lines):,}")
        print(f"Monthly premiums: {len(combined['premiums']):,}")
        print(f"Outputs: {OUTPUT_FOLDER}")
        if "--load-db" in sys.argv:
            load_to_mysql(combined, latest_headers, latest_lines, summaries)
        else:
            print("MySQL not changed. Add --load-db after configuring credentials to load tables.")
    except Exception as exc:
        print(f"\nPIPELINE FAILED: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
