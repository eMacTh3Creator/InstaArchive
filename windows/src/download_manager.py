"""
download_manager.py — Orchestrates concurrent profile downloads with stop/skip support.
Mirrors the macOS DownloadManager.swift logic using Python threading.
"""
import threading
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed, Future
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum, auto
from typing import Optional, Callable

from app_settings import AppSettings
from instagram_service import InstagramService, DiscoveredMedia, SessionError, InstagramError
from logger import Logger
from storage_manager import StorageManager, MediaItem


# ---------------------------------------------------------------------------
# Status types
# ---------------------------------------------------------------------------

class StatusKind(Enum):
    IDLE        = auto()
    CHECKING    = auto()
    DOWNLOADING = auto()
    COMPLETED   = auto()
    SKIPPED     = auto()
    ERROR       = auto()


@dataclass
class ProfileStatus:
    kind: StatusKind = StatusKind.IDLE
    progress: float  = 0.0     # 0.0–1.0 when DOWNLOADING
    new_items: int   = 0       # set when COMPLETED
    error_msg: str   = ""      # set when ERROR

    def to_str(self) -> str:
        if self.kind == StatusKind.DOWNLOADING:
            return f"downloading:{int(self.progress * 100)}"
        if self.kind == StatusKind.COMPLETED:
            return f"completed:{self.new_items}"
        if self.kind == StatusKind.ERROR:
            return f"error:{self.error_msg}"
        return self.kind.name.lower()


# ---------------------------------------------------------------------------
# DownloadManager
# ---------------------------------------------------------------------------

class DownloadManager:
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
        self._settings   = AppSettings()
        self._instagram  = InstagramService()
        self._storage    = StorageManager()
        self._log        = Logger()

        # State
        self._media_items: list[MediaItem]   = []
        self._downloaded_ids: set[str]       = set()
        self._media_lock = threading.Lock()

        self.profile_statuses: dict[str, ProfileStatus] = {}
        self.active_usernames: set[str] = set()
        self.is_running: bool  = False
        self.current_activity: str = ""
        self.total_new_items:  int = 0

        # Cancellation
        self._stop_all_flag = threading.Event()
        self._profile_stop_flags: dict[str, threading.Event] = {}
        self._state_lock = threading.Lock()

        # Callbacks (web server subscribes to status changes)
        self._on_status_change: Optional[Callable] = None

        # Load index
        self._media_items = self._storage.load_media_index()
        self._rebuild_id_index()
        self._initialized = True

    # ------------------------------------------------------------------
    # Index helpers
    # ------------------------------------------------------------------

    def _rebuild_id_index(self):
        with self._media_lock:
            self._downloaded_ids = {item.instagram_id for item in self._media_items}

    def _is_downloaded(self, iid: str) -> bool:
        with self._media_lock:
            return iid in self._downloaded_ids

    def _record_download(self, item: MediaItem):
        with self._media_lock:
            self._media_items.append(item)
            self._downloaded_ids.add(item.instagram_id)
            count = len(self._media_items)
        if count % 25 == 0:
            self._save_index()

    def _save_index(self):
        with self._media_lock:
            snapshot = list(self._media_items)
        self._storage.save_media_index(snapshot)

    def validate_index(self):
        """Prune index entries whose files no longer exist on disk."""
        with self._media_lock:
            before = len(self._media_items)
            self._media_items = [
                item for item in self._media_items
                if item.local_path and __import__("os.path", fromlist=["exists"]).exists(item.local_path)
            ]
            removed = before - len(self._media_items)
            if removed:
                print(f"[DownloadManager] Pruned {removed} stale index entries")
                self._downloaded_ids = {i.instagram_id for i in self._media_items}
                self._storage.save_media_index(self._media_items)

    def remove_media_index(self, username: str):
        with self._media_lock:
            self._media_items = [i for i in self._media_items if i.profile_username != username]
            self._downloaded_ids = {i.instagram_id for i in self._media_items}
            self._storage.save_media_index(self._media_items)

    def remove_posts_index(self, username: str) -> int:
        keep_types = {"Stories", "Highlights", "Profile Pictures"}
        with self._media_lock:
            self._media_items = [
                item for item in self._media_items
                if item.profile_username != username or item.media_type in keep_types
            ]
            self._downloaded_ids = {i.instagram_id for i in self._media_items}
            remaining = sum(1 for item in self._media_items if item.profile_username == username)
            self._storage.save_media_index(self._media_items)
        return remaining

    def media_items_for(self, username: str) -> list[MediaItem]:
        with self._media_lock:
            return [i for i in self._media_items if i.profile_username == username]

    @property
    def total_downloaded(self) -> int:
        with self._media_lock:
            return len(self._media_items)

    def current_ids(self) -> set[str]:
        with self._media_lock:
            return set(self._downloaded_ids)

    # ------------------------------------------------------------------
    # Cancellation
    # ------------------------------------------------------------------

    def skip_profile(self, username: str):
        with self._state_lock:
            flag = self._profile_stop_flags.get(username)
            if flag:
                flag.set()
        self._set_status(username, ProfileStatus(kind=StatusKind.SKIPPED))
        with self._state_lock:
            self.active_usernames.discard(username)
            if not self.active_usernames:
                self.is_running = False
                self.current_activity = ""

    def stop_all(self):
        self._stop_all_flag.set()
        with self._state_lock:
            for flag in self._profile_stop_flags.values():
                flag.set()

    def _should_stop(self, username: str) -> bool:
        if self._stop_all_flag.is_set():
            return True
        flag = self._profile_stop_flags.get(username)
        return flag is not None and flag.is_set()

    # ------------------------------------------------------------------
    # Status helpers
    # ------------------------------------------------------------------

    def _set_status(self, username: str, status: ProfileStatus):
        with self._state_lock:
            self.profile_statuses[username] = status
        if self._on_status_change:
            self._on_status_change(username, status)

    def get_status(self, username: str) -> ProfileStatus:
        with self._state_lock:
            return self.profile_statuses.get(username, ProfileStatus())

    # ------------------------------------------------------------------
    # Check single profile
    # ------------------------------------------------------------------

    def check_profile(self, profile: dict, profile_store=None):
        """Fire-and-forget: start download for one profile in background thread."""
        username = profile["username"]
        with self._state_lock:
            if username in self.active_usernames:
                return
            stop_flag = threading.Event()
            self._profile_stop_flags[username] = stop_flag
            self.active_usernames.add(username)
            self.is_running = True

        t = threading.Thread(
            target=self._perform_check,
            args=(profile, profile_store, stop_flag),
            daemon=True,
            name=f"download-{username}",
        )
        t.start()

    def refresh_profile(self, profile: dict, profile_store=None) -> bool:
        """Delete posts/reels/videos, keep stories/highlights/profile pictures, then sync."""
        username = profile["username"]
        with self._state_lock:
            if username in self.active_usernames:
                return False
            stop_flag = threading.Event()
            self._profile_stop_flags[username] = stop_flag
            self.active_usernames.add(username)
            self.is_running = True

        t = threading.Thread(
            target=self._perform_refresh,
            args=(profile, profile_store, stop_flag),
            daemon=True,
            name=f"refresh-{username}",
        )
        t.start()
        return True

    def _perform_refresh(self, profile: dict, profile_store, stop_flag: threading.Event):
        username = profile["username"]
        try:
            self._log.info(
                f"Refreshing @{username}: deleting posts, keeping stories/highlights/profile pictures",
                context="refresh",
            )
            self._set_status(username, ProfileStatus(kind=StatusKind.CHECKING))
            self.current_activity = f"Preparing refresh for @{username}..."

            if stop_flag.is_set() or self._stop_all_flag.is_set():
                raise InterruptedError()

            remaining = self.remove_posts_index(username)

            for media_type in ("Posts", "Reels", "Videos"):
                shutil.rmtree(self._storage.media_dir(username, media_type), ignore_errors=True)

            if profile_store is not None:
                profile_store.reset_after_refresh(username, remaining)
                updated_profile = profile_store.get_profile(username) or profile
            else:
                updated_profile = profile

            if stop_flag.is_set() or self._stop_all_flag.is_set():
                raise InterruptedError()

            self._perform_check(updated_profile, profile_store, stop_flag)
        except InterruptedError:
            self._save_index()
            self._log.info(f"@{username}: refresh skipped/cancelled", context="refresh")
            self._set_status(username, ProfileStatus(kind=StatusKind.SKIPPED))
            with self._state_lock:
                self.active_usernames.discard(username)
                self._profile_stop_flags.pop(username, None)
                if not self.active_usernames:
                    self.is_running = False
                    self.current_activity = ""
        except Exception as e:
            self._save_index()
            self._log.error(f"@{username}: refresh failed — {e}", context="refresh")
            self._set_status(username, ProfileStatus(kind=StatusKind.ERROR, error_msg=str(e)))
            with self._state_lock:
                self.active_usernames.discard(username)
                self._profile_stop_flags.pop(username, None)
                if not self.active_usernames:
                    self.is_running = False
                    self.current_activity = ""

    def _perform_check(self, profile: dict, profile_store, stop_flag: threading.Event):
        username = profile["username"]
        self._log.info(f"Starting check for @{username}", context="download")
        self._set_status(username, ProfileStatus(kind=StatusKind.CHECKING))
        self.current_activity = f"Validating index for @{username}..."
        self.validate_index()

        try:
            if stop_flag.is_set() or self._stop_all_flag.is_set():
                raise InterruptedError()

            # 1. Profile info
            self._log.info(f"Fetching profile info for @{username}", context="download")
            profile_info = self._instagram.fetch_profile_info(username)
            all_media: list[DiscoveredMedia] = []

            # 2. Profile picture
            pic = self._instagram.make_profile_pic_media(profile_info)
            if pic:
                all_media.append(pic)

            # 3. Posts
            if stop_flag.is_set() or self._stop_all_flag.is_set():
                raise InterruptedError()
            self.current_activity = f"Fetching posts for @{username}..."
            posts = self._instagram.fetch_all_media(username, self.current_ids())
            all_media.extend(posts)

            # 4. Stories — proper error handling, don't silently swallow failures
            if self._settings.download_stories and profile_info.user_id:
                if not (stop_flag.is_set() or self._stop_all_flag.is_set()):
                    self.current_activity = f"Fetching stories for @{username}..."
                    try:
                        stories = self._instagram.fetch_stories(profile_info.user_id, username)
                        all_media.extend(stories)
                    except (SessionError, InstagramError):
                        raise
                    except Exception as e:
                        self._log.warn(f"Stories fetch failed for @{username}: {e} (continuing)", context="download")

            # 5. Highlights — proper error handling, don't silently swallow failures
            if self._settings.download_highlights and profile_info.user_id:
                if not (stop_flag.is_set() or self._stop_all_flag.is_set()):
                    self.current_activity = f"Fetching highlights for @{username}..."
                    try:
                        highlights = self._instagram.fetch_highlights(profile_info.user_id, username)
                        all_media.extend(highlights)
                    except (SessionError, InstagramError):
                        raise
                    except Exception as e:
                        self._log.warn(f"Highlights fetch failed for @{username}: {e} (continuing)", context="download")

            # Filter by type settings and dedup
            type_enabled = {
                "Posts":            self._settings.download_posts,
                "Reels":            self._settings.download_reels,
                "Videos":           self._settings.download_videos,
                "Highlights":       self._settings.download_highlights,
                "Stories":          self._settings.download_stories,
                "Profile Pictures": True,
            }
            known = self.current_ids()
            new_media = [
                m for m in all_media
                if type_enabled.get(m.media_type, True)
                and not all(
                    (f"{m.instagram_id}_{i}" if len(m.media_urls) > 1 else m.instagram_id) in known
                    for i in range(len(m.media_urls))
                )
            ]

            self._log.info(
                f"@{username}: discovered {len(all_media)} total, {len(new_media)} new after filtering",
                context="download",
            )

            # Build flat job list
            jobs = []
            self._storage.create_profile_directories(username)

            for media in new_media:
                for idx, url in enumerate(media.media_urls):
                    item_id = f"{media.instagram_id}_{idx}" if len(media.media_urls) > 1 else media.instagram_id
                    if self._is_downloaded(item_id):
                        continue
                    existing_path = self._storage.existing_save_path(
                        username,
                        media.media_type,
                        media.instagram_id,
                        media.timestamp,
                        media.is_video,
                        idx,
                        len(media.media_urls),
                        media_url=url,
                    )
                    # If already on disk, just re-index
                    if existing_path is not None:
                        size = existing_path.stat().st_size
                        self._record_download(MediaItem(
                            profile_username=username,
                            media_type=media.media_type,
                            instagram_id=item_id,
                            media_url=url,
                            local_path=str(existing_path),
                            caption=media.caption,
                            timestamp=media.timestamp.isoformat(),
                            downloaded_at=datetime.now().isoformat(),
                            file_size=size,
                        ))
                        continue
                    save_path = self._storage.save_path(
                        username,
                        media.media_type,
                        media.instagram_id,
                        media.timestamp,
                        media.is_video,
                        idx,
                        len(media.media_urls),
                        media_url=url,
                    )
                    jobs.append({
                        "media": media, "idx": idx, "url": url,
                        "item_id": item_id, "save_path": save_path,
                    })

            # Download concurrently
            total = len(jobs)
            completed_counter = _AtomicInt()
            new_item_counter  = _AtomicInt()
            failed_counter    = _AtomicInt()
            max_workers = self._settings.max_concurrent_files

            self._log.info(f"@{username}: downloading {total} files", context="download")

            def download_job(job):
                if stop_flag.is_set() or self._stop_all_flag.is_set():
                    return
                try:
                    data = self._instagram.download_media_data(job["url"])
                    final_ext = self._storage.detected_extension(
                        data,
                        job["url"],
                        job["media"].is_video,
                    )
                    final_save_path = self._storage.save_path(
                        username,
                        job["media"].media_type,
                        job["media"].instagram_id,
                        job["media"].timestamp,
                        job["media"].is_video,
                        job["idx"],
                        len(job["media"].media_urls),
                        file_ext=final_ext,
                    )
                    self._storage.save_file(data, final_save_path)
                    item = MediaItem(
                        profile_username=username,
                        media_type=job["media"].media_type,
                        instagram_id=job["item_id"],
                        media_url=job["url"],
                        local_path=str(final_save_path),
                        caption=job["media"].caption,
                        timestamp=job["media"].timestamp.isoformat(),
                        downloaded_at=datetime.now().isoformat(),
                        file_size=len(data),
                    )
                    self._record_download(item)
                    new_item_counter.increment()
                except Exception as e:
                    failed_counter.increment()
                    self._log.warn(f"Failed to download {job['item_id']}: {e}", context="download")
                finally:
                    done = completed_counter.increment()
                    if total > 0 and (done % 3 == 0 or done == total):
                        prog = done / total
                        self._set_status(username, ProfileStatus(
                            kind=StatusKind.DOWNLOADING, progress=prog
                        ))
                        self.current_activity = f"Downloading @{username} ({done}/{total})..."

            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                futures = [executor.submit(download_job, j) for j in jobs]
                for f in as_completed(futures):
                    if stop_flag.is_set() or self._stop_all_flag.is_set():
                        executor.shutdown(wait=False, cancel_futures=True)
                        break
                    f.result()  # propagate exceptions

            self._save_index()
            new_count = new_item_counter.value
            fail_count = failed_counter.value

            # Update profile store
            if profile_store is not None:
                profile_store.update_after_download(username, new_count)

            with self._state_lock:
                self.total_new_items += new_count

            if fail_count > 0:
                self._log.warn(
                    f"@{username}: completed with {new_count} new, {fail_count} failed",
                    context="download",
                )
            else:
                self._log.info(f"@{username}: completed with {new_count} new items", context="download")

            self._set_status(username, ProfileStatus(kind=StatusKind.COMPLETED, new_items=new_count))

        except InterruptedError:
            self._save_index()
            self._log.info(f"@{username}: skipped/cancelled", context="download")
            self._set_status(username, ProfileStatus(kind=StatusKind.SKIPPED))
        except SessionError as e:
            self._save_index()
            self._log.error(f"@{username}: session error — {e}", context="download")
            self._instagram.reset_session()
            self._set_status(username, ProfileStatus(kind=StatusKind.ERROR, error_msg=str(e)))
        except Exception as e:
            self._save_index()
            self._log.error(f"@{username}: {e}", context="download")
            self._set_status(username, ProfileStatus(kind=StatusKind.ERROR, error_msg=str(e)))
        finally:
            with self._state_lock:
                self.active_usernames.discard(username)
                self._profile_stop_flags.pop(username, None)
                if not self.active_usernames:
                    self.is_running = False
                    self.current_activity = ""

    # ------------------------------------------------------------------
    # Check all profiles (concurrent)
    # ------------------------------------------------------------------

    def check_all_profiles(self, profile_store):
        self._stop_all_flag.clear()
        active_profiles = [p for p in profile_store.profiles if p.get("is_active", True)]
        if not active_profiles:
            return

        max_concurrent = self._settings.max_concurrent_profiles

        def run_all():
            with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
                futures: list[Future] = []
                for profile in active_profiles:
                    if self._stop_all_flag.is_set():
                        break
                    username = profile["username"]
                    with self._state_lock:
                        if username in self.active_usernames:
                            continue
                        stop_flag = threading.Event()
                        self._profile_stop_flags[username] = stop_flag
                        self.active_usernames.add(username)
                        self.is_running = True
                    f = executor.submit(self._perform_check, profile, profile_store, stop_flag)
                    futures.append(f)
                for f in as_completed(futures):
                    try:
                        f.result()
                    except Exception as e:
                        print(f"[DownloadManager] check_all error: {e}")

            with self._state_lock:
                if not self.active_usernames:
                    self.is_running = False
                    self.current_activity = ""

        t = threading.Thread(target=run_all, daemon=True, name="check-all")
        t.start()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class _AtomicInt:
    def __init__(self):
        self._v = 0
        self._lock = threading.Lock()

    def increment(self) -> int:
        with self._lock:
            self._v += 1
            return self._v

    @property
    def value(self) -> int:
        with self._lock:
            return self._v
