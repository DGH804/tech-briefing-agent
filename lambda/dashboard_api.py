"""Read side of the status dashboard.

Returns the latest runs for each configured agent from DynamoDB. Sits
behind API Gateway with a Cognito JWT authorizer. Its role can only
Query and GetItem the status table, so it never writes.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ddb = boto3.client("dynamodb")

ROWS_PER_AGENT = 40  # about 10 runs at 4 rows each


def plain(item):
    return {k: int(v["N"]) if "N" in v else v.get("S") for k, v in item.items()}


def summarize(rows, now):
    rows.sort(key=lambda r: r["timestamp"])
    last = rows[-1]
    status = last.get("status")
    if status == "running":
        age = (now - datetime.fromisoformat(last["timestamp"])).total_seconds()
        if age > int(os.environ.get("STALE_SECONDS", "120")):
            status = "timed_out"
    return {
        "run_id": last.get("run_id"),
        "started_at": rows[0]["timestamp"],
        "updated_at": last["timestamp"],
        "status": status,
        "steps": [r.get("step") for r in rows],
        "articles": last.get("articles"),
        "input_tokens": last.get("input_tokens"),
        "output_tokens": last.get("output_tokens"),
        "duration_ms": last.get("duration_ms"),
        "error": last.get("error"),
    }


def agent_status(agent, now):
    resp = ddb.query(
        TableName=os.environ["TABLE_NAME"],
        KeyConditionExpression="agent_name = :a",
        ExpressionAttributeValues={":a": {"S": agent}},
        ScanIndexForward=False,  # newest first
        Limit=ROWS_PER_AGENT,
    )
    runs = {}
    for row in map(plain, resp.get("Items", [])):
        runs.setdefault(row.get("run_id") or row["timestamp"], []).append(row)

    summaries = sorted((summarize(r, now) for r in runs.values()),
                       key=lambda s: s["started_at"], reverse=True)
    running = bool(summaries) and summaries[0]["status"] == "running"
    return {"agent": agent, "state": "running" if running else "idle", "runs": summaries}


def handler(event, context):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    log.info("Status read by %s", claims.get("username") or claims.get("sub"))

    now = datetime.now(timezone.utc)
    agents = []
    for name in [a.strip() for a in os.environ["AGENTS"].split(",") if a.strip()]:
        try:
            agents.append(agent_status(name, now))
        except Exception as exc:  # one bad agent shouldn't blank the dashboard
            log.error("Query failed for %s: %s", name, exc)
            agents.append({"agent": name, "state": "unknown", "runs": [], "error": "Could not load status"})

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps({
            "generated_at": now.isoformat(timespec="seconds"),
            "max_tokens": int(os.environ.get("MAX_TOKENS", "0")),
            "agents": agents,
        }),
    }
