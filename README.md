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
