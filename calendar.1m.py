#!/usr/bin/env -S /Users/kyle/.local/bin/uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["google-api-python-client", "google-auth-oauthlib"]
# ///
#
# <xbar.title>Calendar</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>kyle</xbar.author>
# <xbar.desc>Upcoming Google Calendar events in the menu bar (Notion Calendar style).</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# SwiftBar re-renders every minute (for the countdown) but only calls the
# Google Calendar API every FETCH_EVERY seconds; events are cached in between.
#
# Files in ~/.config/menubar-calendar/:
#   credentials.json      OAuth "Desktop app" client from Google Cloud (you add this)
#   accounts/<email>.json one token per signed-in Google account
#   cache.json            last fetched events
#   config.json           optional: {"exclude": ["Holidays in Germany"], "lookahead_minutes": 60,
#                                    "hidden_accounts": ["work@example.com"],
#                                    "account_colors": {"work@example.com": "#4f8ff7"}}
#
# Actions: `calendar.1m.py auth` (add an account), `calendar.1m.py remove <email>`,
#          `calendar.1m.py toggle <email>` (hide/show), `calendar.1m.py refresh` (fetch now).

import base64
import datetime as dt
import functools
import json
import math
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("MENUBAR_CAL_DIR", Path.home() / ".config" / "menubar-calendar"))
CREDS = CONFIG_DIR / "credentials.json"
ACCOUNTS_DIR = CONFIG_DIR / "accounts"
CACHE = CONFIG_DIR / "cache.json"
SETTINGS = CONFIG_DIR / "config.json"
SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]

FETCH_EVERY = 300  # seconds between API calls
TITLE_MAX = 24  # chars of the event name shown in the menu bar
PLUGIN_NAME = "calendar"  # SwiftBar plugin name (file name before the first dot)

SELF = os.path.abspath(__file__)
GRAY = "#86868b"
# Colors handed out to accounts in order; saved to config.json on first sight.
PALETTE = ["#4f8ff7", "#f0883e", "#3fb950", "#d670d6", "#e5534b", "#2cc6c6", "#e3b341", "#a371f7"]


# --- settings / cache -------------------------------------------------------


def load_json(path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def settings():
    s = {"exclude": [], "lookahead_minutes": 60, "hidden_accounts": []}
    s.update(load_json(SETTINGS, {}))
    return s


def accounts():
    return sorted(p.stem for p in ACCOUNTS_DIR.glob("*.json"))


def active_accounts():
    hidden = set(settings()["hidden_accounts"])
    return [a for a in accounts() if a not in hidden]


def account_colors(emails):
    s = load_json(SETTINGS, {})
    colors = s.get("account_colors", {})
    new = [e for e in emails if e not in colors]
    for email in new:
        unused = [c for c in PALETTE if c not in colors.values()]
        colors[email] = unused[0] if unused else PALETTE[len(colors) % len(PALETTE)]
    if new:
        s["account_colors"] = colors
        SETTINGS.write_text(json.dumps(s, indent=2) + "\n")
    return colors


def toggle(email):
    s = load_json(SETTINGS, {})
    hidden = s.get("hidden_accounts", [])
    s["hidden_accounts"] = [a for a in hidden if a != email] if email in hidden else hidden + [email]
    SETTINGS.write_text(json.dumps(s, indent=2) + "\n")


def token_path(email):
    return ACCOUNTS_DIR / f"{email}.json"


def swiftbar_refresh():
    subprocess.run(["open", "-g", f"swiftbar://refreshplugin?name={PLUGIN_NAME}"], check=False)


# --- Google API ---------------------------------------------------------------


def calendar_service(creds):
    from googleapiclient.discovery import build

    return build("calendar", "v3", credentials=creds, cache_discovery=False)


def auth():
    from google_auth_oauthlib.flow import InstalledAppFlow

    flow = InstalledAppFlow.from_client_secrets_file(str(CREDS), SCOPES)
    # select_account makes Google show the account picker instead of reusing
    # whichever account the browser is already signed in to.
    creds = flow.run_local_server(port=0, open_browser=True, prompt="select_account consent")
    # The primary calendar's id is the account's email address.
    email = calendar_service(creds).calendars().get(calendarId="primary").execute()["id"]
    ACCOUNTS_DIR.mkdir(parents=True, exist_ok=True)
    token_path(email).write_text(creds.to_json())
    token_path(email).chmod(0o600)
    CACHE.unlink(missing_ok=True)


def remove(email):
    path = token_path(email)
    token = load_json(path, {}).get("refresh_token")
    if token:
        # Best effort: also revoke the grant on Google's side.
        import requests

        try:
            requests.post("https://oauth2.googleapis.com/revoke", data={"token": token}, timeout=10)
        except requests.RequestException:
            pass
    path.unlink(missing_ok=True)
    CACHE.unlink(missing_ok=True)


def join_url(ev):
    if ev.get("hangoutLink"):
        return ev["hangoutLink"]
    for p in ev.get("conferenceData", {}).get("entryPoints", []):
        if p.get("entryPointType") == "video":
            return p.get("uri")
    loc = ev.get("location", "")
    if loc.startswith("https://"):
        return loc.split()[0]
    return None


def fetch_account(email):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    creds = Credentials.from_authorized_user_file(str(token_path(email)), SCOPES)
    if not creds.valid:
        creds.refresh(Request())
        token_path(email).write_text(creds.to_json())

    svc = calendar_service(creds)
    palette = svc.colors().get().execute().get("event", {})

    cals, page = [], None
    while True:
        r = svc.calendarList().list(pageToken=page).execute()
        cals += r.get("items", [])
        page = r.get("nextPageToken")
        if not page:
            break

    exclude = set(settings()["exclude"])
    start = dt.datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + dt.timedelta(days=2)

    events, failed = [], []
    for cal in cals:
        name = cal.get("summaryOverride") or cal.get("summary", "")
        # `selected` mirrors the checkbox in the Google Calendar sidebar.
        if not cal.get("selected") or cal["id"] in exclude or name in exclude:
            continue
        try:
            items, page = [], None
            while True:
                r = (
                    svc.events()
                    .list(
                        calendarId=cal["id"],
                        timeMin=start.isoformat(),
                        timeMax=end.isoformat(),
                        singleEvents=True,
                        orderBy="startTime",
                        maxResults=250,
                        pageToken=page,
                    )
                    .execute()
                )
                items += r.get("items", [])
                page = r.get("nextPageToken")
                if not page:
                    break
        except Exception:
            failed.append(name)
            continue

        for ev in items:
            if ev.get("status") == "cancelled" or ev.get("eventType") == "workingLocation":
                continue
            me = next((a for a in ev.get("attendees", []) if a.get("self")), None)
            response = me.get("responseStatus", "accepted") if me else "accepted"
            if response == "declined":
                continue
            s, e = ev["start"], ev["end"]
            link = ev.get("htmlLink")
            events.append(
                {
                    "uid": ev.get("iCalUID", ev["id"]),
                    "summary": ev.get("summary", "(No title)"),
                    "start": s.get("dateTime") or s["date"],
                    "end": e.get("dateTime") or e["date"],
                    "all_day": "date" in s,
                    "tentative": response in ("tentative", "needsAction"),
                    "color": palette.get(ev.get("colorId"), {}).get("background")
                    or cal.get("backgroundColor", "#4285f4"),
                    "calendar": name,
                    "account": email,
                    # authuser opens the event in the right account when the
                    # browser is signed in to several.
                    "link": f"{link}&authuser={email}" if link else None,
                    "join": join_url(ev),
                    "location": ev.get("location", ""),
                }
            )
    return events, failed


def fetch_all(old_cache):
    from google.auth.exceptions import RefreshError

    old = old_cache or {}
    now = dt.datetime.now().astimezone().isoformat()
    merged, failed, status = [], [], {}
    for email in active_accounts():
        try:
            events, cal_failed = fetch_account(email)
            status[email] = {"state": "ok"}
            failed += cal_failed
        except RefreshError:
            status[email] = {"state": "auth"}
            events = [e for e in old.get("events", []) if e.get("account") == email]
        except Exception as e:
            # HttpError.reason is Google's message; otherwise e.g. a network error.
            status[email] = {"state": "error", "error": getattr(e, "reason", None) or f"{type(e).__name__}: {e}"}
            # Keep showing this account's last known events until it recovers.
            events = [e for e in old.get("events", []) if e.get("account") == email]
        merged += events

    # The same event often shows up in several calendars or accounts, sometimes
    # as separate copies with different ids. Treat same title + same times as
    # the same event too, and prefer the copy that has a meeting link.
    seen, events = set(), []
    for e in sorted(merged, key=lambda e: not e["join"]):
        keys = {(e.get("uid"), e["start"]), (clean(e["summary"]).lower(), e["start"], e["end"])}
        if keys & seen:
            continue
        seen |= keys
        events.append(e)

    any_ok = any(s["state"] == "ok" for s in status.values())
    return {
        # Only move the sync time forward when something was actually fetched,
        # so a fully failed run is retried on the next render.
        "fetched_at": now if any_ok or not old.get("fetched_at") else old["fetched_at"],
        "events": events,
        "failed": failed,
        "accounts": status,
    }


# --- rendering ---------------------------------------------------------------


def clean(text):
    # SwiftBar treats " | " as the start of parameters and leading "-" as menu nesting.
    return " ".join(str(text).split()).replace("|", "∣").lstrip("-") or "(No title)"


def short(text, n=TITLE_MAX):
    text = clean(text)
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def hm(t):
    return t.strftime("%-I:%M %p")


def delta(td):
    mins = max(1, round(td.total_seconds() / 60))
    if mins < 60:
        return f"{mins}m"
    h, m = divmod(mins, 60)
    return f"{h}h {m}m" if m else f"{h}h"


def parse(ev):
    ev = dict(ev)
    if ev["all_day"]:
        ev["start"] = dt.date.fromisoformat(ev["start"])
        ev["end"] = dt.date.fromisoformat(ev["end"])
    else:
        ev["start"] = dt.datetime.fromisoformat(ev["start"]).astimezone()
        ev["end"] = dt.datetime.fromisoformat(ev["end"]).astimezone()
    return ev


@functools.cache
def pill_png(color, filled, w=5, h=16, stroke=1.5, scale=2):
    """Base64 PNG of a rounded bar, w x h points, drawn at 2x for Retina.

    SwiftBar shows SF Symbols as monochrome, so colored bars are drawn here.
    The PNG's 144 dpi tag makes macOS treat it as w x h points, not pixels.
    """
    W, H = w * scale, h * scale
    r = W / 2
    inner = r - stroke * scale
    rgb = bytes.fromhex(color.lstrip("#")[:6])
    rows = []
    for y in range(H):
        row = bytearray([0])  # PNG filter: none
        for x in range(W):
            hits = 0
            for sy in range(4):
                for sx in range(4):
                    px, py = x + (sx + 0.5) / 4, y + (sy + 0.5) / 4
                    # Distance from the centre line of the pill.
                    d = math.hypot(px - r, py - min(max(py, r), H - r))
                    if d <= r and (filled or d > inner):
                        hits += 1
            row += rgb + bytes([round(255 * hits / 16)])
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    ppm = round(72 * scale / 0.0254)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
        + chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )
    return base64.b64encode(png).decode()


def bar(ev):
    # Filled bar = there's a meeting link to join; outline = no video call.
    return f"image={pill_png(ev['color'], bool(ev['join']))}"


def header(text):
    print(f"{text} | size=12 color={GRAY}")


def event_item(ev, label, show_account):
    # No `color=` here: SwiftBar drops the image on lines that set a text color.
    # The href keeps the item enabled: SwiftBar 2.1's in-place menu updates can
    # leave a submenu-only item disabled. Clicking it joins the call, or opens the event.
    target = ev["join"] or ev["link"]
    print(f"{label} · {clean(ev['summary'])} | {bar(ev)}" + (f" href={target}" if target else ""))
    where = clean(ev["calendar"])
    if show_account and ev.get("account") and ev["account"] != ev["calendar"]:
        where += f" ({ev['account']})"
    if ev["all_day"]:
        print(f"--{where} | color={GRAY}")
    else:
        print(f"--{hm(ev['start'])} – {hm(ev['end'])} · {where} | color={GRAY}")
    if ev["location"] and not ev["location"].startswith("https://"):
        print(f"--{clean(ev['location'])} | sfimage=mappin.and.ellipse color={GRAY}")
    if ev["join"]:
        print(f"--Join meeting | href={ev['join']} sfimage=video")
    if ev["link"]:
        print(f"--Open in Google Calendar | href={ev['link']} sfimage=calendar")


def render(cache, error=None):
    now = dt.datetime.now().astimezone()
    today, tomorrow = now.date(), now.date() + dt.timedelta(days=1)
    lookahead = dt.timedelta(minutes=settings()["lookahead_minutes"])
    signed_in = accounts()
    active = active_accounts()
    account_status = (cache or {}).get("accounts", {})
    problems = {a: s for a, s in account_status.items() if a in active and s["state"] != "ok"}

    colors = account_colors(signed_in)
    events = [parse(e) for e in (cache or {}).get("events", []) if e.get("account") in active]
    for e in events:
        e["color"] = colors.get(e["account"], e["color"])
    timed = sorted((e for e in events if not e["all_day"]), key=lambda e: e["start"])
    all_day = [e for e in events if e["all_day"]]

    ongoing = [e for e in timed if e["start"] <= now < e["end"]]
    upcoming = [e for e in timed if e["start"] > now]
    nxt = [e for e in upcoming if e["start"] == upcoming[0]["start"]] if upcoming else []
    show_account = len(active) > 1

    # Menu bar title
    if nxt and nxt[0]["start"] - now <= lookahead:
        e = nxt[0]
        print(f"{short(e['summary'])} in {delta(e['start'] - now)} | {bar(e)}")
    elif ongoing:
        e = min(ongoing, key=lambda e: e["end"])
        print(f"{short(e['summary'])} · {delta(e['end'] - now)} left | {bar(e)}")
    elif problems or error or not signed_in:
        print(" | sfimage=calendar.badge.exclamationmark")
    else:
        print(" | sfimage=calendar")
    print("---")

    if not signed_in:
        print(f"Sign in to Google Calendar | bash=\"{SELF}\" param1=auth terminal=false sfimage=person.crop.circle.badge.plus")
        print("---")
    if error:
        print(f"Couldn't load events | color={GRAY} sfimage=exclamationmark.triangle")
        print(f"{short(error, 90)} | size=11 color={GRAY} tooltip={clean(error)}")
        print("---")
    for email, s in problems.items():
        if s["state"] == "auth":
            print(f"Sign in again: {email} | bash=\"{SELF}\" param1=auth terminal=false sfimage=person.crop.circle.badge.exclamationmark")
        else:
            print(f"Couldn't load {email} | color={GRAY} sfimage=exclamationmark.triangle")
            print(f"{short(s.get('error', ''), 90)} | size=11 color={GRAY} tooltip={clean(s.get('error', ''))}")
    for name in (cache or {}).get("failed", []):
        print(f"Couldn't load {clean(name)} | color={GRAY} sfimage=exclamationmark.triangle")
    if problems or (cache or {}).get("failed"):
        print("---")

    if ongoing:
        header("Now")
        for e in ongoing:
            event_item(e, f"until {hm(e['end'])}", show_account)

    if nxt:
        header(f"Upcoming in {delta(nxt[0]['start'] - now)}")
        for e in nxt:
            event_item(e, hm(e["start"]), show_account)

    rest_today = [e for e in upcoming if e["start"].date() == today and e not in nxt]
    today_all_day = [e for e in all_day if e["start"] <= today < e["end"]]
    header("Today")
    for e in today_all_day:
        event_item(e, "All day", show_account)
    for e in rest_today:
        event_item(e, hm(e["start"]), show_account)
    if signed_in and not active:
        print(f"All accounts are hidden | color={GRAY}")
    elif not (rest_today or today_all_day or (nxt and nxt[0]["start"].date() == today)):
        print(f"No more events today | color={GRAY}")

    rest_tomorrow = [e for e in upcoming if e["start"].date() == tomorrow and e not in nxt]
    tomorrow_all_day = [e for e in all_day if e["start"] <= tomorrow < e["end"]]
    if rest_tomorrow or tomorrow_all_day:
        header("Tomorrow")
        for e in tomorrow_all_day:
            event_item(e, "All day", show_account)
        for e in rest_tomorrow:
            event_item(e, hm(e["start"]), show_account)

    print("---")
    print("Accounts | sfimage=person.2")
    for email in signed_in:
        shown = email in active
        print(
            f"--{email} | checked={str(shown).lower()} image={pill_png(colors[email], True, w=8, h=8)}"
            + ("" if shown else f" color={GRAY}")
        )
        print(f"----Open in Google Calendar | href=https://calendar.google.com/calendar/r?authuser={email} sfimage=calendar")
        print(f"----Show events | bash=\"{SELF}\" param1=toggle param2=\"{email}\" terminal=false checked={str(shown).lower()}")
        print(f"----Remove account | bash=\"{SELF}\" param1=remove param2=\"{email}\" terminal=false")
    print(f"--Add account… | bash=\"{SELF}\" param1=auth terminal=false sfimage=plus")
    print(f"Refresh | bash=\"{SELF}\" param1=refresh terminal=false")
    if cache:
        synced = dt.datetime.fromisoformat(cache["fetched_at"]).astimezone()
        print(f"Synced {hm(synced)} | size=11 color={GRAY}")


def render_setup():
    print(" | sfimage=calendar.badge.exclamationmark")
    print("---")
    print("Calendar setup needed")
    print(f"Save an OAuth Desktop client as {CREDS} | size=12 color={GRAY}")
    print("Open Google Cloud clients page | href=https://console.cloud.google.com/auth/clients")
    print(f"Open config folder | bash=/usr/bin/open param1=\"{CONFIG_DIR}\" terminal=false")


# --- main ----------------------------------------------------------------------


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    action = sys.argv[1] if len(sys.argv) > 1 else None

    if action == "auth":
        auth()
        swiftbar_refresh()
        return
    if action == "remove":
        remove(sys.argv[2])
        swiftbar_refresh()
        return
    if action == "toggle":
        toggle(sys.argv[2])
        swiftbar_refresh()
        return
    if action == "refresh":
        CACHE.write_text(json.dumps(fetch_all(load_json(CACHE, None))))
        swiftbar_refresh()
        return

    if not CREDS.exists():
        render_setup()
        return

    cache = load_json(CACHE, None)
    error = None
    if active_accounts():
        fetched_at = dt.datetime.fromisoformat(cache["fetched_at"]).astimezone() if cache else None
        stale = (
            fetched_at is None
            or (dt.datetime.now().astimezone() - fetched_at).total_seconds() > FETCH_EVERY
            or fetched_at.date() != dt.date.today()
            or set(cache.get("accounts", {})) != set(active_accounts())
        )
        if stale:
            try:
                cache = fetch_all(cache)
                CACHE.write_text(json.dumps(cache))
            except Exception as e:
                error = f"{type(e).__name__}: {e}"

    render(cache, error)


if __name__ == "__main__":
    main()
