"""
instagram_service.py — Instagram API interactions (v1, GraphQL, HTML scraping).
Mirrors the logic from the macOS InstagramService.swift.
"""
import json
import re
import time
import random
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import urlencode

import requests

from app_settings import AppSettings

# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass
class ProfileInfo:
    username: str
    full_name: str
    biography: str
    profile_pic_url: str
    is_private: bool
    post_count: int
    follower_count: int
    user_id: str


@dataclass
class DiscoveredMedia:
    instagram_id: str
    media_type: str          # "Posts","Reels","Videos","Highlights","Stories","Profile Pictures"
    media_urls: list[str]    # multiple = carousel
    thumbnail_url: Optional[str]
    caption: Optional[str]
    timestamp: datetime
    is_video: bool


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class InstagramError(Exception):
    pass

class RateLimitedError(InstagramError):
    pass

class SessionError(InstagramError):
    pass


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

BASE_URL = "https://www.instagram.com"
APP_ID   = "936619743392459"

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br",
    "Connection":      "keep-alive",
    "X-IG-App-ID":     APP_ID,
}


class InstagramService:
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
        self._settings    = AppSettings()
        self._session     = requests.Session()
        self._session.headers.update(HEADERS)
        self._last_request_time: float = 0.0
        self._min_interval: float = 2.5    # seconds between API calls
        self._csrf_token: Optional[str] = None
        self._session_ready = False
        self._cached_user_ids: dict[str, str] = {}
        self._rate_lock = threading.Lock()
        self._load_cookies()
        self._initialized = True

    # ------------------------------------------------------------------
    # Cookie persistence
    # ------------------------------------------------------------------

    def _load_cookies(self):
        path = self._settings.cookies_path
        if path.exists():
            try:
                with open(path, "r", encoding="utf-8") as f:
                    cookies = json.load(f)
                for c in cookies:
                    self._session.cookies.set(c["name"], c["value"], domain=c.get("domain", ".instagram.com"))
                # Extract CSRF token
                csrf = self._session.cookies.get("csrftoken", domain=".instagram.com")
                if csrf:
                    self._csrf_token = csrf
                    self._session.headers["X-CSRFToken"] = csrf
                    self._session_ready = True
                    print("[Instagram] Loaded saved cookies")
            except Exception as e:
                print(f"[Instagram] Failed to load cookies: {e}")

    def save_cookies(self, cookies: list[dict]):
        """Called by the login flow with cookies captured from the browser."""
        path = self._settings.cookies_path
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(cookies, f, indent=2)
            # Apply to session
            for c in cookies:
                self._session.cookies.set(c["name"], c["value"], domain=c.get("domain", ".instagram.com"))
            csrf = self._session.cookies.get("csrftoken", domain=".instagram.com")
            if csrf:
                self._csrf_token = csrf
                self._session.headers["X-CSRFToken"] = csrf
            self._session_ready = True
            self._settings.is_logged_in = True
            print("[Instagram] Cookies saved and session ready")
        except Exception as e:
            print(f"[Instagram] Failed to save cookies: {e}")

    def reset_session(self):
        self._session_ready = False
        self._csrf_token = None
        self._session.cookies.clear()
        self._settings.is_logged_in = False
        path = self._settings.cookies_path
        if path.exists():
            path.unlink()
        print("[Instagram] Session reset")

    # ------------------------------------------------------------------
    # Rate limiting
    # ------------------------------------------------------------------

    def _wait_rate_limit(self):
        with self._rate_lock:
            elapsed = time.monotonic() - self._last_request_time
            if elapsed < self._min_interval:
                time.sleep(self._min_interval - elapsed + random.uniform(0, 0.3))
            self._last_request_time = time.monotonic()

    def _get(self, url: str, params: dict = None, referer: str = None) -> requests.Response:
        self._wait_rate_limit()
        headers = {}
        if referer:
            headers["Referer"] = referer
        resp = self._session.get(url, params=params, headers=headers, timeout=30)
        return resp

    # ------------------------------------------------------------------
    # Profile info
    # ------------------------------------------------------------------

    def fetch_profile_info(self, username: str) -> ProfileInfo:
        url = f"{BASE_URL}/api/v1/users/web_profile_info/"
        resp = self._get(url, params={"username": username}, referer=f"{BASE_URL}/{username}/")
        if resp.status_code == 429:
            raise RateLimitedError("Rate limited")
        if resp.status_code in (401, 403):
            raise SessionError("Session expired")
        if resp.status_code != 200:
            raise InstagramError(f"HTTP {resp.status_code}")

        try:
            data = resp.json()
            user = data["data"]["user"]
            return ProfileInfo(
                username=user.get("username", username),
                full_name=user.get("full_name", ""),
                biography=user.get("biography", ""),
                profile_pic_url=user.get("profile_pic_url_hd") or user.get("profile_pic_url", ""),
                is_private=user.get("is_private", False),
                post_count=user.get("edge_owner_to_timeline_media", {}).get("count", 0),
                follower_count=user.get("edge_followed_by", {}).get("count", 0),
                user_id=user.get("id", ""),
            )
        except (KeyError, ValueError) as e:
            raise InstagramError(f"Failed to parse profile: {e}")

    def get_user_id(self, username: str) -> str:
        if username in self._cached_user_ids:
            return self._cached_user_ids[username]
        info = self.fetch_profile_info(username)
        self._cached_user_ids[username] = info.user_id
        return info.user_id

    # ------------------------------------------------------------------
    # Profile picture
    # ------------------------------------------------------------------

    def make_profile_pic_media(self, profile_info: ProfileInfo) -> Optional[DiscoveredMedia]:
        if not profile_info.profile_pic_url:
            return None
        return DiscoveredMedia(
            instagram_id=f"{profile_info.user_id}_profilepic",
            media_type="Profile Pictures",
            media_urls=[profile_info.profile_pic_url],
            thumbnail_url=profile_info.profile_pic_url,
            caption=None,
            timestamp=datetime.now(),
            is_video=False,
        )

    # ------------------------------------------------------------------
    # Posts (paginated)
    # ------------------------------------------------------------------

    def fetch_all_media(self, username: str, known_ids: set[str]) -> list[DiscoveredMedia]:
        """Fetch all posts for a username with full cursor-based pagination."""
        all_media: list[DiscoveredMedia] = []
        user_id = self.get_user_id(username)
        cursor = None
        consecutive_known = 0
        safety_cap = 5000

        while len(all_media) < safety_cap:
            page, next_cursor = self._fetch_page_v1(user_id, cursor)
            if not page:
                # Fallback to GraphQL
                page, next_cursor = self._fetch_page_graphql(username, cursor)
            if not page:
                break

            new_this_page = 0
            for item in page:
                media = self._parse_media_node(item, username)
                if media:
                    if media.instagram_id not in known_ids:
                        all_media.append(media)
                        new_this_page += 1
                    else:
                        consecutive_known += 1

            if new_this_page == 0:
                consecutive_known += len(page)

            if consecutive_known >= 66:  # 2 full pages of already-known
                break

            if not next_cursor:
                break
            cursor = next_cursor

        return all_media

    def _fetch_page_v1(self, user_id: str, cursor: Optional[str]) -> tuple[list, Optional[str]]:
        url = f"{BASE_URL}/api/v1/feed/user/{user_id}/"
        params = {"count": "33"}
        if cursor:
            params["max_id"] = cursor
        try:
            resp = self._get(url, params=params, referer=BASE_URL + "/")
            if resp.status_code != 200:
                return [], None
            data = resp.json()
            items = data.get("items", [])
            next_cursor = data.get("next_max_id")
            return items, next_cursor
        except Exception as e:
            print(f"[Instagram] v1 page fetch failed: {e}")
            return [], None

    def _fetch_page_graphql(self, username: str, cursor: Optional[str]) -> tuple[list, Optional[str]]:
        doc_id = "17991233890457762"
        variables = {"id": self.get_user_id(username), "first": 33}
        if cursor:
            variables["after"] = cursor
        try:
            resp = self._get(
                f"{BASE_URL}/graphql/query/",
                params={"doc_id": doc_id, "variables": json.dumps(variables)},
                referer=f"{BASE_URL}/{username}/",
            )
            if resp.status_code != 200:
                return [], None
            data = resp.json()
            edges = (
                data.get("data", {})
                    .get("user", {})
                    .get("edge_owner_to_timeline_media", {})
                    .get("edges", [])
            )
            page_info = (
                data.get("data", {})
                    .get("user", {})
                    .get("edge_owner_to_timeline_media", {})
                    .get("page_info", {})
            )
            nodes = [e["node"] for e in edges if "node" in e]
            next_cursor = page_info.get("end_cursor") if page_info.get("has_next_page") else None
            return nodes, next_cursor
        except Exception as e:
            print(f"[Instagram] GraphQL page fetch failed: {e}")
            return [], None

    def _parse_media_node(self, node: dict, username: str) -> Optional[DiscoveredMedia]:
        try:
            media_id = node.get("id") or node.get("pk", "")
            if not media_id:
                return None

            # Determine type
            typename = node.get("__typename") or node.get("media_type", "")
            is_video = node.get("is_video", False) or typename in ("GraphVideo",) or node.get("media_type") == 2
            is_reel  = node.get("product_type") in ("clips", "reels") or typename == "GraphVideo"

            if is_reel:
                media_type = "Reels"
            elif is_video:
                media_type = "Videos"
            else:
                media_type = "Posts"

            # Timestamp
            ts_raw = node.get("taken_at") or node.get("taken_at_timestamp") or 0
            timestamp = datetime.fromtimestamp(float(ts_raw)) if ts_raw else datetime.now()

            # Caption
            caption = None
            cap_node = node.get("edge_media_to_caption", {}).get("edges", [])
            if cap_node:
                caption = cap_node[0].get("node", {}).get("text")
            if not caption:
                caption = node.get("caption", {})
                if isinstance(caption, dict):
                    caption = caption.get("text")

            # URLs — handle carousels
            media_urls: list[str] = []
            thumbnail_url: Optional[str] = None

            carousel_edges = node.get("edge_sidecar_to_children", {}).get("edges", [])
            carousel_media = node.get("carousel_media", [])

            if carousel_edges:
                for edge in carousel_edges:
                    child = edge.get("node", {})
                    url = self._best_url(child)
                    if url:
                        media_urls.append(url)
                thumbnail_url = self._thumbnail_url(node)
            elif carousel_media:
                for child in carousel_media:
                    url = self._best_url(child)
                    if url:
                        media_urls.append(url)
                thumbnail_url = self._thumbnail_url(node)
            else:
                url = self._best_url(node)
                if url:
                    media_urls.append(url)
                thumbnail_url = self._thumbnail_url(node)

            if not media_urls:
                return None

            return DiscoveredMedia(
                instagram_id=str(media_id),
                media_type=media_type,
                media_urls=media_urls,
                thumbnail_url=thumbnail_url,
                caption=caption,
                timestamp=timestamp,
                is_video=is_video,
            )
        except Exception as e:
            print(f"[Instagram] Failed to parse media node: {e}")
            return None

    def _best_url(self, node: dict) -> Optional[str]:
        # Video
        if node.get("video_url"):
            return node["video_url"]
        vv = node.get("video_versions")
        if vv and isinstance(vv, list):
            return vv[0].get("url")
        # Image — pick highest res
        candidates = node.get("image_versions2", {}).get("candidates", [])
        if candidates:
            best = max(candidates, key=lambda c: c.get("width", 0) * c.get("height", 0))
            return best.get("url")
        # GraphQL display_url
        resources = node.get("edge_media_preview_image", {}).get("edges", [])
        if resources:
            return resources[-1].get("node", {}).get("src")
        return node.get("display_url")

    def _thumbnail_url(self, node: dict) -> Optional[str]:
        candidates = node.get("image_versions2", {}).get("candidates", [])
        if candidates:
            return candidates[-1].get("url")
        return node.get("thumbnail_src") or node.get("display_url")

    # ------------------------------------------------------------------
    # Stories
    # ------------------------------------------------------------------

    def fetch_stories(self, user_id: str, username: str) -> list[DiscoveredMedia]:
        url = f"{BASE_URL}/api/v1/feed/user/{user_id}/story/"
        try:
            resp = self._get(url, referer=f"{BASE_URL}/{username}/")
            if resp.status_code != 200:
                return []
            data = resp.json()
            reel = data.get("reel") or data.get("reels", {}).get(user_id, {})
            items = reel.get("items", []) if reel else []
            results = []
            for item in items:
                media = self._parse_story_item(item, username)
                if media:
                    results.append(media)
            return results
        except Exception as e:
            print(f"[Instagram] Stories fetch failed: {e}")
            return []

    def _parse_story_item(self, item: dict, username: str) -> Optional[DiscoveredMedia]:
        try:
            media_id = str(item.get("pk") or item.get("id", ""))
            ts_raw = item.get("taken_at", 0)
            timestamp = datetime.fromtimestamp(float(ts_raw))
            is_video = item.get("media_type") == 2

            url = self._best_url(item)
            if not url:
                return None

            return DiscoveredMedia(
                instagram_id=media_id,
                media_type="Stories",
                media_urls=[url],
                thumbnail_url=self._thumbnail_url(item),
                caption=None,
                timestamp=timestamp,
                is_video=is_video,
            )
        except Exception:
            return None

    # ------------------------------------------------------------------
    # Highlights
    # ------------------------------------------------------------------

    def fetch_highlights(self, user_id: str, username: str) -> list[DiscoveredMedia]:
        reel_ids = self._fetch_highlight_reel_ids(user_id, username)
        results = []
        for reel_id in reel_ids:
            items = self._fetch_highlight_items(reel_id, username)
            results.extend(items)
        return results

    def _fetch_highlight_reel_ids(self, user_id: str, username: str) -> list[str]:
        url = f"{BASE_URL}/api/v1/highlights/{user_id}/highlights_tray/"
        try:
            resp = self._get(url, referer=f"{BASE_URL}/{username}/")
            if resp.status_code != 200:
                return []
            data = resp.json()
            tray = data.get("tray", [])
            return [str(r.get("id", "")) for r in tray if r.get("id")]
        except Exception as e:
            print(f"[Instagram] Highlight IDs fetch failed: {e}")
            return []

    def _fetch_highlight_items(self, reel_id: str, username: str) -> list[DiscoveredMedia]:
        full_id = reel_id if reel_id.startswith("highlight:") else f"highlight:{reel_id}"
        url = f"{BASE_URL}/api/v1/feed/reels_media/"
        try:
            resp = self._get(url, params={"reel_ids": full_id}, referer=f"{BASE_URL}/{username}/")
            if resp.status_code != 200:
                return []
            data = resp.json()
            reels = data.get("reels", {})
            reel = reels.get(full_id) or reels.get(reel_id, {})
            items = reel.get("items", [])
            results = []
            for item in items:
                media_id = str(item.get("pk") or item.get("id", ""))
                ts_raw = item.get("taken_at", 0)
                timestamp = datetime.fromtimestamp(float(ts_raw))
                is_video = item.get("media_type") == 2
                url_val = self._best_url(item)
                if url_val:
                    results.append(DiscoveredMedia(
                        instagram_id=f"{reel_id}_{media_id}",
                        media_type="Highlights",
                        media_urls=[url_val],
                        thumbnail_url=self._thumbnail_url(item),
                        caption=None,
                        timestamp=timestamp,
                        is_video=is_video,
                    ))
            return results
        except Exception as e:
            print(f"[Instagram] Highlight items fetch failed: {e}")
            return []

    # ------------------------------------------------------------------
    # File download (no rate limiting — CDN)
    # ------------------------------------------------------------------

    def download_media_data(self, url: str) -> bytes:
        resp = self._session.get(
            url,
            headers={"Referer": "https://www.instagram.com/"},
            timeout=60,
            stream=False,
        )
        if resp.status_code != 200:
            raise InstagramError(f"Download failed: HTTP {resp.status_code}")
        if len(resp.content) < 100:
            raise InstagramError("Downloaded file suspiciously small")
        return resp.content
