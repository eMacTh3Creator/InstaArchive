"""
profile_store.py — Observable list of tracked profiles with persistence.
"""
import threading
import uuid
from datetime import datetime
from typing import Optional

from storage_manager import StorageManager


class ProfileStore:
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
        self._storage  = StorageManager()
        self._profiles: list[dict] = []
        self._plock    = threading.Lock()
        self._load()
        self._initialized = True

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load(self):
        data = self._storage.load_profiles()
        with self._plock:
            self._profiles = data

    def _save(self):
        with self._plock:
            snapshot = list(self._profiles)
        self._storage.save_profiles(snapshot)

    # ------------------------------------------------------------------
    # Accessors
    # ------------------------------------------------------------------

    @property
    def profiles(self) -> list[dict]:
        with self._plock:
            return list(self._profiles)

    def get_profile(self, username: str) -> Optional[dict]:
        with self._plock:
            for p in self._profiles:
                if p["username"] == username.lower():
                    return dict(p)
        return None

    # ------------------------------------------------------------------
    # CRUD
    # ------------------------------------------------------------------

    def add_profile(self, username: str, display_name: str = "",
                    profile_pic_url: str = "", bio: str = "") -> dict:
        username = username.lower().strip()
        with self._plock:
            if any(p["username"] == username for p in self._profiles):
                raise ValueError(f"Profile @{username} already exists")
            profile = {
                "id":             str(uuid.uuid4()),
                "username":       username,
                "display_name":   display_name or username,
                "profile_pic_url": profile_pic_url,
                "bio":            bio,
                "is_active":      True,
                "last_checked":   None,
                "last_new_content": None,
                "total_downloaded": 0,
                "date_added":     datetime.now().isoformat(),
            }
            self._profiles.append(profile)
        self._storage.create_profile_directories(username)
        self._save()
        return profile

    def remove_profile(self, username: str):
        with self._plock:
            self._profiles = [p for p in self._profiles if p["username"] != username]
        self._save()

    def remove_profile_and_files(self, username: str):
        self.remove_profile(username)
        from download_manager import DownloadManager
        DownloadManager().remove_media_index(username)
        self._storage.delete_profile_files(username)

    def update_after_download(self, username: str, new_items: int):
        with self._plock:
            for p in self._profiles:
                if p["username"] == username:
                    p["last_checked"] = datetime.now().isoformat()
                    p["total_downloaded"] = p.get("total_downloaded", 0) + new_items
                    if new_items > 0:
                        p["last_new_content"] = datetime.now().isoformat()
                    break
        self._save()

    def reset_after_refresh(self, username: str, remaining_items: int):
        with self._plock:
            for p in self._profiles:
                if p["username"] == username:
                    p["total_downloaded"] = remaining_items
                    p["last_checked"] = None
                    break
        self._save()

    def set_active(self, username: str, active: bool):
        with self._plock:
            for p in self._profiles:
                if p["username"] == username:
                    p["is_active"] = active
                    break
        self._save()

    # ------------------------------------------------------------------
    # Export / Import
    # ------------------------------------------------------------------

    def export_profiles(self, path: str):
        import json
        with self._plock:
            snapshot = list(self._profiles)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2, default=str)

    def import_profiles(self, path: str) -> int:
        import json
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            data = data.get("profiles", [])
        added = 0
        for item in data:
            username = item.get("username", "").lower().strip()
            if not username:
                continue
            with self._plock:
                if any(p["username"] == username for p in self._profiles):
                    continue
            try:
                self.add_profile(
                    username=username,
                    display_name=item.get("display_name", ""),
                    profile_pic_url=item.get("profile_pic_url", ""),
                    bio=item.get("bio", ""),
                )
                added += 1
            except ValueError:
                pass
        return added
