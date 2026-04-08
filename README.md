# InstaArchive

A native macOS app for archiving Instagram profiles. Automatically downloads and organizes posts, reels, stories, highlights, and profile pictures from public (and followed private) Instagram accounts.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue) ![Swift](https://img.shields.io/badge/Swift-5.0-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Core Archiving
- **Full profile downloads** — posts, reels, videos, stories, highlights, and profile pictures
- **Automatic pagination** — fetches entire post history, not just the first page
- **Duplicate detection** — skips already-downloaded media using an in-memory index with O(1) lookups
- **File validation** — detects and re-downloads missing files by checking the index against disk
- **Organized storage** — media sorted into per-profile folders by type (`Posts/`, `Reels/`, `Stories/`, etc.)

### Performance
- **Concurrent profile processing** — download multiple profiles simultaneously via `withTaskGroup`
- **Concurrent file downloads** — up to 12 files downloaded in parallel per profile (configurable)
- **Smart rate limiting** — API calls are rate-limited to avoid blocks; CDN downloads run at full speed
- **3-tier thumbnail cache** — memory (LRU, 500 items) → disk (JPEG) → on-demand generation using `CGImageSource` for efficient thumbnail extraction without loading full images
- **Async UI** — all heavy operations (storage calculations, thumbnail loading, media queries) run off the main thread
- **Optimized SwiftUI** — cached media queries prevent redundant 20K+ item array filtering on every view update

### Instagram Authentication
- **Built-in Instagram login** — WKWebView-based login flow that captures session cookies
- **Cookie sync** — session cookies shared between WKWebView and URLSession
- **Automatic session management** — detects expired sessions and prompts re-login

### Download Management
- **Stop/skip controls** — stop all downloads or skip individual profiles mid-download
- **Per-profile status tracking** — real-time progress percentage for each profile
- **Background scheduling** — automatic periodic checks (1h to 7 days, configurable)
- **macOS notifications** — get notified when new content is found

### Web Interface
A built-in HTTP server (default: `http://localhost:8485`) provides browser-based management:

- **Password protection** — optional login with cookie-based sessions
- **Add/remove profiles** — supports usernames, @handles, and full Instagram URLs
- **Sync controls** — trigger sync for individual profiles or all at once
- **Profile detail view** — click any profile to see stats, media breakdown by type, storage usage, and last check times
- **Export/Import** — download your profile list as JSON or import from a file
- **Auto-refresh** — status updates every 5 seconds
- **Dark themed UI** — clean, responsive design

### Native macOS Integration
- **Menu bar extra** — quick access widget with profile status and controls
- **Dock icon** — full macOS citizen with proper window management
- **Menu bar commands** — Add Profile (⌘N), Check All (⇧⌘R), Go Home (⇧⌘H), Settings (⌘,)
- **Export/Import** — File menu items with ⇧⌘E / ⇧⌘I shortcuts
- **Launch at login** — optional auto-start via `SMAppService`
- **Open in Finder/Safari** — quick access to downloaded files and Instagram profiles

### Data Management
- **Export profiles** — save your subscription list to a JSON file
- **Import profiles** — load profiles from JSON, automatically skips duplicates
- **Delete with options** — remove a profile while keeping files, or delete everything including downloaded media and index entries

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15.0+ (to build from source)
- An Instagram account (for authenticated downloads)

## Building

1. Clone the repository:
   ```bash
   git clone https://github.com/eMacTh3Creator/InstaArchive.git
   cd InstaArchive
   ```

2. Open in Xcode:
   ```bash
   open InstaArchive.xcodeproj
   ```

3. Select your development team in Signing & Capabilities

4. Build and run (⌘R)

## Configuration

All settings are accessible via **Settings** (⌘,):

| Setting | Default | Description |
|---------|---------|-------------|
| Download Path | `~/Pictures/InstaArchive` | Where media files are saved |
| Check Interval | 24 hours | How often to check for new content |
| Content Types | All enabled | Toggle posts, reels, videos, highlights, stories |
| Concurrent Profiles | 3 | Profiles downloaded simultaneously |
| Files per Profile | 6 | Concurrent file downloads per profile |
| Web Interface | Enabled | Browser-based management on port 8485 |
| Web Password | (blank) | Set to require login for web interface |

## Architecture

```
InstaArchive/
├── InstaArchiveApp.swift      # App entry point, menus, focused values
├── Models/
│   ├── Profile.swift          # Profile data model + MediaType enum
│   ├── MediaItem.swift        # Downloaded media item model
│   ├── AppSettings.swift      # UserDefaults-backed settings
│   └── ProfileStore.swift     # Observable profile list + export/import
├── Views/
│   ├── ContentView.swift      # Main split view + HomeView with stats
│   ├── SidebarView.swift      # Profile list with search, stop/skip controls
│   ├── ProfileDetailView.swift # Media grid with async thumbnails + filters
│   ├── AddProfileView.swift   # Add profile sheet with Instagram lookup
│   ├── SettingsView.swift     # Full settings panel
│   ├── MenuBarView.swift      # Menu bar extra widget
│   ├── OnboardingView.swift   # First-run setup
│   └── InstagramLoginView.swift # WKWebView Instagram login
├── Services/
│   ├── InstagramService.swift # Instagram API (v1, GraphQL, HTML scraping)
│   ├── DownloadManager.swift  # Concurrent download orchestration
│   ├── StorageManager.swift   # File I/O and persistence
│   ├── SchedulerService.swift # Background check scheduling
│   ├── ThumbnailCache.swift   # 3-tier thumbnail cache (memory/disk/generate)
│   └── WebServer.swift        # Built-in HTTP server + web UI
└── Utilities/
    └── LaunchAtLogin.swift    # SMAppService wrapper
```

## API Endpoints (Web Interface)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Web dashboard |
| `GET` | `/login` | Login page (when password is set) |
| `POST` | `/api/login` | Authenticate (`{"password": "..."}`) |
| `GET` | `/api/profiles` | List all profiles |
| `POST` | `/api/profiles` | Add a profile (`{"username": "..."}`) |
| `DELETE` | `/api/profiles/{username}` | Remove a profile |
| `GET` | `/api/profile/{username}` | Profile detail with stats |
| `GET` | `/api/status` | App status (downloading, counts) |
| `POST` | `/api/sync/all` | Start sync for all profiles |
| `POST` | `/api/sync/{username}` | Start sync for one profile |

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

This tool is for personal archiving purposes. Respect Instagram's Terms of Service and the privacy of content creators. Only archive content you have permission to save.
