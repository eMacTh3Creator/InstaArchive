# InstaArchive for Windows

A Windows port of [InstaArchive](../InstaArchive-v2/README.md) — a background app for archiving Instagram profiles. Runs as a **system tray icon** and serves a **browser-based dashboard** on `http://localhost:8485`.

![Windows](https://img.shields.io/badge/Windows-10%2F11-blue) ![Python](https://img.shields.io/badge/Python-3.11%2B-yellow) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

All core features from the macOS version, delivered via a browser UI:

- **Full profile downloads** — posts, reels, videos, stories, highlights, profile pictures
- **Concurrent downloads** — multiple profiles and files simultaneously (configurable)
- **Duplicate detection** — O(1) set-based index, skips already-downloaded media
- **File validation** — detects missing files and re-downloads them
- **Background scheduling** — automatic periodic checks (hourly to weekly)
- **System tray icon** — lives in the Windows taskbar tray; right-click for quick controls
- **Web dashboard** — full management UI in any browser at `http://localhost:8485`
- **Password protection** — optional login for the web interface
- **Export/Import** — save and load your profile list as JSON
- **Per-profile stats** — media counts by type, storage usage, last checked time
- **Sync controls** — trigger sync for one profile or all profiles from the browser

## Quick Start

### Option A — Portable `.exe` (recommended)

> A pre-built `.exe` is available on the [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases) page once built.

1. Download `InstaArchive.exe`
2. Double-click to run — a tray icon appears and your browser opens the dashboard
3. Add Instagram profiles and start archiving

### Option B — Run from source

**Requirements:** Python 3.11 or later

```bash
# 1. Clone the repo
git clone https://github.com/eMacTh3Creator/InstaArchive.git
cd InstaArchive/windows

# 2. Install dependencies
pip install -r requirements.txt

# 3. Run
python src/main.py
```

Your browser will open `http://localhost:8485` automatically.

## Building the `.exe`

Requires Python 3.11+ and all dependencies installed.

```bat
build.bat
```

This runs PyInstaller and produces `dist/InstaArchive.exe` — a single portable executable with no Python installation required.

### Building the installer

After running `build.bat`:

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php)
2. Open `installer.iss` in Inno Setup
3. Click **Compile** (or press F9)
4. The installer appears at `dist/installer/InstaArchive-Setup-1.0.0.exe`

The installer adds InstaArchive to the Start Menu, optionally creates a desktop shortcut, and registers an optional startup entry.

## Instagram Authentication

InstaArchive needs your Instagram session cookies to download private content and avoid rate limiting.

**To log in:**
1. Open the dashboard at `http://localhost:8485`
2. Click **Settings → Log In to Instagram**
3. A browser window opens — log in to Instagram normally
4. Cookies are saved to `%APPDATA%\InstaArchive\cookies.json`

Your credentials are sent directly to Instagram — InstaArchive never sees your password.

## Web Dashboard

The dashboard is available at `http://localhost:8485` (or your configured port).

### Pages

| Page | Description |
|------|-------------|
| Dashboard | Status stats, add profile form, profile list |
| Profile Detail | Click any profile row for stats, media breakdown, sync/remove buttons |

### Keyboard flows

- Paste a username, `@handle`, or full `https://www.instagram.com/username/` URL into the Add field
- Press Enter or click **Add**

## Configuration

Settings are stored in `%APPDATA%\InstaArchive\settings.json`.

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
│   ├── main.py              # Entry point — wires all components
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
├── InstaArchive.spec        # PyInstaller build configuration
├── version_info.txt         # Windows executable version metadata
├── build.bat                # One-click build script
├── installer.iss            # Inno Setup installer script
└── README.md
```

## API Reference

The same REST API as the macOS version:

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
| `GET` | `/api/settings` | Get current settings |
| `POST` | `/api/settings` | Update settings |
| `GET` | `/api/export` | Download profiles as JSON |

## Dependencies

| Package | Purpose |
|---------|---------|
| `requests` | HTTP client for Instagram API calls |
| `flask` | Web server for the dashboard |
| `pillow` | Thumbnail generation |
| `pystray` | Windows system tray icon |
| `APScheduler` | Background check scheduling |
| `pyinstaller` | Build tool — creates standalone `.exe` |

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

For personal archiving only. Respect Instagram's Terms of Service and the privacy of content creators.
