"""Telemetry API for backup-monitor.gr — receives compliance telemetry from backup-monitor."""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from datetime import datetime

import asyncpg
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

DATABASE_URL = os.environ["DATABASE_URL"]

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS telemetry_events (
    id               BIGSERIAL PRIMARY KEY,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source_ip        TEXT,
    event            VARCHAR(50) NOT NULL,
    fingerprint      VARCHAR(16),
    environment      VARCHAR(20),
    env_source       VARCHAR(100),
    public_ip        TEXT,
    server_url       TEXT,
    provider         VARCHAR(20),
    node_count       INTEGER,
    cp_nodes         INTEGER,
    namespace_count  INTEGER,
    k10_version      VARCHAR(50),
    enterprise_score INTEGER,
    license_key_provided BOOLEAN,
    license_key_valid    BOOLEAN,
    unlicensed_run_count INTEGER,
    src_hash         VARCHAR(16),
    tool_version     VARCHAR(20),
    client_timestamp TIMESTAMPTZ,
    raw_payload      JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_telemetry_fingerprint ON telemetry_events (fingerprint);
CREATE INDEX IF NOT EXISTS idx_telemetry_received_at ON telemetry_events (received_at DESC);

CREATE TABLE IF NOT EXISTS dns_beacon_log (
    id           BIGSERIAL PRIMARY KEY,
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source_ip    TEXT,
    source_port  INTEGER,
    query_name   TEXT NOT NULL,
    fingerprint  VARCHAR(16),
    src_hash     VARCHAR(16),
    tool_version VARCHAR(20)
);
CREATE INDEX IF NOT EXISTS idx_dns_fingerprint ON dns_beacon_log (fingerprint);
CREATE INDEX IF NOT EXISTS idx_dns_received_at ON dns_beacon_log (received_at DESC);
"""

pool: asyncpg.Pool


@asynccontextmanager
async def lifespan(application: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=10)
    async with pool.acquire() as conn:
        await conn.execute(SCHEMA_SQL)
    yield
    await pool.close()


app = FastAPI(title="backup-monitor telemetry", lifespan=lifespan)


# ---------------------------------------------------------------------------
# POST /api/v1/telemetry — ingest
# ---------------------------------------------------------------------------
@app.post("/api/v1/telemetry")
async def ingest_telemetry(request: Request):
    body = await request.json()

    source_ip = (
        request.headers.get("CF-Connecting-IP")
        or request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        or request.client.host
    )

    # Parse client timestamp
    client_ts = None
    ts_raw = body.get("timestamp")
    if ts_raw:
        try:
            client_ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            pass

    await pool.execute(
        """
        INSERT INTO telemetry_events (
            source_ip, event, fingerprint, environment, env_source,
            public_ip, server_url, provider, node_count, cp_nodes,
            namespace_count, k10_version, enterprise_score,
            license_key_provided, license_key_valid, unlicensed_run_count,
            src_hash, tool_version, client_timestamp, raw_payload
        ) VALUES (
            $1, $2, $3, $4, $5,
            $6, $7, $8, $9, $10,
            $11, $12, $13,
            $14, $15, $16,
            $17, $18, $19, $20
        )
        """,
        source_ip,
        body.get("event", "unknown"),
        body.get("fingerprint"),
        body.get("environment"),
        body.get("env_source"),
        body.get("public_ip"),
        body.get("server_url"),
        body.get("provider"),
        body.get("node_count"),
        body.get("cp_nodes"),
        body.get("namespace_count"),
        body.get("k10_version"),
        body.get("enterprise_score"),
        body.get("license_key_provided"),
        body.get("license_key_valid"),
        body.get("unlicensed_run_count"),
        body.get("src_hash"),
        body.get("tool_version"),
        client_ts,
        json.dumps(body),
    )

    return {"status": "ok"}


# ---------------------------------------------------------------------------
# GET /api/v1/telemetry — query
# ---------------------------------------------------------------------------
@app.get("/api/v1/telemetry")
async def query_telemetry(
    fingerprint: str | None = None,
    environment: str | None = None,
    since: str | None = None,
    limit: int = 100,
):
    clauses = []
    params: list = []
    idx = 1

    if fingerprint:
        clauses.append(f"fingerprint = ${idx}")
        params.append(fingerprint)
        idx += 1
    if environment:
        clauses.append(f"environment = ${idx}")
        params.append(environment)
        idx += 1
    if since:
        clauses.append(f"received_at >= ${idx}")
        try:
            params.append(datetime.fromisoformat(since.replace("Z", "+00:00")))
        except ValueError:
            return JSONResponse({"error": "invalid 'since' format"}, status_code=400)
        idx += 1

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    limit = min(max(1, limit), 1000)

    rows = await pool.fetch(
        f"SELECT * FROM telemetry_events {where} ORDER BY received_at DESC LIMIT ${idx}",
        *params,
        limit,
    )

    return [
        {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in dict(r).items()}
        for r in rows
    ]


# ---------------------------------------------------------------------------
# GET /api/v1/dns — query DNS beacon logs
# ---------------------------------------------------------------------------
@app.get("/api/v1/dns")
async def query_dns(
    fingerprint: str | None = None,
    since: str | None = None,
    limit: int = 100,
):
    clauses = []
    params: list = []
    idx = 1

    if fingerprint:
        clauses.append(f"fingerprint = ${idx}")
        params.append(fingerprint)
        idx += 1
    if since:
        clauses.append(f"received_at >= ${idx}")
        try:
            params.append(datetime.fromisoformat(since.replace("Z", "+00:00")))
        except ValueError:
            return JSONResponse({"error": "invalid 'since' format"}, status_code=400)
        idx += 1

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    limit = min(max(1, limit), 1000)

    rows = await pool.fetch(
        f"SELECT * FROM dns_beacon_log {where} ORDER BY received_at DESC LIMIT ${idx}",
        *params,
        limit,
    )

    return [
        {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in dict(r).items()}
        for r in rows
    ]


# ---------------------------------------------------------------------------
# GET /api/v1/stats — summary
# ---------------------------------------------------------------------------
@app.get("/api/v1/stats")
async def stats():
    async with pool.acquire() as conn:
        unique_fps = await conn.fetchval(
            "SELECT COUNT(DISTINCT fingerprint) FROM telemetry_events"
        )

        env_rows = await conn.fetch(
            "SELECT environment, COUNT(*) AS cnt FROM telemetry_events GROUP BY environment ORDER BY cnt DESC"
        )

        daily_rows = await conn.fetch(
            "SELECT received_at::date AS day, COUNT(*) AS cnt "
            "FROM telemetry_events GROUP BY day ORDER BY day DESC LIMIT 30"
        )

        dns_count = await conn.fetchval("SELECT COUNT(*) FROM dns_beacon_log")

    return {
        "unique_fingerprints": unique_fps,
        "by_environment": {r["environment"]: r["cnt"] for r in env_rows},
        "daily_events": {str(r["day"]): r["cnt"] for r in daily_rows},
        "dns_beacon_total": dns_count,
    }


# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    try:
        await pool.fetchval("SELECT 1")
        return {"status": "healthy"}
    except Exception as e:
        return JSONResponse({"status": "unhealthy", "error": str(e)}, status_code=503)
