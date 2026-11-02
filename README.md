# menubar-calendar

A [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin that shows upcoming Google Calendar events in the macOS menu bar, in the style of Notion Calendar's menu bar item.

- Next event with a countdown in the menu bar; today's and tomorrow's events in the dropdown
- Multiple Google accounts, each with its own color; hide or show an account's events
- Filled bar = event has a video meeting link (with a "Join meeting" item); outlined = no link
- Read-only access (`calendar.readonly`); tokens and cache stay in `~/.config/menubar-calendar/`

The repo also hosts the app's [home page](https://kjastram.github.io/menubar-calendar/) and [privacy policy](https://kjastram.github.io/menubar-calendar/privacy.html) for Google's OAuth consent screen.

## Setup

1. Create a Google Cloud project, enable the Google Calendar API, and create an OAuth client of type **Desktop app**.
2. Save the client JSON as `~/.config/menubar-calendar/credentials.json`.
3. Link the plugin into SwiftBar's plugin folder:
   `ln -s "$PWD/calendar.1m.py" ~/Library/Application\ Support/SwiftBar/plugins/`
4. Click the menu bar icon → **Sign in to Google Calendar**. Add more accounts under **Accounts → Add account…**.

The script runs through [uv](https://docs.astral.sh/uv/), which installs its Python dependencies on first run. Adjust the `uv` path in the first line if yours differs.

Optional settings go in `~/.config/menubar-calendar/config.json`:

```json
{
  "exclude": ["Holidays in Germany"],
  "lookahead_minutes": 60,
  "hidden_accounts": ["work@example.com"],
  "account_colors": {"work@example.com": "#4f8ff7"}
}
```
