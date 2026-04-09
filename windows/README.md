# InstaArchive for Windows

A Windows port of [InstaArchive](../README.md) — an app for archiving Instagram profiles. Available in two modes:

1. **Tray mode** (lightweight) — system tray icon + browser dashboard at `http://localhost:8485`
2. **Desktop UI mode** — native PyQt6 window with sidebar, profile list, media grid, settings, and embedded Instagram login

![Windows](https://img.shields.io/badge/Windows-10%2F11-blue) ![ARM64](https://img.shields.io/badge/ARM64-supported-green) ![Python](https://img.shields.io/badge/Python-3.11%2B-yellow) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

All core features from the macOS version:

- **Full profile downloads** — posts, reels, videos, stories, highlights, profile pictures
- **Concurrent downloads** — multiple profiles and files simultaneously (configurable)
- **Duplicate detection** — O(1) set-based index, skips already-downloaded media
- **File validation** — detects missing files and re-downloads them
- **Background scheduling** — automatic periodic checks (hourly to weekly)
- **Password protection** — optional login for the web interface
- **Export/Import** — save and load your profile list as JSON
- **Per-profile stats** — media counts by type, storage usage, last checked time

### Desktop UI mode (new)
- **Native dark-themed window** — sidebar with profile management, stat cards, media grid
- **Embedded Instagram login** — log in directly inside the app (via PyQt6 WebEngine)
- **Settings panel** — configure all options without touching JSON files
- **Profile detail view** — click any profile for stats, media thumbnails, sync controls
- **Stop/skip controls** — stop all downloads or skip individual profiles

### Tray mode
- **System tray icon** — lives in the Windows taskbar tray; right-click for quick controls
- **Web dashboard** — full management UI in any browser at `http://localhost:8485`

## Quick Start

### Option A — Portable `.exe`

> Pre-built `.exe` files are available on the [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases) page.

1. Download `InstaArchive.exe`
2. Double-click to run
3. Add Instagram profiles and start archiving

### Option B — Run from source

**Requirements:** Python 3.11 or later

```bash
# 1. Clone the repo
git clone https://github.com/eMacTh3Creator/InstaArchive.git
cd InstaArchive/windows

# 2. Install dependencies
pip install -r requirements.txt

# 3a. Run tray mode (browser UI)
python src/main.py

# 3b. Run desktop UI mode (native window)
python src/ui.py
```

## Building the `.exe`

Requires Python 3.11+ and all dependencies installed.

```bat
REM Tray-only version (lightweight, browser UI)
build.bat

REM Native desktop UI version (PyQt6 window)
build.bat ui
```

Output: `dist\InstaArchive.exe`

**ARM64 builds:** Run `build.bat` on an ARM64 Windows machine with ARM64 Python. PyInstaller auto-produces a native ARM64 executable.

### Building the installer

After building:

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php)
2. Open `installer.iss` in Inno Setup
3. Click **Compile** (F9)
4. Output: `dist/installer/InstaArchive-Setup-1.0.0.exe`

## Instagram Authentication

### Desktop UI mode
1. Click **Log In to Instagram** in the sidebar
2. A browser window opens inside the app — log in normally
3. Session cookies are captured automatically

### Tray mode
1. Open `http://localhost:8485`
2. Go to Settings and log in
3. Cookies are saved to `%APPDATA%\InstaArchive\cookies.json`

Your credentials are sent directly to Instagram — InstaArchive never sees your password.

## Configuration

Settings are stored in `%APPDATA%\InstaArchive\settings.json` and editable via the Settings panel (desktop UI) or web dashboard.

| Key | Default | Description |
|-----|---------|-------------|
| `download_path` | `%USERPROFILE%\Pictures\InstaArchive` | Where media is saved |
| `check_interval_hours` | `24` | Scheduled check interval |
| `download_posts` | `true` | Download photo posts |
| `download_reels` | `true` | Download reels |
| `download_videos` | `true` | Download IGTV videos |
| `download_highlights` | `true` | Download story highlights |
| `download_stories` | `false` | Download active stories |
| `max_concurrent_profiles` | `3` | Profiles downloaded in parallel |
| `max_concurrent_files` | `6` | Files downloaded in parallel per profile |
| `web_server_enabled` | `true` | Enable/disable the web interface |
| `web_server_port` | `8485` | Port for the web interface |
| `web_server_password` | `""` | Set to require login (blank = no auth) |

## Project Structure

```
windows/
├── src/
│   ├── main.py              # Entry point — tray mode (wires all backend components)
│   ├── ui.py                # Entry point — desktop UI mode (PyQt6 native window)
│   ├── app_settings.py      # Settings persistence (%APPDATA%/InstaArchive/)
│   ├── profile_store.py     # Profile list (add/remove/export/import)
│   ├── instagram_service.py # Instagram API (v1, GraphQL, HTML scraping)
│   ├── storage_manager.py   # File I/O, directory management, media index
│   ├── download_manager.py  # Concurrent downloads with stop/skip
│   ├── thumbnail_cache.py   # 3-tier thumbnail cache (memory/disk/Pillow)
│   ├── scheduler.py         # APScheduler background check scheduling
│   ├── web_server.py        # Flask API + embedded dark-themed HTML/JS UI
│   └── tray_app.py          # pystray Windows system tray icon
├── requirements.txt         # Python dependencies
├── InstaArchive.spec        # PyInstaller spec — tray mode
├── InstaArchiveUI.spec      # PyInstaller spec — desktop UI mode
├── version_info.txt         # Windows executable version metadata
├── build.bat                # Build script (supports: build.bat / build.bat ui)
├── installer.iss            # Inno Setup installer script
└── README.md
```

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Web dashboard |
| `GET` | `/login` | Login page (if password set) |
| `POST` | `/api/login` | Authenticate `{"password": "..."}` |
| `POST` | `/api/logout` | Clear session |
| `GET` | `/api/profiles` | List all profiles |
| `POST` | `/api/profiles` | Add profile `{"username": "..."}` |
| `DELETE` | `/api/profiles/{username}` | Remove profile |
| `GET` | `/api/profile/{username}` | Profile detail + stats |
| `GET` | `/api/status` | App status (downloading, counts) |
| `POST` | `/api/sync/all` | Start sync for all profiles |
| `POST` | `/api/sync/{username}` | Start sync for one profile |
| `POST` | `/api/stop` | Stop all active downloads |
| `POST` | `/api/skip/{username}` | Skip a specific profile |
| `GET` | `/api/settings` | Get current settings |
| `POST` | `/api/settings` | Update settings |
| `GET` | `/api/export` | Download profiles as JSON |

## Dependencies

| Package | Purpose |
|---------|---------|
| `requests` | HTTP client for Instagram API |
| `flask` | Web server for the dashboard |
| `pillow` | Thumbnail generation |
| `pystray` | Windows system tray icon |
| `APScheduler` | Background check scheduling |
| `PyQt6` | Native desktop UI (optional — only for UI mode) |
| `PyQt6-WebEngine` | Embedded Instagram login browser (optional) |
| `pyinstaller` | Build tool — creates standalone `.exe` |

## License

MIT License. See [LICENSE](../LICENSE) for details.

## Disclaimer

For personal archiving only. Respect Instagram's Terms of Service and the privacy of content creators.
