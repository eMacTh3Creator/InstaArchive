"""
storage_manager.py — File I/O, directory management, and media index persistence.
"""
import json
import os
import threading
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

from app_settings import AppSettings


# ---------------------------------------------------------------------------
# Media item model (stored in media_index.json)
# ---------------------------------------------------------------------------

@dataclass
class MediaItem:
    profile_username: str
    media_type: str             # Posts / Reels / Videos / Highlights / Stories / Profile Pictures
    instagram_id: str
    media_url: str
    local_path: Optional[str]
    caption: Optional[str]
    timestamp: str              # ISO8601 string
    downloaded_at: str          # ISO8601 string
    file_size: Optional[int]    # bytes

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "MediaItem":
        return MediaItem(
            profile_username=d.get("profile_username", ""),
            media_type=d.get("media_type", "Posts"),
            instagram_id=d.get("instagram_id", ""),
            media_url=d.get("media_url", ""),
            local_path=d.get("local_path"),
            caption=d.get("caption"),
            timestamp=d.get("timestamp", datetime.now().isoformat()),
            downloaded_at=d.get("downloaded_at", datetime.now().isoformat()),
            file_size=d.get("file_size"),
        )


# ---------------------------------------------------------------------------
# StorageManager
# ---------------------------------------------------------------------------

MEDIA_TYPES = [
    "Posts", "Reels", "Videos", "Highlights", "Stories", "Profile Pictures"
]


class StorageManager:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        with cls._lock:
            if cls._instance is None:
                cls._instance = super().__new__(cls)
                cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._settings = AppSettings()
        self._index_lock = threading.Lock()
        self._initialized = True

    # ------------------------------------------------------------------
    # Paths
    # ------------------------------------------------------------------

    @property
    def _index_path(self) -> Path:
        return self._settings.app_data_dir / "media_index.json"

    @property
    def _profiles_path(self) -> Path:
        return self._settings.app_data_dir / "profiles.json"

    def profile_dir(self, username: str) -> Path:
        return Path(self._settings.download_path) / username

    def media_dir(self, username: str, media_type: str) -> Path:
        return self.profile_dir(username) / media_type

    def save_path(self, username: str, media_type: str, instagram_id: str,
                  timestamp: datetime, is_video: bool, index: int = 0,
                  total: int = 1) -> Path:
        ext = "mp4" if is_video else "jpg"
        ts  = int(timestamp.timestamp())
        suffix = f"_{index + 1}" if total > 1 else ""
        filename = f"{instagram_id}_{ts}{suffix}.{ext}"
        return self.media_dir(username, media_type) / filename

    # ------------------------------------------------------------------
    # Directory creation
    # ------------------------------------------------------------------

    def ensure_dir(self, path: Path) -> Path:
        path.mkdir(parents=True, exist_ok=True)
        return path

    def create_profile_directories(self, username: str):
        for mt in MEDIA_TYPES:
            self.ensure_dir(self.media_dir(username, mt))

    # ------------------------------------------------------------------
    # Profile persistence
    # ------------------------------------------------------------------

    def save_profiles(self, profiles: list[dict]):
        try:
            with open(self._profiles_path, "w", encoding="utf-8") as f:
                json.dump(profiles, f, indent=2, default=str)
        except Exception as e:
            print(f"[Storage] Failed to save profiles: {e}")

    def load_profiles(self) -> list[dict]:
        if not self._profiles_path.exists():
            return []
        try:
            with open(self._profiles_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"[Storage] Failed to load profiles: {e}")
            return []

    # ------------------------------------------------------------------
    # Media index
    # ------------------------------------------------------------------

    def save_media_index(self, items: list[MediaItem]):
        with self._index_lock:
            try:
                data = [i.to_dict() for i in items]
                tmp = self._index_path.with_suffix(".tmp")
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(data, f)
                tmp.replace(self._index_path)
            except Exception as e:
                print(f"[Storage] Failed to save media index: {e}")

    def load_media_index(self) -> list[MediaItem]:
        if not self._index_path.exists():
            return []
        try:
            with open(self._index_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return [MediaItem.from_dict(d) for d in data]
        except Exception as e:
            print(f"[Storage] Failed to load media index: {e}")
            return []

    # ------------------------------------------------------------------
    # File operations
    # ------------------------------------------------------------------

    def save_file(self, data: bytes, path: Path):
        self.ensure_dir(path.parent)
        tmp = path.with_suffix(".tmp")
        with open(tmp, "wb") as f:
            f.write(data)
        tmp.replace(path)

    def delete_profile_files(self, username: str):
        import shutil
        profile_dir = self.profile_dir(username)
        if profile_dir.exists():
            shutil.rmtree(profile_dir, ignore_errors=True)
            print(f"[Storage] Deleted files for @{username}")

    # ------------------------------------------------------------------
    # Storage size
    # ------------------------------------------------------------------

    def downloaded_size(self, username: str) -> int:
        """Return total bytes downloaded for a profile."""
        total = 0
        pdir = self.profile_dir(username)
        if not pdir.exists():
            return 0
        for root, _, files in os.walk(pdir):
            for fname in files:
                try:
                    total += os.path.getsize(os.path.join(root, fname))
                except OSError:
                    pass
        return total

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def format_bytes(n: int) -> str:
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024:
                return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
            n /= 1024
        return f"{n:.1f} PB"
