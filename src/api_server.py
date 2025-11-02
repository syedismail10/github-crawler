from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
import subprocess
import psycopg2
import sys
from dotenv import load_dotenv

load_dotenv()

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
        # Get total count
        cur.execute(
            "SELECT COUNT(*) FROM (SELECT DISTINCT repo_node_id FROM stars_history) t"
        )
        total_count = cur.fetchone()[0]
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
        return {
            "total": total_count,
            "count": len(result),
            "items": result,
            "limit": limit,
            "offset": offset,
        }
    finally:
        conn.close()


@app.post("/api/crawl")
def trigger_crawl(req: CrawlRequest):
    """Trigger a background crawl (spawns a subprocess). Returns PID of the spawned process."""
    # Make sure the crawler exists
    crawl_script = os.path.join(os.path.dirname(__file__), "crawl_stars.py")
    if not os.path.exists(crawl_script):
        raise HTTPException(
            status_code=500, detail="crawl_stars.py not found on server"
        )

    # Run crawler in background with provided TARGET_COUNT
    log_file = os.path.join(os.path.dirname(__file__), "crawl.log")
    with open(log_file, "w") as f:
        cmd = [sys.executable, crawl_script, "--target", str(req.target)]
        proc = subprocess.Popen(
            cmd, env=dict(os.environ), stdout=f, stderr=subprocess.STDOUT
        )
    return {"pid": proc.pid, "target": req.target, "log_file": log_file}
