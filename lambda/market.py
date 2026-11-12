"""Weekday market review.

Pulls end-of-day prices from Massive (formerly Polygon.io): major indexes
(through US-listed ETFs), the 11 sector ETFs, the biggest liquid US
decliners and a watchlist. Adds the market news, asks Claude for a
factual review, and publishes it to the same SNS topic as the briefing.

Facts only: no buy or sell calls. Standard library + boto3 only.
"""

import html
import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
import uuid
from collections import deque
from datetime import datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ssm = boto3.client("ssm")
sns = boto3.client("sns")
ddb = boto3.client("dynamodb")

API_URL = "https://api.anthropic.com/v1/messages"
USER_AGENT = "tech-briefing-agent/1.0"
CALLS_PER_MINUTE = 5        # Massive free tier
TOP_DECLINERS = 5
LOOKUP_LIMIT = 6            # reference lookups spent finding TOP_DECLINERS stocks
STOCK_TYPES = {"CS", "ADRC"}  # common stock and ADRs; skips ETFs, warrants, units
NEWS_PER_TICKER = 3
MARKET_HEADLINES = 8
TICKER_RE = re.compile(r"^[A-Z]{1,5}(\.[A-Z])?$")  # allows share classes like BRK.B

INDEXES = {
    "SPY": "S&P 500",
    "QQQ": "Nasdaq-100",
    "DIA": "Dow Jones",
    "IWM": "Russell 2000",
    "EWU": "UK (FTSE, via EWU)",
    "EWG": "Germany (DAX, via EWG)",
    "EWJ": "Japan (Nikkei, via EWJ)",
    "EEM": "Emerging markets (via EEM)",
}

SECTORS = {
    "XLK": "Technology",
    "XLC": "Communication Services",
    "XLY": "Consumer Discretionary",
    "XLP": "Consumer Staples",
    "XLE": "Energy",
    "XLF": "Financials",
    "XLV": "Health Care",
    "XLI": "Industrials",
    "XLB": "Materials",
    "XLRE": "Real Estate",
    "XLU": "Utilities",
}

DISCLAIMER = (
    "\n\n--\nFacts for your own research, not investment advice. End-of-day prices from "
    "Massive (formerly Polygon.io). Indexes are shown through the ETFs that track them."
)

_secrets = {}                              # cached across warm invocations
_calls = deque(maxlen=CALLS_PER_MINUTE)    # times of recent market API calls


def get_secret(env_name):
    if env_name not in _secrets:
        resp = ssm.get_parameter(Name=os.environ[env_name], WithDecryption=True)
        _secrets[env_name] = resp["Parameter"]["Value"]
    return _secrets[env_name]


def clean(text):
    text = re.sub(r"<[^>]+>", " ", text or "")
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


# ---------------------------------------------------------------
# Market data
# ---------------------------------------------------------------
def market_get(path, **params):
    """GET from the market API, waiting as needed to stay under the free rate limit."""
    if len(_calls) == _calls.maxlen:
        wait = 61 - (time.monotonic() - _calls[0])
        if wait > 0:
            log.info("Market API rate limit: waiting %.0f s", wait)
            time.sleep(wait)
    _calls.append(time.monotonic())

    url = os.environ["MARKET_API_BASE"].rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Authorization": f"Bearer {get_secret('MARKET_KEY_PARAM')}",  # key stays out of URLs
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def grouped_day(day):
    data = market_get(f"/v2/aggs/grouped/locale/us/market/stocks/{day.isoformat()}", adjusted="true")
    return {r["T"]: r for r in data.get("results") or []}


def previous_trading_day(before, max_tries=5):
    """Latest weekday before `before` that has market data (skips holidays)."""
    day = before
    for _ in range(max_tries):
        day -= timedelta(days=1)
        while day.weekday() >= 5:  # Saturday, Sunday
            day -= timedelta(days=1)
        bars = grouped_day(day)
        if bars:
            return day, bars
    raise RuntimeError(f"No market data in the {max_tries} weekdays before {before}")


def pct(now, then):
    return round((now - then) / then * 100, 2) if then else None


def change(ticker, latest, prev, week):
    bar = latest.get(ticker)
    if not bar:
        return None
    return {
        "ticker": ticker,
        "close": bar["c"],
        "day_pct": pct(bar["c"], prev.get(ticker, {}).get("c")),
        "week_pct": pct(bar["c"], week.get(ticker, {}).get("c")),
        "dollar_volume": round(bar["c"] * bar["v"]),
    }


def decline_candidates(latest, prev, week):
    """Liquid tickers that fell, biggest drop first. No API calls."""
    min_price = float(os.environ.get("MIN_PRICE", "5"))
    min_dollar_volume = float(os.environ.get("MIN_DOLLAR_VOLUME", "50000000"))
    found = []
    for ticker, bar in latest.items():
        if not TICKER_RE.match(ticker) or ticker in INDEXES or ticker in SECTORS:
            continue
        if bar["c"] < min_price or bar["c"] * bar["v"] < min_dollar_volume:
            continue
        c = change(ticker, latest, prev, week)
        if c and c["day_pct"] is not None and c["day_pct"] < 0:
            found.append(c)
    return sorted(found, key=lambda c: c["day_pct"])


def keep_stocks(candidates):
    """Look up candidates until TOP_DECLINERS are stocks, dropping ETFs and the like."""
    picked = []
    for c in candidates[:LOOKUP_LIMIT]:
        try:
            info = market_get(f"/v3/reference/tickers/{c['ticker']}").get("results") or {}
        except Exception as exc:
            log.warning("Lookup failed for %s: %s", c["ticker"], exc)
            continue
        if info.get("type") in STOCK_TYPES:
            picked.append({**c, "name": info.get("name") or c["ticker"]})
            if len(picked) == TOP_DECLINERS:
                break
    return picked


def market_news(since, tickers):
    """Recent headlines: up to NEWS_PER_TICKER per ticker, plus general market headlines."""
    try:
        data = market_get("/v2/reference/news", **{
            "published_utc.gte": since.isoformat(), "order": "desc", "sort": "published_utc", "limit": "1000",
        })
    except Exception as exc:  # the review still goes out, just without reasons
        log.warning("News fetch failed: %s", exc)
        return {}, []

    by_ticker = {t: [] for t in tickers}
    general = []
    for item in data.get("results", []):
        headline = {
            "title": clean(item.get("title")),
            "summary": clean(item.get("description"))[:300],
            "publisher": (item.get("publisher") or {}).get("name", ""),
        }
        if len(general) < MARKET_HEADLINES:
            general.append(headline)
        for t in item.get("tickers") or []:
            if t in by_ticker and len(by_ticker[t]) < NEWS_PER_TICKER:
                by_ticker[t].append(headline)
    return by_ticker, general


# ---------------------------------------------------------------
# Claude
# ---------------------------------------------------------------
def fmt_pct(v):
    return "n/a" if v is None else f"{v:+.2f}%"


def fmt_line(label, c):
    return f"{label} | close {c['close']:,.2f} | day {fmt_pct(c['day_pct'])} | week {fmt_pct(c['week_pct'])}"


def fmt_news(items):
    return "\n".join(f"    - {h['title']} ({h['publisher']}): {h['summary']}" for h in items) or "    - (no headlines)"


def build_prompt(days, indexes, sectors, decliners, watchlist, missing, news, general):
    latest_day, prev_day, week_day = days
    alert = float(os.environ.get("ALERT_PCT", "3"))

    lines = ["MARKETS (ETF | name)"]
    lines += [fmt_line(f"{c['ticker']} | {INDEXES[c['ticker']]}", c) for c in indexes]
    lines += ["", "SECTORS (ETF | sector)"]
    lines += [fmt_line(f"{c['ticker']} | {SECTORS[c['ticker']]}", c) for c in sectors]
    lines += ["", "BIGGEST DECLINERS (liquid US stocks)"]
    for c in decliners:
        lines.append(fmt_line(f"{c['ticker']} | {c['name']}", c) + f" | dollar volume ${c['dollar_volume'] / 1e6:,.0f}M")
        lines.append("  headlines:\n" + fmt_news(news.get(c["ticker"], [])))
    lines += ["", f"WATCHLIST (alert at {alert:g}% or more down on the day)"]
    for c in watchlist:
        lines.append(fmt_line(c["ticker"], c))
        lines.append("  headlines:\n" + fmt_news(news.get(c["ticker"], [])))
    lines += [f"{t} | no price data for this day (check the ticker)" for t in missing]
    if not watchlist and not missing:
        lines.append("(empty)")
    lines += ["", "GENERAL MARKET HEADLINES", fmt_news(general)]

    return f"""You are writing a weekday market review email for one reader who does their own investment research.
Prices are end-of-day for {latest_day:%A, %B %d, %Y}. "day" is the change from the previous close ({prev_day:%b %d}); "week" is the change from {week_day:%b %d}.

Write plain text (no markdown, no asterisks or pound signs) with these sections:
1. Big picture: 2 or 3 sentences on how the markets moved, using the numbers given and the general headlines.
2. Markets: one line per market, worst day first: name, day %, week %.
3. Sectors: one line per sector, worst day first: name, day %, week %.
4. Biggest decliners: for each stock, a line with ticker, company name, close, day %, week % and dollar volume.
   Then a line starting "Why:" giving the reason only if one of that stock's headlines explains the drop,
   naming the publisher. If none does, write "Why: no headline in today's news explains this drop."
5. Watchlist: one line per ticker with close, day % and week %. Start the line with "ALERT" if it fell
   {alert:g}% or more on the day, and add a "Why:" line for those the same way as above. Skip this
   section if the watchlist is empty.

Rules:
- Use only the data and headlines below. Do not invent numbers, reasons or company facts.
- Never call anything a buy, sell or hold, and never use the words undervalued, overvalued, opportunity,
  bargain, cheap or price target. Make no predictions or recommendations. Describe what happened.
- Markets outside the US are shown through US-listed ETFs; say so once in the Markets section.

DATA
{chr(10).join(lines)}"""


def ask_claude(prompt):
    body = json.dumps({
        "model": os.environ["CLAUDE_MODEL"],
        "max_tokens": int(os.environ.get("MAX_TOKENS", "3000")),
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "x-api-key": get_secret("API_KEY_PARAM"),
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.loads(resp.read())

    usage = data.get("usage", {})
    log.info("Claude usage: input=%s output=%s stop=%s",
             usage.get("input_tokens"), usage.get("output_tokens"), data.get("stop_reason"))
    text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
    if re.search(r"\b(buy|sell)\b", text, re.IGNORECASE):
        log.warning("Review mentions buy/sell despite instructions; check the wording")
    return text, usage


def publish(subject, message):
    sns.publish(TopicArn=os.environ["TOPIC_ARN"], Subject=subject[:100], Message=message)


# ---------------------------------------------------------------
# Status rows for the dashboard (same shape as briefing.py)
# ---------------------------------------------------------------
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
    record_status(run, "running", "started")

    try:
        today = datetime.now(timezone.utc).date()
        latest_day, latest = previous_trading_day(today)
        prev_day, prev = previous_trading_day(latest_day)
        week_day, week = previous_trading_day(latest_day - timedelta(days=6))
        record_status(run, "running", "feeds_fetched")

        def rank(tickers):
            rows = [c for c in (change(t, latest, prev, week) for t in tickers) if c]
            return sorted(rows, key=lambda c: c["day_pct"] if c["day_pct"] is not None else 0)

        indexes = rank(INDEXES)
        sectors = rank(SECTORS)
        watch_tickers = [t.strip().upper() for t in os.environ.get("WATCHLIST", "").split(",") if t.strip()]
        watchlist = rank(watch_tickers)
        missing = [t for t in watch_tickers if t not in latest]
        candidates = decline_candidates(latest, prev, week)

        news, general = market_news(prev_day, [c["ticker"] for c in candidates[:LOOKUP_LIMIT]] + watch_tickers)
        decliners = keep_stocks(candidates)
        headlines = sum(len(v) for v in news.values()) + len(general)
        log.info("Data for %s: %d decliners, %d watchlist, %d headlines",
                 latest_day, len(decliners), len(watchlist), headlines)

        record_status(run, "running", "writing", articles=headlines)
        review, usage = ask_claude(build_prompt(
            (latest_day, prev_day, week_day), indexes, sectors, decliners, watchlist, missing, news, general))
        publish(f"Market Review - {latest_day:%b %d, %Y}", review + DISCLAIMER)
    except Exception as exc:
        record_status(run, "failed", "error", error=str(exc))
        raise  # keep the Lambda error so the scheduler's retry still runs

    record_status(
        run, "sent", "published",
        articles=headlines,
        input_tokens=usage.get("input_tokens"),
        output_tokens=usage.get("output_tokens"),
    )
    return {"status": "sent", "market_day": latest_day.isoformat(), "decliners": len(decliners)}
