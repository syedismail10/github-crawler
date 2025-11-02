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
