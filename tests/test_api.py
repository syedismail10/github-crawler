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
        # If the schema SQL isn't applied for any reason, create the two required
        # tables directly here to make tests more robust (avoids relying on psql).
        create_repos = """
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
        """
        create_stars = """
        CREATE TABLE IF NOT EXISTS stars_history (
            repo_node_id TEXT NOT NULL REFERENCES repositories(repo_node_id) ON DELETE CASCADE,
            snapshot_date DATE NOT NULL,
            stars INTEGER NOT NULL,
            captured_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (repo_node_id, snapshot_date)
        );
        CREATE INDEX IF NOT EXISTS idx_stars_snapshot_date ON stars_history (snapshot_date);
        """
        # Execute statements one by one (psycopg2 can't execute multiple statements in one execute call reliably)
        for stmt in [s.strip() for s in create_repos.split(";") if s.strip()]:
            try:
                cur.execute(stmt)
            except Exception:
                pass
        for stmt in [s.strip() for s in create_stars.split(";") if s.strip()]:
            try:
                cur.execute(stmt)
            except Exception:
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
