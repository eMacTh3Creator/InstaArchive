# InstaArchive

Archive Instagram profiles automatically — posts, reels, stories, highlights, and profile pictures. Available for **macOS** (native SwiftUI app) and **Windows** (portable `.exe` + installer).

![macOS](https://img.shields.io/badge/macOS-13.0+-blue) ![Windows](https://img.shields.io/badge/Windows-10%2F11-blue) ![ARM64](https://img.shields.io/badge/ARM64-supported-green) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Platform Downloads

| Platform | Download | Requirements |
|----------|----------|-------------|
| **macOS** | Build from source (Xcode) | macOS 13.0+, Xcode 15+ |
| **Windows x64** | [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases) | Windows 10/11 |
| **Windows ARM64** | [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases) | Windows 10/11 ARM (Surface Pro X, Copilot+ PCs) |

---

## Features

Both versions share the same core feature set:

- **Full profile downloads** — posts, reels, IGTV videos, stories, highlights, profile pictures
- **Concurrent downloads** — multiple profiles and files simultaneously (configurable)
- **Duplicate detection** — O(1) set-based index, never downloads the same file twice
- **File validation** — detects missing files and re-downloads them automatically
- **Background scheduling** — automatic periodic checks from hourly to weekly
- **Web dashboard** — browser-based management UI at `http://localhost:8485`
- **Password protection** — optional login for the web interface
- **Export/Import** — save and load your profile list as JSON
- **Per-profile stats** — media counts by type, storage usage, last checked time
- **Sync controls** — trigger sync for one profile or all at once

---

## macOS

A native SwiftUI app with menu bar extra, full macOS integration, and a built-in web interface.

📁 **Source:** [root of this repository](.) — open `InstaArchive.xcodeproj` in Xcode.

### Additional macOS-only features
- **Native SwiftUI UI** — full macOS app with sidebar, detail views, and media grid
- **Menu bar extra** — quick-access widget in the menu bar
- **macOS Notifications** — notified when new content is found
- **Launch at login** — via `SMAppService`
- **Built-in Instagram login** — WKWebView captures session cookies automatically
- **Open in Finder** — one-click access to downloaded media

### Quick Start (macOS)

```bash
git clone https://github.com/eMacTh3Creator/InstaArchive.git
cd InstaArchive
open InstaArchive.xcodeproj
```

Build and run with ⌘R. See the [macOS architecture](#macos-architecture) section below for full details.

---

## Windows

A Python-based port that runs as a **system tray icon** and serves the same browser dashboard at `http://localhost:8485`. Available as a portable single-file `.exe` or a proper Windows installer.

📁 **Source:** [`windows/`](windows/) directory of this repository.

### Quick Start (Windows)

**Option A — Portable `.exe` (recommended)**

1. Download `InstaArchive.exe` from [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases)
2. Double-click — a tray icon appears and your browser opens the dashboard
3. Add profiles and start archiving

**Option B — Installer**

1. Download `InstaArchive-Setup-1.0.0.exe` from [Releases](https://github.com/eMacTh3Creator/InstaArchive/releases)
2. Run the installer — adds InstaArchive to Start Menu, optional desktop shortcut and startup entry

**Option C — Run from source**

```bat
git clone https://github.com/eMacTh3Creator/InstaArchive.git
cd InstaArchive\windows
pip install -r requirements.txt
python src\main.py
```

### Building the Windows `.exe`

Requires Python 3.11+ on Windows.

```bat
cd windows
build.bat
```

Produces `windows\dist\InstaArchive.exe` — a single portable executable with no Python required.

**ARM64 builds:** run `build.bat` on an ARM64 Windows machine with ARM64 Python installed. PyInstaller automatically produces a native ARM64 executable.

See [`windows/README.md`](windows/README.md) for full Windows documentation.

---

## Configuration

Settings are identical across platforms:

| Key | Default | Description |
|-----|---------|-------------|
| `download_path` | Platform default¹ | Where media is saved |
| `check_interval_hours` | `24` | Scheduled check interval |
| `download_posts` | `true` | Download photo posts |
| `download_reels` | `true` | Download reels |
| `download_videos` | `true` | Download IGTV videos |
| `download_highlights` | `true` | Download story highlights |
| `download_stories` | `false` | Download active stories |
| `max_concurrent_profiles` | `3` | Profiles downloaded in parallel |
| `max_concurrent_files` | `6` | Files per profile in parallel |
| `web_server_port` | `8485` | Web dashboard port |
| `web_server_password` | `""` | Set to require login (blank = open) |

¹ macOS: `~/Pictures/InstaArchive` · Windows: `%USERPROFILE%\Pictures\InstaArchive`

---

## Web API

Both platforms expose the same REST API at `http://localhost:8485`:

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
| `POST` | `/api/sync/all` | Sync all profiles |
| `POST` | `/api/sync/{username}` | Sync one profile |
| `GET` | `/api/settings` | Get current settings |
| `POST` | `/api/settings` | Update settings |
| `GET` | `/api/export` | Download profiles as JSON |

---

## macOS Architecture

```
InstaArchive/                      ← macOS (SwiftUI)
├── InstaArchiveApp.swift          # App entry point, menus, focused values
├── Models/
│   ├── Profile.swift              # Profile data model + MediaType enum
│   ├── MediaItem.swift            # Downloaded media item model
│   ├── AppSettings.swift          # UserDefaults-backed settings
│   └── ProfileStore.swift         # Observable profile list
├── Views/
│   ├── ContentView.swift          # Main split view + HomeView
│   ├── SidebarView.swift          # Profile list with stop/skip controls
│   ├── ProfileDetailView.swift    # Media grid with async thumbnails
│   ├── AddProfileView.swift       # Add profile sheet
│   ├── SettingsView.swift         # Settings panel
│   ├── MenuBarView.swift          # Menu bar extra widget
│   ├── OnboardingView.swift       # First-run setup
│   └── InstagramLoginView.swift   # WKWebView Instagram login
├── Services/
│   ├── InstagramService.swift     # Instagram API (v1, GraphQL, HTML)
│   ├── DownloadManager.swift      # Concurrent download orchestration
│   ├── StorageManager.swift       # File I/O and persistence
│   ├── SchedulerService.swift     # Background scheduling
│   ├── ThumbnailCache.swift       # 3-tier thumbnail cache
│   └── WebServer.swift            # Built-in HTTP server + web UI
└── Utilities/
    └── LaunchAtLogin.swift        # SMAppService wrapper
```

## Windows Architecture

```
windows/                           ← Windows (Python)
├── src/
│   ├── main.py                    # Entry point — wires all components
│   ├── app_settings.py            # Settings (%APPDATA%\InstaArchive\)
│   ├── profile_store.py           # Profile list (add/remove/export/import)
│   ├── instagram_service.py       # Instagram API (v1, GraphQL, HTML)
│   ├── storage_manager.py         # File I/O, directory management, index
│   ├── download_manager.py        # Concurrent downloads with stop/skip
│   ├── thumbnail_cache.py         # 3-tier thumbnail cache (Pillow)
│   ├── scheduler.py               # APScheduler background scheduling
│   ├── web_server.py              # Flask API + embedded HTML/JS/CSS UI
│   └── tray_app.py                # pystray Windows system tray icon
├── requirements.txt               # Python dependencies
├── InstaArchive.spec              # PyInstaller build configuration
├── version_info.txt               # Windows exe version metadata
├── build.bat                      # One-click build script
├── installer.iss                  # Inno Setup installer script
└── README.md                      # Full Windows documentation
```

---

## Instagram Authentication

### macOS
Log in via **Settings → Log In to Instagram** — a WKWebView window opens, log in normally, and session cookies are captured automatically.

### Windows
1. Open `http://localhost:8485`
2. Go to **Settings → Log In to Instagram**
3. A browser window opens — log in to Instagram normally
4. Cookies are saved to `%APPDATA%\InstaArchive\cookies.json`

In both cases, your credentials are sent directly to Instagram — InstaArchive never sees your password.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

For personal archiving only. Respect Instagram's Terms of Service and the privacy of content creators. Only archive content you have permission to save.
