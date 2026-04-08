"""
app_settings.py — Persistent settings stored in %APPDATA%/InstaArchive/settings.json
"""
import json
import os
from pathlib import Path


def _default_download_path() -> str:
    pictures = Path.home() / "Pictures" / "InstaArchive"
    return str(pictures)


def _app_data_dir() -> Path:
    base = os.environ.get("APPDATA", str(Path.home()))
    d = Path(base) / "InstaArchive"
    d.mkdir(parents=True, exist_ok=True)
    return d


DEFAULTS = {
    "download_path": _default_download_path(),
    "check_interval_hours": 24,
    "download_posts": True,
    "download_reels": True,
    "download_videos": True,
    "download_highlights": True,
    "download_stories": False,
    "max_concurrent_profiles": 3,
    "max_concurrent_files": 6,
    "notifications_enabled": True,
    "web_server_enabled": True,
    "web_server_port": 8485,
    "web_server_password": "",
    "launch_at_startup": False,
    "is_logged_in": False,
}


class AppSettings:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._loaded = False
        return cls._instance

    def __init__(self):
        if self._loaded:
            return
        self._path = _app_data_dir() / "settings.json"
        self._data = dict(DEFAULTS)
        self._load()
        self._loaded = True

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load(self):
        if self._path.exists():
            try:
                with open(self._path, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                self._data.update(saved)
            except Exception as e:
                print(f"[Settings] Failed to load: {e}")

    def save(self):
        try:
            with open(self._path, "w", encoding="utf-8") as f:
                json.dump(self._data, f, indent=2)
        except Exception as e:
            print(f"[Settings] Failed to save: {e}")

    # ------------------------------------------------------------------
    # Accessors
    # ------------------------------------------------------------------

    def get(self, key, default=None):
        return self._data.get(key, default if default is not None else DEFAULTS.get(key))

    def set(self, key, value):
        self._data[key] = value
        self.save()

    def update(self, mapping: dict):
        self._data.update(mapping)
        self.save()

    # ------------------------------------------------------------------
    # Typed properties
    # ------------------------------------------------------------------

    @property
    def download_path(self) -> str:
        return self.get("download_path")

    @download_path.setter
    def download_path(self, v):
        self.set("download_path", v)

    @property
    def check_interval_hours(self) -> int:
        return int(self.get("check_interval_hours"))

    @property
    def download_posts(self) -> bool:
        return bool(self.get("download_posts"))

    @property
    def download_reels(self) -> bool:
        return bool(self.get("download_reels"))

    @property
    def download_videos(self) -> bool:
        return bool(self.get("download_videos"))

    @property
    def download_highlights(self) -> bool:
        return bool(self.get("download_highlights"))

    @property
    def download_stories(self) -> bool:
        return bool(self.get("download_stories"))

    @property
    def max_concurrent_profiles(self) -> int:
        return int(self.get("max_concurrent_profiles"))

    @property
    def max_concurrent_files(self) -> int:
        return int(self.get("max_concurrent_files"))

    @property
    def web_server_enabled(self) -> bool:
        return bool(self.get("web_server_enabled"))

    @property
    def web_server_port(self) -> int:
        return int(self.get("web_server_port"))

    @property
    def web_server_password(self) -> str:
        return str(self.get("web_server_password") or "")

    @property
    def is_logged_in(self) -> bool:
        return bool(self.get("is_logged_in"))

    @is_logged_in.setter
    def is_logged_in(self, v: bool):
        self.set("is_logged_in", v)

    @property
    def app_data_dir(self) -> Path:
        return _app_data_dir()

    @property
    def cookies_path(self) -> Path:
        return self.app_data_dir / "cookies.json"
