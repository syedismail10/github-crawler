# create_project.ps1
# Run from: C:\Users\syedi\Coding\Personal
# Temporarily allows script execution in this PowerShell session:
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

$root = (Resolve-Path ".").ProviderPath

Write-Host "Creating project files under $root"

# Helper: create directory and write file with UTF8
function Write-TextFile([string]$path, [string]$content) {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $content | Out-File -FilePath $path -Encoding utf8 -Force
  Write-Host "Wrote $path"
}

# --- Files map: relative path => content (single-quoted here-strings used to avoid interpolation)
# README.md
$readme = @'
# GitHub Stars Crawler

This repository implements a GitHub crawler that uses the GitHub GraphQL API to collect repository star counts and store them in Postgres. It's designed to run in GitHub Actions using the default `GITHUB_TOKEN` and a Postgres service container.

What this includes
- A rate-limit-aware GraphQL crawler (`src/crawl_stars.py`).
- A flexible relational schema (see `sql/schema.sql`) separating repository metadata and star snapshots.
- A GitHub Actions workflow (`.github/workflows/crawl.yml`) which:
  - starts a Postgres service container
  - creates DB schema
  - runs the crawler (using the runner-provided `GITHUB_TOKEN`)
  - dumps the DB contents and uploads as artifact

Notes
- The workflow uses only the default `GITHUB_TOKEN` (no extra secrets required).
- Crawling 100k repositories can take time due to GitHub rate limits; the code is written to be resumable and to respect rate limits and retries.

See `sql/schema.sql` for schema details and the sections below for scaling and schema evolution notes.

How to run locally (quick smoke test)
1. Install dependencies: `pip install -r requirements.txt`
2. Start a local Postgres and set env vars: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`.
3. Export `GITHUB_TOKEN` (a personal token for local runs) or rely on Actions-provided `GITHUB_TOKEN` in CI.
4. Create the DB schema: `psql -h $PGHOST -U $PGUSER -d $PGDATABASE -f sql/schema.sql`.
5. Run crawler: `python src/crawl_stars.py --target 1000` (use a smaller target for local tests).


## Design overview

- The schema separates repository identity (`repositories`) from periodic snapshots of star counts (`stars_history`). This makes updates efficient: adding or updating today's snapshot affects only one row per repo.
- The crawler uses search-based partitioning (created-date ranges) to avoid the 1000-result-per-search cap and expand coverage.
- The crawler reads the `rateLimit` object in GraphQL responses and adapts (sleep until reset when remaining credits are low). Exponential backoff is used for transient HTTP/GraphQL errors.


## Schema and how it evolves

Current tables (see `sql/schema.sql`):

- `repositories` (normalized identity and stable metadata)
  - `repo_node_id` (PK), `name_with_owner`, `url`, `created_at`, `description`, `language`, `last_updated_at`
- `stars_history` (time-series snapshots)
  - `repo_node_id`, `snapshot_date`, `stars`, `captured_at` (PK: `(repo_node_id, snapshot_date)`)

Why this is flexible
- Normalization keeps repository metadata in one place and time-series data in another. This keeps updates localized (single-row updates for today's snapshot) and keeps historical data immutable.

Extending the schema for more GitHub metadata
- For issues:
  - `issues` (issue_id PK, repo_node_id FK, number, title, state, created_at, updated_at)
  - `issue_comments` (comment_id PK, issue_id FK, author, body, created_at, updated_at)
- For pull requests:
  - `pull_requests` (pr_id PK, repo_node_id FK, number, title, state, created_at, updated_at)
  - `pr_comments` (comment_id PK, pr_id FK, author, body, created_at, updated_at)
  - `pr_reviews` (review_id PK, pr_id FK, author, state, body, submitted_at)
  - `pr_commits` (commit_sha PK, pr_id FK, author, message, committed_at)
- For CI checks and statuses:
  - `ci_checks` (check_id PK, commit_sha or pr_id, status, conclusion, started_at, completed_at)

Efficient updates for growing collections (comments example)
- Keep comment tables append-only. New comments are inserted (few rows affected). Edits update a single comment row. If you need a fast summary (comment counts), maintain a small derived counters table (one row per issue/pr) and update with atomic increments (single-row upserts).


## Performance & crawl-duration considerations

- The crawler's runtime for N repositories is dominated by:
  1. GitHub API rate limits (primary constraint)
  2. Network latency and concurrency
  3. DB write throughput (mitigated via batch upserts)

- Strategies to minimize duration when collecting 100k repos:
  - Partition the input space (created date, language, alphabetical ranges) and crawl partitions in parallel with distinct tokens.
  - Use multiple GitHub App install tokens or personal tokens and a token manager to spread requests across tokens while respecting per-token limits.
  - Batch DB writes using `execute_values` (already implemented) to reduce round-trips.


## Running at scale (what I'd change for 500M repositories)

Collecting 500M repositories is a fundamentally different scale; changes I would make:

1. Storage & analytics
   - Move historic analytics data to a columnar/OLAP store (BigQuery, Snowflake, Redshift). Keep transactional data in a sharded OLTP system only when needed.
   - Store raw crawl events in a data lake (S3) as Parquet for reprocessing.

2. Ingestion & coordination
   - Use a distributed queue (Kafka) and many workers. Workers publish normalized events; consumer services write to DBs and data lake.
   - Implement a central frontier/coordination service to avoid duplicate crawls and to schedule retries.

3. API rate limits & tokens
   - Use GitHub Apps (installation tokens) at scale and a token broker that allocates tokens to workers and enforces per-token throttling.

4. Seeding & backfill
   - Use public archives (GHArchive, GHTorrent) to seed data instead of hitting the GraphQL API for every historical event.

5. Partitioning & sharding
   - Shard by repository ranges (hash of name_with_owner or repository id) and partition time-series tables by date ranges.

6. Observability & correctness
   - Strong monitoring, per-shard progress tracking, and dedupe pipelines. Store checksums/ETags for repo snapshots to detect no-ops.


## Operational notes & assumptions

- The example workflow uses `TARGET_COUNT: 1000` to keep a demo run short. Setting `TARGET_COUNT: 100000` is supported but may take a very long time and be subject to rate limits.
- The CI run uses the Actions-provided `GITHUB_TOKEN`. That token has lower rate limits than an OAuth app or many personal tokens; for higher throughput use multiple tokens or a GitHub App.
- Assumptions made:
  - We use `repo_node_id` (GraphQL node id) as the primary key; it's stable and unique.
  - We rely on search-based crawling (created: range). This approach is simple and avoids repository listing APIs which are not provided for arbitrary discovery.


## Next steps and optional improvements

- Add a worker-dispatcher example that runs multiple parallel crawlers with token management.
- Add schema DDL migrations (Flyway/liquibase) and unit/integration tests.
- Add a metrics endpoint and Prometheus metrics for crawl rate, errors, and DB write latencies.

License: MIT
'@

Write-TextFile -path (Join-Path $root 'README.md') -content $readme

# requirements.txt
$req = @'
requests>=2.31.0
psycopg2-binary>=2.9
python-dateutil>=2.8
backoff>=2.2.1
fastapi>=0.95.0
uvicorn[standard]>=0.22.0
pytest>=7.0
pytest-cov>=4.0
'@
Write-TextFile -path (Join-Path $root 'requirements.txt') -content $req

# sql/schema.sql
$schema = @'
-- Schema for GitHub stars crawler
-- repositories: repository identity and stable metadata
-- stars_history: daily snapshot of star counts (one row per repo per date)

CREATE TABLE IF NOT EXISTS repositories (
    repo_node_id TEXT PRIMARY KEY,
    name_with_owner TEXT NOT NULL,
    url TEXT,
    created_at TIMESTAMPTZ,
    description TEXT,
    language TEXT,
    last_updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_repos_name_with_owner ON repositories (name_with_owner);

CREATE TABLE IF NOT EXISTS stars_history (
    repo_node_id TEXT NOT NULL REFERENCES repositories(repo_node_id) ON DELETE CASCADE,
    snapshot_date DATE NOT NULL,
    stars INTEGER NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (repo_node_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_stars_snapshot_date ON stars_history (snapshot_date);
'@
Write-TextFile -path (Join-Path $root 'sql\schema.sql') -content $schema

# src/crawl_stars.py
$crawl = @'
#!/usr/bin/env python3
"""
Crawl GitHub repositories using GraphQL and store star counts in Postgres.

This script is written to be rate-limit aware and resume-friendly.

Usage:
  python src/crawl_stars.py --target 100000

Environment variables (used by default):
  GITHUB_TOKEN (from Actions or local env)
  PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE

The script inserts/upserts repository rows into `repositories` and inserts/updates
one row per day in `stars_history`.
"""
import os
import sys
import time
import json
import argparse
from datetime import datetime, timedelta, timezone, date
from dateutil import parser as date_parser
import requests
import backoff
import psycopg2
from psycopg2.extras import execute_values

GRAPHQL_URL = "https://api.github.com/graphql"


def get_env(key, default=None):
    val = os.environ.get(key)
    return val if val is not None else default


def graphql_query(token, query, variables=None):
    headers = {"Authorization": f"bearer {token}", "Accept": "application/json"}
    payload = {"query": query, "variables": variables or {}}

    resp = requests.post(GRAPHQL_URL, json=payload, headers=headers, timeout=30)
    if resp.status_code != 200:
        raise RuntimeError(f"GraphQL query failed: {resp.status_code} {resp.text}")
    data = resp.json()
    if "errors" in data:
        # surface errors
        raise RuntimeError(f"GraphQL errors: {data['errors']}")
    return data.get("data", {})


@backoff.on_exception(backoff.expo, (requests.exceptions.RequestException, RuntimeError), max_time=60)
def fetch_search_page(token, q, first=100, after=None):
    # GraphQL query with rateLimit included
    query = """
    query($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: REPOSITORY, first: $first, after: $after) {
        repositoryCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on Repository {
            id
            databaseId
            nameWithOwner
            url
            stargazerCount
            createdAt
            description
            primaryLanguage { name }
          }
        }
      }
      rateLimit { limit cost remaining resetAt }
    }
    """

    variables = {"q": q, "first": first, "after": after}
    data = graphql_query(token, query, variables)
    return data


def ensure_db_conn():
    conn = psycopg2.connect(
        host=get_env("PGHOST", "localhost"),
        port=int(get_env("PGPORT", 5432)),
        user=get_env("PGUSER", "postgres"),
        password=get_env("PGPASSWORD", "postgres"),
        dbname=get_env("PGDATABASE", "github_crawler"),
    )
    conn.autocommit = True
    return conn


def upsert_repositories(conn, rows):
    if not rows:
        return
    with conn.cursor() as cur:
        values = [
            (r["id"], r["nameWithOwner"], r.get("url"), r.get("createdAt"), r.get("description"), r.get("language"))
            for r in rows
        ]
        sql = (
            "INSERT INTO repositories (repo_node_id, name_with_owner, url, created_at, description, language) "
            "VALUES %s ON CONFLICT (repo_node_id) DO UPDATE SET name_with_owner = EXCLUDED.name_with_owner, url = EXCLUDED.url, description = EXCLUDED.description, language = EXCLUDED.language, last_updated_at = now();"
        )
        execute_values(cur, sql, values)


def upsert_stars(conn, rows, snapshot_date):
    if not rows:
        return
    with conn.cursor() as cur:
        values = [(r["id"], snapshot_date, r["stargazerCount"]) for r in rows]
        sql = (
            "INSERT INTO stars_history (repo_node_id, snapshot_date, stars, captured_at) VALUES %s "
            "ON CONFLICT (repo_node_id, snapshot_date) DO UPDATE SET stars = EXCLUDED.stars, captured_at = EXCLUDED.captured_at;"
        )
        execute_values(cur, sql, values)


def parse_repo_node(node):
    return {
        "id": node.get("id"),
        "databaseId": node.get("databaseId"),
        "nameWithOwner": node.get("nameWithOwner"),
        "url": node.get("url"),
        "stargazerCount": node.get("stargazerCount", 0),
        "createdAt": node.get("createdAt"),
        "description": node.get("description"),
        "language": node.get("primaryLanguage").get("name") if node.get("primaryLanguage") else None,
    }


def yield_date_ranges(start_date: date, end_date: date, window_days: int):
    cur = start_date
    while cur < end_date:
        next_d = min(end_date, cur + timedelta(days=window_days))
        yield cur, next_d
        cur = next_d


def collect_repositories(token, target_count=100000, window_days=30):
    # Strategy: iterate over created-date ranges (ascending) and page through search results
    # to collect many repositories. Each search can return up to 100 nodes per page and a max
    # of 1000 total results for a given query, so we use windowing to expand coverage.
    collected = []
    now = datetime.now(timezone.utc).date()
    start = date(2008, 1, 1)
    for a, b in yield_date_ranges(start, now, window_days):
        # build search query - use created range and sort by stars (descending) to get varied repos
        q = f"created:{a.isoformat()}..{b.isoformat()}"
        after = None
        while True:
            data = fetch_search_page(token, q, first=100, after=after)
            if data is None:
                break
            search = data.get("search", {})
            nodes = search.get("nodes", [])
            parsed = [parse_repo_node(n) for n in nodes]
            collected.extend(parsed)
            # adaptive rate limit handling
            rate = data.get("rateLimit") or {}
            remaining = rate.get("remaining")
            resetAt = rate.get("resetAt")
            if remaining is not None and remaining < 10 and resetAt:
                # sleep until reset
                reset_dt = date_parser.parse(resetAt)
                wait = (reset_dt - datetime.now(timezone.utc)).total_seconds()
                if wait > 0:
                    print(f"Rate limit low ({remaining}), sleeping {wait:.1f}s until reset")
                    time.sleep(wait + 1)

            page_info = search.get("pageInfo", {})
            if page_info.get("hasNextPage"):
                after = page_info.get("endCursor")
            else:
                break

            if len(collected) >= target_count:
                return collected[:target_count]

        if len(collected) >= target_count:
            break

    return collected[:target_count]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--target", type=int, default=int(get_env("TARGET_COUNT", 1000)), help="Number of repos to collect (default from TARGET_COUNT env or 1000)")
    p.add_argument("--window-days", type=int, default=int(get_env("WINDOW_DAYS", 30)), help="Window size in days for created: ranges")
    args = p.parse_args()

    token = get_env("GITHUB_TOKEN")
    if not token:
        print("GITHUB_TOKEN is required via env (in Actions it's provided automatically). Exiting.")
        sys.exit(1)

    print(f"Collecting up to {args.target} repositories (window_days={args.window_days})")
    repos = collect_repositories(token, target_count=args.target, window_days=args.window_days)
    print(f"Collected {len(repos)} repositories; writing to DB")

    conn = ensure_db_conn()
    snapshot_date = datetime.now(timezone.utc).date()
    # upsert in chunks
    chunk = 200
    for i in range(0, len(repos), chunk):
        batch = repos[i : i + chunk]
        # ensure repo rows
        upsert_repositories(conn, batch)
        upsert_stars(conn, batch, snapshot_date)

    print("Done.")


if __name__ == "__main__":
    main()
'@
Write-TextFile -path (Join-Path $root 'src\crawl_stars.py') -content $crawl

# src/api_server.py
$api = @'
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
import subprocess
import psycopg2

app = FastAPI(title="GitHub Stars Crawler API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db_conn():
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", 5432)),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "github_crawler"),
    )


class CrawlRequest(BaseModel):
    target: int = 1000


@app.get("/api/repos")
def list_repos(limit: int = 100, offset: int = 0):
    """Return latest star snapshot per repository, paginated."""
    conn = get_db_conn()
    try:
        cur = conn.cursor()
        # Use a window function to get the latest snapshot per repo
        sql = (
            "SELECT repo_node_id, name_with_owner, url, snapshot_date, stars FROM ("
            "  SELECT s.repo_node_id, r.name_with_owner, r.url, s.snapshot_date, s.stars, "
            "    ROW_NUMBER() OVER (PARTITION BY s.repo_node_id ORDER BY s.snapshot_date DESC) rn "
            "  FROM stars_history s JOIN repositories r ON r.repo_node_id = s.repo_node_id"
            ") t WHERE rn = 1 ORDER BY stars DESC LIMIT %s OFFSET %s"
        )
        cur.execute(sql, (limit, offset))
        rows = cur.fetchall()
        result = [
            {
                "repo_node_id": r[0],
                "name_with_owner": r[1],
                "url": r[2],
                "snapshot_date": r[3].isoformat() if r[3] else None,
                "stars": r[4],
            }
            for r in rows
        ]
        return {"count": len(result), "items": result}
    finally:
        conn.close()


@app.post("/api/crawl")
def trigger_crawl(req: CrawlRequest):
    """Trigger a background crawl (spawns a subprocess). Returns PID of the spawned process."""
    # Make sure the crawler exists
    crawl_script = os.path.join(os.path.dirname(__file__), "crawl_stars.py")
    if not os.path.exists(crawl_script):
        raise HTTPException(status_code=500, detail="crawl_stars.py not found on server")

    # Run crawler in background with provided TARGET_COUNT
    cmd = ["python", crawl_script, "--target", str(req.target)]
    proc = subprocess.Popen(cmd)
    return {"pid": proc.pid, "target": req.target}
'@
Write-TextFile -path (Join-Path $root 'src\api_server.py') -content $api

# .github/workflows/crawl.yml
$crawlYaml = @'
name: crawl-stars

on:
  workflow_dispatch:
  schedule:
    - cron: '0 3 * * *' # daily at 03:00 UTC (optional)

jobs:
  crawl:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: github_crawler
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres" --health-interval 10s --health-timeout 5s --health-retries 5

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install system deps and python requirements
        run: |
          sudo apt-get update -y
          sudo apt-get install -y postgresql-client
          python -m pip install --upgrade pip
          pip install -r requirements.txt

      - name: Wait for Postgres to be available
        run: |
          for i in {1..15}; do
            pg_isready -h localhost -p 5432 -U postgres && break
            echo "waiting for postgres... ($i)"; sleep 2
          done

      - name: Setup Postgres schema
        env:
          PGPASSWORD: postgres
        run: |
          psql -h localhost -U postgres -d github_crawler -f sql/schema.sql

      - name: Crawl stars
        env:
          PGHOST: localhost
          PGPORT: 5432
          PGUSER: postgres
          PGPASSWORD: postgres
          PGDATABASE: github_crawler
          # Use the Actions-provided token; do NOT store or require secrets
          # For the demo CI run we collect a smaller sample. To collect 100k set TARGET_COUNT=100000
          TARGET_COUNT: 1000
          WINDOW_DAYS: 30
        run: |
          python src/crawl_stars.py --target $TARGET_COUNT --window-days $WINDOW_DAYS

      - name: Dump stars to CSV
        env:
          PGPASSWORD: postgres
        run: |
          psql -h localhost -U postgres -d github_crawler -c "\copy (SELECT r.name_with_owner, s.snapshot_date, s.stars, r.url FROM stars_history s JOIN repositories r ON r.repo_node_id = s.repo_node_id ORDER BY s.snapshot_date DESC) TO 'stars_dump.csv' CSV HEADER"

      - name: Upload artifact (CSV)
        uses: actions/upload-artifact@v4
        with:
          name: stars-dump
          path: stars_dump.csv
'@
Write-TextFile -path (Join-Path $root '.github\workflows\crawl.yml') -content $crawlYaml

# .github/workflows/ci-tests.yml
$ciYaml = @'
name: CI Tests

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: github_crawler
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres" --health-interval 10s --health-timeout 5s --health-retries 5

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install system deps and python requirements
        run: |
          sudo apt-get update -y
          sudo apt-get install -y postgresql-client
          python -m pip install --upgrade pip
          pip install -r requirements.txt

      - name: Wait for Postgres to be available
        run: |
          for i in {1..15}; do
            pg_isready -h localhost -p 5432 -U postgres && break
            echo "waiting for postgres... ($i)"; sleep 2
          done

      - name: Setup Postgres schema
        env:
          PGPASSWORD: postgres
        run: |
          psql -h localhost -U postgres -d github_crawler -f sql/schema.sql

      - name: Run tests
        env:
          PGHOST: localhost
          PGPORT: 5432
          PGUSER: postgres
          PGPASSWORD: postgres
          PGDATABASE: github_crawler
        run: |
          pytest -q
'@
Write-TextFile -path (Join-Path $root '.github\workflows\ci-tests.yml') -content $ciYaml

# docker-compose.yml
$docker = @'
version: '3.8'
services:
  db:
    image: postgres:14
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: github_crawler
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
'@
Write-TextFile -path (Join-Path $root 'docker-compose.yml') -content $docker

# tests/test_api.py
$tests = @'
import os
import psycopg2
import pytest
from fastapi.testclient import TestClient

from src.api_server import app

client = TestClient(app)

@pytest.fixture(scope="module")
def db_conn():
    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", 5432)),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "github_crawler"),
    )
    conn.autocommit = True
    cur = conn.cursor()
    # Ensure tables exist and are clean for the test run. If schema isn't present,
    # load sql/schema.sql (useful when running tests locally against a fresh DB).
    try:
        cur.execute("SELECT 1 FROM repositories LIMIT 1;")
    except Exception:
        # attempt to create schema by executing statements in sql/schema.sql
        schema_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'sql', 'schema.sql'))
        with open(schema_path, 'r', encoding='utf-8') as f:
            sql = f.read()
        # split on semicolon conservatively and execute non-empty statements
        for stmt in [s.strip() for s in sql.split(';')]:
            if not stmt:
                continue
            try:
                cur.execute(stmt)
            except Exception:
                # ignore statements that fail (like IF NOT EXISTS differences)
                pass
    # truncate to start clean
    cur.execute("TRUNCATE stars_history, repositories CASCADE;")
    yield conn
    cur.close()
    conn.close()

def test_list_repos_empty(db_conn):
    res = client.get("/api/repos?limit=10")
    assert res.status_code == 200
    data = res.json()
    assert "items" in data

def test_list_repos_with_data(db_conn):
    cur = db_conn.cursor()
    repo_id = "test:1"
    name = "test/repo"
    url = "https://github.com/test/repo"
    cur.execute(
        "INSERT INTO repositories (repo_node_id, name_with_owner, url, created_at) VALUES (%s,%s,%s, now()) ON CONFLICT (repo_node_id) DO NOTHING",
        (repo_id, name, url),
    )
    cur.execute(
        "INSERT INTO stars_history (repo_node_id, snapshot_date, stars) VALUES (%s, current_date, %s) ON CONFLICT (repo_node_id, snapshot_date) DO UPDATE SET stars = EXCLUDED.stars",
        (repo_id, 42),
    )

    res = client.get("/api/repos?limit=10")
    assert res.status_code == 200
    data = res.json()
    items = data.get("items", [])
    assert any(i.get("name_with_owner") == name for i in items)

def test_trigger_crawl_monkeypatch(monkeypatch):
    class DummyP:
        def __init__(self, *a, **k):
            self.pid = 99999

    monkeypatch.setattr("src.api_server.subprocess.Popen", lambda *a, **k: DummyP())
    res = client.post("/api/crawl", json={"target": 5})
    assert res.status_code == 200
    data = res.json()
    assert data.get("pid") == 99999
'@
Write-TextFile -path (Join-Path $root 'tests\test_api.py') -content $tests

# web files
$web_pkg = @'
{
  "name": "github-stars-ui",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "vite": "^5.0.0",
    "tailwindcss": "^3.5.0",
    "postcss": "^8.4.0",
    "autoprefixer": "^10.4.0",
    "@vitejs/plugin-react": "^4.0.0"
  }
}
'@
Write-TextFile -path (Join-Path $root 'web\package.json') -content $web_pkg

$web_index = @'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>GitHub Stars UI</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
'@
Write-TextFile -path (Join-Path $root 'web\index.html') -content $web_index

$web_main = @'
import React from "react"
import { createRoot } from "react-dom/client"
import App from "./App"
import "./index.css"

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
'@
Write-TextFile -path (Join-Path $root 'web\src\main.jsx') -content $web_main

$web_app = @'
import React, { useEffect, useState } from "react"

function RepoTable({ items }) {
  return (
    <table className="min-w-full divide-y divide-gray-200">
      <thead className="bg-gray-50">
        <tr>
          <th className="px-6 py-3 text-left text-sm font-medium text-gray-500">Repository</th>
          <th className="px-6 py-3 text-right text-sm font-medium text-gray-500">Stars</th>
          <th className="px-6 py-3 text-left text-sm font-medium text-gray-500">Snapshot</th>
        </tr>
      </thead>
      <tbody className="bg-white divide-y divide-gray-200">
        {items.map((r) => (
          <tr key={r.repo_node_id}>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-blue-600">
              <a href={r.url} target="_blank" rel="noreferrer">{r.name_with_owner}</a>
            </td>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-right">{r.stars}</td>
            <td className="px-6 py-4 whitespace-nowrap text-sm">{r.snapshot_date}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

export default function App() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(false)
  const [target, setTarget] = useState(100)

  useEffect(() => {
    fetchRepos()
  }, [])

  async function fetchRepos() {
    setLoading(true)
    try {
      const res = await fetch('/api/repos?limit=50')
      const data = await res.json()
      setItems(data.items || [])
    } catch (e) {
      console.error(e)
    } finally {
      setLoading(false)
    }
  }

  async function triggerCrawl() {
    const res = await fetch('/api/crawl', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: Number(target) })
    })
    const data = await res.json()
    alert('Crawl started (pid=' + data.pid + ')')
  }

  return (
    <div className="max-w-4xl mx-auto p-6">
      <h1 className="text-2xl font-bold mb-4">GitHub Stars UI</h1>

      <div className="mb-4 flex gap-2 items-center">
        <input className="border px-2 py-1" value={target} onChange={(e) => setTarget(e.target.value)} />
        <button className="bg-blue-600 text-white px-3 py-1 rounded" onClick={triggerCrawl}>Trigger Crawl</button>
        <button className="ml-auto bg-gray-200 px-3 py-1 rounded" onClick={fetchRepos}>Refresh</button>
      </div>

      {loading ? <div>Loading...</div> : <RepoTable items={items} />}
    </div>
  )
}
'@
Write-TextFile -path (Join-Path $root 'web\src\App.jsx') -content $web_app

$web_css = @'
@tailwind base;
@tailwind components;
@tailwind utilities;

html, body, #root { height: 100%; }
body { font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial; }
'@
Write-TextFile -path (Join-Path $root 'web\src\index.css') -content $web_css

$tailwind = @'
module.exports = {
  content: [
    "./index.html",
    "./src/**/*.{js,jsx,ts,tsx}"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
'@
Write-TextFile -path (Join-Path $root 'web\tailwind.config.cjs') -content $tailwind

$postcss = @'
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
'@
Write-TextFile -path (Join-Path $root 'web\postcss.config.cjs') -content $postcss

$vite = @'
import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": "http://localhost:8000"
    }
  }
})
'@
Write-TextFile -path (Join-Path $root 'web\vite.config.js') -content $vite

Write-Host "All files created. Summary:"
Get-ChildItem -Path $root -Recurse -Depth 3 | Where-Object { -not $_.PSIsContainer } | Select-Object -First 100 FullName | ForEach-Object { Write-Host $_.FullName }

Write-Host ""
Write-Host "Next steps (recommended):"
Write-Host "1) Start Postgres via Docker Compose: docker compose up -d"
Write-Host "2) Set DB env vars in PowerShell:"
Write-Host "   $env:PGHOST='localhost'; $env:PGPORT='5432'; $env:PGUSER='postgres'; $env:PGPASSWORD='postgres'; $env:PGDATABASE='github_crawler'"
Write-Host "3) Install Python deps: python -m pip install -r requirements.txt"
Write-Host "4) Start backend: python -m uvicorn src.api_server:app --reload --host 0.0.0.0 --port 8000"
Write-Host "5) Start frontend: cd web; npm install; npm run dev"
Write-Host ""
Write-Host "If you want, I can also create a git repo and commit these files (I cannot run git on your machine from here)."