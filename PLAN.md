# Build plan: native macOS calendar app (v1)

A small native calendar for macOS that talks to the Google Calendar API directly. A SwiftUI app with a month view, a day panel and a create/edit form, plus a menu bar popover that replaces the SwiftBar plugin in this repo. No EventKit. Built so a todo app with its own database can plug in later.

Designs (hi-fi mockups and wireframes): [Calendar App Design canvas](https://claude.ai/artifact/JGB3XYQFndp4g7FHX4TRw4). This file is a copy of its "Build plan" board, plus a section on how the app works with the existing plugin.

**Summary:** macOS 14+ · Swift 6 / SwiftUI · Google Calendar API v3 · SQLite cache (GRDB) · MVP about 5–7 working days.

## Scope

### In v1

- Several Google accounts, each with a color; show or hide each calendar
- Month grid, mini month, day panel with event details
- Create, edit and delete single events; quick add from a sentence
- Optional Google Meet link when creating; Join button when one exists
- Menu bar item with next-event countdown and a today/tomorrow popover
- Local cache: opens instantly, works read-only offline
- Search, keyboard shortcuts, launch at login

### Not in v1 (on purpose)

- Week and day timeline views, drag to move or resize
- Editing recurring events (shows "Edit in Google Calendar" instead)
- Inviting guests, RSVP, notifications
- Offline writes (create/edit needs a connection)
- iCloud, Outlook or other sources
- Todo integration (phase 7, but the code leaves room for it now)

## Stack

| Part | Choice | Why |
|---|---|---|
| UI | SwiftUI, macOS 14+, `@Observable` | Native look, small code. 14 gives `@Observable` and good window APIs. |
| Menu bar | `MenuBarExtra` with `.window` style, same app | One process for the main window and the popover. Text label for the countdown. |
| Sign-in | AppAuth-iOS, Google "Desktop app" client, loopback redirect + PKCE | Google's recommended flow for installed apps. One auth state per account, so several accounts work. GoogleSignIn handles only one user. |
| Token storage | Keychain (Security framework, small wrapper) | Replaces the plugin's JSON token files. |
| API client | `URLSession` + `Codable`, in an `actor` | No maintained Swift client exists. Only about 7 endpoints are needed. |
| Local cache | SQLite via GRDB | A plain SQLite file with a schema you control. A future todo app or backend can use the same tables or migration SQL. SwiftData's store format is opaque. |
| Scope | `calendar.events` + `calendar.readonly` | Read calendars, write events. No access to sharing settings or deleting calendars. |
| Distribution | SwiftPM (no Xcode): `macos/scripts/build-app.sh` builds and bundles `Almanac.app`, signed with a local self-signed certificate from `macos/scripts/make-signing-cert.sh` | No notarization for your own Mac. Stable signing keeps the Keychain from prompting on every rebuild. |

## How it fits together

- **Views:** MonthView · MiniMonth · DayInspector · EventForm (new and edit) · MenuBarPopover · SettingsWindow
- **State (`@MainActor @Observable`):** CalendarStore holds the selected month and day, visible calendars, and items for the visible range (read from the cache, updated when it changes)
- **AuthService:** add or remove an account, refresh tokens, mark an account "needs sign-in"
- **ItemSource protocol:** `GoogleCalendarSource` now, `TodoSource` later. Each fetches a date range and creates, updates and deletes its own items.
- **SyncEngine (actor):** polls every 2 min and when the window gets focus. Applies changes to the cache and retries with backoff.
- **SQLite cache:** `accounts` · `calendars` · `events` · `sync_state` (later: `tasks`)
- **Keychain:** one saved auth state per Google account

## Data model

- `accounts`: id, email, color, status
- `calendars`: id, account_id, google_id, name, color, access_role, visible
- `events`: id, calendar_id, google_id, etag, title, start_at, end_at, all_day, location, notes, meet_url, recurring_event_id, status, updated_at
- `sync_state`: calendar_id, sync_token, last_full_sync
- Every row is keyed by `(source, external_id)`, so tasks can join later without a schema rewrite.

## Sync rules

- First run: `events.list` with `singleEvents=true` from 3 months back to 12 months ahead, then save `nextSyncToken`.
- After that: send only `syncToken`. `timeMin`, `timeMax` and `orderBy` are not allowed with it.
- An event with `status: cancelled` means delete it from the cache. A `410 Gone` means clear that calendar and sync it fully again.
- All-day events use `start.date`, and the end date is exclusive. Timed events use `dateTime`.
- Writes show up right away, then get confirmed by the API. On an error, roll back and show a message.

## Working with the SwiftBar plugin

The app replaces `calendar.1m.py`, so it should match what the plugin already does and take over its settings.

### Behavior to carry over from the plugin

These are in `fetch_account`, `fetch_all` and `join_url` in `calendar.1m.py`:

- **Which calendars show by default:** only calendars where `calendarList` has `selected: true` (the checkbox in Google Calendar's sidebar). Use it as the initial `calendars.visible` value.
- **Skipped events:** `status: cancelled`, `eventType: workingLocation`, and events where your own attendee entry (`self: true`) has `responseStatus: declined`.
- **Tentative events:** `tentative` or `needsAction` responses are shown, but marked as not confirmed.
- **Event color:** `colorId` looked up in `colors.get` (event palette), falling back to the calendar's `backgroundColor`. In the menu bar, the account color is used instead.
- **Meeting link:** `hangoutLink`, then the `video` entry in `conferenceData.entryPoints`, then a `location` that starts with `https://`. Store the result as `meet_url`.
- **Duplicates:** the same event often shows up in several calendars or accounts. Treat events as the same if they share `iCalUID` + start, or the same cleaned-up title + start + end. Keep the copy that has a meeting link. Do this when building the visible list, not in the cache, so each calendar still syncs on its own.
- **Event links:** append `&authuser=<email>` to `htmlLink` so "Open in Google Calendar" opens the right account.
- **Account email:** read from `calendars.get("primary").id`, which is the account's email.
- **Sign-in prompt:** use `prompt=select_account consent` so Google shows the account picker instead of reusing whichever account the browser is signed in to.
- **Remove account:** revoke the refresh token at `https://oauth2.googleapis.com/revoke` (best effort), then delete it locally.
- **Errors per account:** a failed refresh marks only that account "needs sign-in"; other errors show a message for that account. In both cases keep showing that account's cached events.
- **Menu bar title:** next event with a countdown if it starts within `lookahead_minutes` (default 60); otherwise the ongoing event with time left; otherwise just the icon, with a warning badge when an account has a problem.

### Settings to import on first run

Read `~/.config/menubar-calendar/config.json` (or `$MENUBAR_CAL_DIR`) if it exists:

| Plugin setting | App setting |
|---|---|
| `account_colors` | `accounts.color` (same palette, same order for new accounts) |
| `hidden_accounts` | account hidden in settings |
| `exclude` (calendar names or IDs) | `calendars.visible = false` for matching calendars |
| `lookahead_minutes` | menu bar countdown lookahead |

### Sign-in and tokens

- Reuse the same Google Cloud project and Desktop OAuth client as the plugin. Add the `calendar.events` scope to the consent screen.
- The plugin's tokens only have `calendar.readonly` and can't be reused for writes, so each account signs in once in the app. Don't try to import `accounts/*.json`.
- While both run (phases 1–4), each has its own tokens. That's fine; Google allows several refresh tokens per client and account. Both polling (plugin every 5 min, app every 2 min) stays far below API limits.

### Switching over (end of phase 5)

1. Check the app's menu bar shows the same events as the plugin for a day or two.
2. Remove the symlink from SwiftBar's plugin folder.
3. Remove the plugin's accounts from SwiftBar's Accounts menu first if you want their grants revoked; otherwise leave them in place.
4. Keep `calendar.1m.py` in the repo as a fallback until you're sure.

## Phases

| # | Phase | Done when | Est. |
|---|---|---|---|
| 0 | Project setup: Xcode project, Personal Team signing, OAuth client; consent screen switched to "In production" (unverified is fine); add `calendar.events` scope | App builds and runs; client ID in a gitignored config file | ½ day |
| 1 | Sign-in and accounts: AppAuth loopback flow, Keychain, add/remove accounts, refresh tokens, import plugin `config.json` | Two accounts signed in, with the plugin's colors; still signed in after a relaunch and after 8+ days | 1 day |
| 2 | Read path: calendarList, events sync, GRDB cache, CalendarStore, plugin's filtering and duplicate rules | Events for the visible month load from the cache, match what the plugin shows, and changes made on the web show up within 2 min | 1–1½ days |
| 3 | Month UI: grid, mini month, day panel, details, show/hide calendars, search | Matches the hi-fi board; keyboard navigation works | 1½ days |
| 4 | Write path: new event form, quick add, edit, delete, Meet link | Create, edit and delete in the app show up on calendar.google.com | 1 day |
| 5 | Menu bar and settings: MenuBarExtra countdown, popover, settings window, launch at login | SwiftBar plugin turned off; nothing lost | 1 day |
| 6 | Later: week view, recurring edits ("this / all future"), notifications | Pick what you miss after a few weeks of use | 1–2 wks |
| 7 | Later: todo integration | Tasks show on days and can be linked to events | 2–4 days |

## Room for the todo app

What the code does now so phase 7 is mostly adding code, not reworking it:

- Views draw a `CalendarItem` (an event or a task), not a Google event type.
- `ItemSource` protocol: the todo app becomes a second source with its own fetch and write calls.
- The app talks to the todo database through a small HTTP API you own, never by connecting straight to Postgres. That keeps database credentials out of the app.
- To link a task to an event, store the task ID in the Google event's `extendedProperties.private`. No extra table is needed on the Google side.
- The cache gets a `tasks` table with the same `(source, external_id)` key.
- The UI already has room for it: a Tasks section in the day panel and an Integrations tab in settings.

## Risks

- **Refresh tokens expire after 7 days** if the OAuth consent screen stays in "Testing". Switch it to production in phase 0. (This applies to the plugin's tokens too.)
- **Recurring events** are the hard part of editing, which is why they're left out of v1.
- **MenuBarExtra limits:** you can't open or close it from code, and it doesn't reliably tell you when it opens. Refresh on a timer, and add MenuBarExtraAccess if needed.
- **Time zones and all-day events:** test events that cross midnight and the exclusive end date.
- **Keychain prompts** if the signing identity changes between builds.
- **Duplicate rule hides real events:** two different events with the same title and times get merged. The plugin accepts this; keep it, but only for display.

## Look

Neutral off-white ground, one dark ink color for today and primary buttons (no red), Inter for text and Space Grotesk for headings. Account colors carry over from the plugin. All-day events are tinted chips; timed events are a dot, a time and a title. Filled vs outlined bar for "has a meeting link" carries over from the plugin. Thin dividers, no shadows, no gradients. The aim is Apple's calmness, not its look.

## Decisions

- Name: Almanac, bundle ID `com.kjastram.almanac`
- Week start: follows the system setting (`Calendar.current.firstWeekday`)
- Dock icon only while the main window is open; otherwise menu bar only
- Code lives in `macos/` in this repo
- Built with SwiftPM, since Xcode isn't installed. Tests run with `macos/scripts/test.sh`.
