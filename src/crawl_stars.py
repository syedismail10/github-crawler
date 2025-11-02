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


@backoff.on_exception(
    backoff.expo, (requests.exceptions.RequestException, RuntimeError), max_time=60
)
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
            (
                r["id"],
                r["nameWithOwner"],
                r.get("url"),
                r.get("createdAt"),
                r.get("description"),
                r.get("language"),
            )
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
        values = [
            (r["id"], snapshot_date, r["stargazerCount"], datetime.now(timezone.utc))
            for r in rows
        ]
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
        "language": node.get("primaryLanguage").get("name")
        if node.get("primaryLanguage")
        else None,
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
    collected = {}
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
            for repo in parsed:
                collected[repo["id"]] = repo
            # adaptive rate limit handling
            rate = data.get("rateLimit") or {}
            remaining = rate.get("remaining")
            resetAt = rate.get("resetAt")
            if remaining is not None and remaining < 10 and resetAt:
                # sleep until reset
                reset_dt = date_parser.parse(resetAt)
                wait = (reset_dt - datetime.now(timezone.utc)).total_seconds()
                if wait > 0:
                    print(
                        f"Rate limit low ({remaining}), sleeping {wait:.1f}s until reset"
                    )
                    time.sleep(wait + 1)

            page_info = search.get("pageInfo", {})
            if page_info.get("hasNextPage"):
                after = page_info.get("endCursor")
            else:
                break

            if len(collected) >= target_count:
                return list(collected.values())[:target_count]

        if len(collected) >= target_count:
            break

    return list(collected.values())[:target_count]


def main():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--target",
        type=int,
        default=int(get_env("TARGET_COUNT", 1000)),
        help="Number of repos to collect (default from TARGET_COUNT env or 1000)",
    )
    p.add_argument(
        "--window-days",
        type=int,
        default=int(get_env("WINDOW_DAYS", 30)),
        help="Window size in days for created: ranges",
    )
    args = p.parse_args()

    token = get_env("GITHUB_TOKEN")
    if not token:
        print(
            "GITHUB_TOKEN is required via env (in Actions it's provided automatically). Exiting."
        )
        sys.exit(1)

    print(
        f"Collecting up to {args.target} repositories (window_days={args.window_days})"
    )
    repos = collect_repositories(
        token, target_count=args.target, window_days=args.window_days
    )
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
