"""Daily AI news briefing.

Pulls recent articles from RSS/Atom feeds, asks Claude to write a short
briefing, and publishes it to an SNS topic (which emails it).

Standard library + boto3 only, so no Lambda layer or packaging is needed.
"""

import email.utils
import html
import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ssm = boto3.client("ssm")
sns = boto3.client("sns")
ddb = boto3.client("dynamodb")

API_URL = "https://api.anthropic.com/v1/messages"
USER_AGENT = "tech-briefing-agent/1.0"
MAX_ARTICLES = 40          # cap what we send to Claude to keep tokens low
SUMMARY_CHARS = 300        # per-article snippet length

ATOM = "{http://www.w3.org/2005/Atom}"

_api_key = None  # cached across warm invocations


def get_api_key():
    global _api_key
    if _api_key is None:
        resp = ssm.get_parameter(Name=os.environ["API_KEY_PARAM"], WithDecryption=True)
        _api_key = resp["Parameter"]["Value"]
    return _api_key


def clean(text):
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def parse_date(value):
    if not value:
        return None
    try:
        dt = email.utils.parsedate_to_datetime(value)          # RSS
    except (TypeError, ValueError):
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))  # Atom
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def fetch_feed(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=10) as resp:
        root = ET.fromstring(resp.read())

    source = urllib.parse.urlparse(url).netloc.replace("www.", "")
    items = []

    # RSS 2.0
    for item in root.iter("item"):
        items.append({
            "source": source,
            "title": clean(item.findtext("title")),
            "link": (item.findtext("link") or "").strip(),
            "summary": clean(item.findtext("description"))[:SUMMARY_CHARS],
            "published": parse_date(item.findtext("pubDate")),
        })

    # Atom
    for entry in root.iter(f"{ATOM}entry"):
        link_el = entry.find(f"{ATOM}link")
        items.append({
            "source": source,
            "title": clean(entry.findtext(f"{ATOM}title")),
            "link": link_el.get("href", "") if link_el is not None else "",
            "summary": clean(entry.findtext(f"{ATOM}summary")
                             or entry.findtext(f"{ATOM}content"))[:SUMMARY_CHARS],
            "published": parse_date(entry.findtext(f"{ATOM}published")
                                    or entry.findtext(f"{ATOM}updated")),
        })

    return items


def collect_articles():
    feeds = [f.strip() for f in os.environ["FEEDS"].split(",") if f.strip()]
    cutoff = datetime.now(timezone.utc) - timedelta(hours=int(os.environ.get("LOOKBACK_HOURS", "26")))

    articles, seen = [], set()
    for url in feeds:
        try:
            for a in fetch_feed(url):
                key = a["title"].lower()
                if not a["title"] or key in seen:
                    continue
                if a["published"] and a["published"] < cutoff:
                    continue
                seen.add(key)
                articles.append(a)
        except Exception as exc:  # one bad feed shouldn't kill the briefing
            log.warning("Feed failed %s: %s", url, exc)

    articles.sort(key=lambda a: a["published"] or cutoff, reverse=True)
    return articles[:MAX_ARTICLES]


def ask_claude(articles):
    listing = "\n\n".join(
        f"[{i}] {a['title']} ({a['source']})\n{a['summary']}\n{a['link']}"
        for i, a in enumerate(articles, 1)
    )
    today = datetime.now(timezone.utc).strftime("%A, %B %d, %Y")

    prompt = f"""You are writing a daily AI news briefing email for a cloud and security engineer.
Today is {today}. Below are the past day's AI headlines from several outlets.

Write a plain-text briefing (no markdown, no asterisks or pound signs):
- Start with a 2-sentence "Big picture" of the day.
- Then the 5 to 8 most important stories. For each: a short headline line,
  one or two sentences on what happened and why it matters, then the link.
- Merge duplicate stories covered by more than one outlet.
- Finish with a "Cloud & security angle" section of 1 to 3 bullets (use "-")
  if any story touches AWS, cloud, AI security, or regulation; skip it otherwise.
- Use only the information given. Do not invent facts.

Headlines:
{listing}"""

    body = json.dumps({
        "model": os.environ["CLAUDE_MODEL"],
        "max_tokens": int(os.environ.get("MAX_TOKENS", "1200")),
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "x-api-key": get_api_key(),
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())

    usage = data.get("usage", {})
    log.info("Claude usage: input=%s output=%s", usage.get("input_tokens"), usage.get("output_tokens"))
    return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"), usage


def publish(subject, message):
    sns.publish(TopicArn=os.environ["TOPIC_ARN"], Subject=subject[:100], Message=message)


def record_status(run, status, step, **fields):
    """Write one status row for the dashboard.

    Never raises: a failed status write is logged and skipped so it can
    never stop the email from going out.
    """
    try:
        now = datetime.now(timezone.utc)
        expires = now + timedelta(days=int(os.environ.get("STATUS_TTL_DAYS", "30")))
        item = {
            "agent_name": {"S": os.environ["AGENT_NAME"]},
            "timestamp": {"S": now.isoformat(timespec="milliseconds")},
            "expires_at": {"N": str(int(expires.timestamp()))},  # TTL needs epoch seconds
            "run_id": {"S": run["id"]},
            "status": {"S": status},
            "step": {"S": step},
            "duration_ms": {"N": str(int((time.monotonic() - run["started"]) * 1000))},
        }
        for name, value in fields.items():
            if value is None:
                continue
            item[name] = {"N": str(value)} if isinstance(value, int) else {"S": str(value)[:500]}
        ddb.put_item(TableName=os.environ["TABLE_NAME"], Item=item)
    except Exception as exc:
        log.error("Status write failed (%s/%s), continuing: %s", status, step, exc)


def handler(event, context):
    run = {
        "id": getattr(context, "aws_request_id", None) or str(uuid.uuid4()),
        "started": time.monotonic(),
    }
    date_str = datetime.now(timezone.utc).strftime("%b %d, %Y")
    record_status(run, "running", "started")

    try:
        articles = collect_articles()
        log.info("Collected %d articles", len(articles))
        record_status(run, "running", "feeds_fetched", articles=len(articles))

        if not articles:
            publish(f"AI Briefing - {date_str}", "No new AI articles found in the feeds today.")
            record_status(run, "empty", "published", articles=0)
            return {"status": "empty"}

        record_status(run, "running", "writing", articles=len(articles))
        briefing, usage = ask_claude(articles)
        publish(f"AI Briefing - {date_str}", briefing)
    except Exception as exc:
        record_status(run, "failed", "error", error=str(exc))
        raise  # keep the Lambda error so the scheduler's retry still runs

    record_status(
        run, "sent", "published",
        articles=len(articles),
        input_tokens=usage.get("input_tokens"),
        output_tokens=usage.get("output_tokens"),
    )
    return {"status": "sent", "articles": len(articles)}
