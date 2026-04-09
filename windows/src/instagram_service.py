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
from logger import Logger

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

# NOTE: Do NOT set Accept-Encoding here. The requests library handles
# gzip/deflate/br decompression automatically; setting it manually can
# cause issues with some edge cases.
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/136.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Connection":      "keep-alive",
    "X-IG-App-ID":     APP_ID,
    "sec-ch-ua":          '"Chromium";v="136", "Google Chrome";v="136", "Not-A.Brand";v="99"',
    "sec-ch-ua-mobile":   "?0",
    "sec-ch-ua-platform": '"Windows"',
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
        self._log         = Logger()
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
                    self._log.info("Loaded saved cookies", context="session")
            except Exception as e:
                self._log.error(f"Failed to load cookies: {e}", context="session")

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
            self._log.info("Cookies saved and session ready", context="session")
        except Exception as e:
            self._log.error(f"Failed to save cookies: {e}", context="session")

    def reset_session(self):
        self._session_ready = False
        self._csrf_token = None
        # Preserve sessionid so the user doesn't have to log in again
        saved_session_id = self._session.cookies.get("sessionid", domain=".instagram.com")
        self._session.cookies.clear()
        if saved_session_id:
            self._session.cookies.set("sessionid", saved_session_id, domain=".instagram.com")
        self._settings.is_logged_in = False
        self._log.info("Session reset (sessionid preserved)", context="session")

    # ------------------------------------------------------------------
    # Rate limiting
    # ------------------------------------------------------------------

    def _wait_rate_limit(self):
        with self._rate_lock:
            jitter = random.uniform(0.3, 1.8)
            effective_interval = self._min_interval + jitter
            elapsed = time.monotonic() - self._last_request_time
            if elapsed < effective_interval:
                time.sleep(effective_interval - elapsed)
            self._last_request_time = time.monotonic()

    def _get(self, url: str, params: dict = None, referer: str = None, is_api: bool = False) -> requests.Response:
        self._wait_rate_limit()
        headers: dict[str, str] = {}
        if referer:
            headers["Referer"] = referer
            headers["Origin"] = "https://www.instagram.com"
        if is_api:
            headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
            headers["X-Requested-With"] = "XMLHttpRequest"
            headers["Sec-Fetch-Site"] = "same-origin"
            headers["Sec-Fetch-Mode"] = "cors"
            headers["Sec-Fetch-Dest"] = "empty"
            headers["dpr"] = "1"
            if self._csrf_token:
                headers["X-CSRFToken"] = self._csrf_token
        else:
            headers["Accept"] = (
                "text/html,application/xhtml+xml,application/xml;q=0.9,"
                "image/avif,image/webp,image/apng,*/*;q=0.8,"
                "application/signed-exchange;v=b3;q=0.7"
            )
            headers["Sec-Fetch-Dest"] = "document"
            headers["Sec-Fetch-Mode"] = "navigate"
            headers["Sec-Fetch-Site"] = "none"
            headers["Sec-Fetch-User"] = "?1"
            headers["Upgrade-Insecure-Requests"] = "1"
        resp = self._session.get(url, params=params, headers=headers, timeout=30)
        return resp

    # ------------------------------------------------------------------
    # Response validation
    # ------------------------------------------------------------------

    def _validate_api_response(self, resp: requests.Response, context: str):
        """Check if an API response is actually HTML instead of JSON.
        Instagram returns HTML (login page, challenge, consent) with HTTP 200
        when your session is invalid or they want additional verification."""
        content_type = resp.headers.get("Content-Type", "")
        is_html_content_type = "text/html" in content_type

        # Also check the body — Instagram sometimes omits/lies about Content-Type
        prefix = resp.text[:200] if resp.text else ""
        looks_like_html = "<!DOCTYPE" in prefix or "<html" in prefix or "<head" in prefix

        if not is_html_content_type and not looks_like_html:
            return  # Looks like JSON, proceed normally

        body = resp.text[:2000] if resp.text else ""
        self._log.error(
            f"{context}: Got HTML instead of JSON (Content-Type: {content_type}, {len(resp.content)} bytes)",
            context="api",
        )

        # Detect specific Instagram pages
        if "/accounts/login" in body or '"loginPage"' in body or '"LoginAndSignupPage"' in body:
            self._log.error(f"{context}: Instagram redirected to login page — session is expired", context="api")
            raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")

        if "/challenge/" in body or '"challenge"' in body:
            self._log.error(f"{context}: Instagram is requesting a challenge (suspicious login verification)", context="api")
            raise InstagramError(
                "Instagram requires verification. Open instagram.com in your browser, "
                "complete any security checks, then try again."
            )

        if "consent" in body or "/privacy/checks/" in body:
            self._log.error(f"{context}: Instagram is showing a consent/privacy screen", context="api")
            raise InstagramError(
                "Instagram requires you to accept updated terms. Open instagram.com in your browser, "
                "accept the prompt, then try again."
            )

        if "/accounts/suspended/" in body:
            raise InstagramError("This Instagram account appears to be suspended.")

        # Generic HTML fallback
        raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")

    # ------------------------------------------------------------------
    # Profile info
    # ------------------------------------------------------------------

    def fetch_profile_info(self, username: str) -> ProfileInfo:
        url = f"{BASE_URL}/api/v1/users/web_profile_info/"
        resp = self._get(url, params={"username": username}, referer=f"{BASE_URL}/{username}/", is_api=True)

        self._log.info(f"Profile info HTTP {resp.status_code} for @{username}", context="api")

        # Detect HTML responses disguised as 200 OK
        self._validate_api_response(resp, f"fetch_profile_info(@{username})")

        if resp.status_code == 429:
            self._log.error(f"Rate limited fetching @{username} (429)", context="api")
            raise RateLimitedError("Rate limited")
        if resp.status_code in (401, 403):
            self._log.warn(
                f"Auth failed for @{username} ({resp.status_code}), resetting session and retrying",
                context="api",
            )
            self.reset_session()
            return self._fetch_profile_info_retry(username)
        if resp.status_code == 404:
            self._log.error(f"Profile @{username} not found (404)", context="api")
            raise InstagramError("Profile not found. Check the username and try again.")
        if resp.status_code != 200:
            self._log.warn(
                f"Unexpected HTTP {resp.status_code} for @{username}, trying page scrape fallback",
                context="api",
            )
            return self._fetch_profile_info_from_page(username)

        return self._parse_profile_info(resp, username)

    def _fetch_profile_info_retry(self, username: str) -> ProfileInfo:
        """Second attempt after session reset. On failure, throw SessionError."""
        url = f"{BASE_URL}/api/v1/users/web_profile_info/"
        resp = self._get(url, params={"username": username}, referer=f"{BASE_URL}/{username}/", is_api=True)

        self._log.info(f"Profile info retry HTTP {resp.status_code} for @{username}", context="api")

        self._validate_api_response(resp, f"fetch_profile_info_retry(@{username})")

        if resp.status_code == 200:
            return self._parse_profile_info(resp, username)

        if resp.status_code in (401, 403):
            self._log.error(
                f"Auth still failing after session reset for @{username} — session may be expired",
                context="api",
            )
            raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")

        return self._fetch_profile_info_from_page(username)

    def _fetch_profile_info_from_page(self, username: str) -> ProfileInfo:
        """Fallback: scrape the profile HTML page for embedded JSON data."""
        self._log.info(f"Falling back to page scrape for @{username}", context="api")

        resp = self._get(f"{BASE_URL}/{username}/", referer=None, is_api=False)

        self._log.info(
            f"Page scrape HTTP {resp.status_code} for @{username} ({len(resp.content)} bytes)",
            context="api",
        )

        if resp.status_code == 404:
            raise InstagramError("Profile not found. Check the username and try again.")
        if resp.status_code in (401, 403):
            self._log.error(f"Instagram rejected page request for @{username}", context="api")
            raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")

        html = resp.text
        if not html:
            raise InstagramError("Could not decode profile page")

        # Check if Instagram redirected to a login page
        if '"loginPage"' in html or ("/accounts/login/" in html and "edge_owner" not in html):
            self._log.error(
                f"Instagram redirected to login page for @{username} — session expired",
                context="api",
            )
            raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")

        # Try to extract JSON from the page
        patterns = [
            r'window\._sharedData\s*=\s*({.+?});</script>',
            r'"ProfilePage":\[({.+?})\]',
            r'window\.__additionalDataLoaded\([^,]+,\s*({.+?})\);',
        ]
        for pattern in patterns:
            match = re.search(pattern, html, re.DOTALL)
            if match:
                try:
                    data = json.loads(match.group(1))
                    user = None
                    # Navigate various embedded structures
                    if "entry_data" in data:
                        pages = data.get("entry_data", {}).get("ProfilePage", [])
                        if pages:
                            user = pages[0].get("graphql", {}).get("user")
                    if not user and "graphql" in data:
                        user = data.get("graphql", {}).get("user")
                    if not user and "user" in data:
                        user = data.get("user")

                    if user and isinstance(user, dict) and user.get("username"):
                        return self._build_profile_info(user, username)
                except (json.JSONDecodeError, KeyError):
                    continue

        self._log.error(f"Could not extract profile data from page for @{username}", context="parse")
        raise InstagramError("Could not extract profile data from Instagram page.")

    def _parse_profile_info(self, resp: requests.Response, username: str) -> ProfileInfo:
        """Parse JSON response from the web_profile_info API."""
        try:
            data = resp.json()
        except ValueError:
            preview = resp.text[:500] if resp.text else "(empty)"
            self._log.error(
                f"API response is not valid JSON ({len(resp.content)} bytes). Preview: {preview}",
                context="parse",
            )
            if "<" in preview:
                raise SessionError("Instagram session expired or blocked. Log out in Settings, then log back in.")
            raise InstagramError(
                f"Instagram returned an unexpected response ({len(resp.content)} bytes). "
                "Try logging out and back in."
            )

        # Try multiple known response structures
        user = None
        if "data" in data and isinstance(data.get("data"), dict):
            user = data["data"].get("user")
        if not user and "user" in data and isinstance(data.get("user"), dict):
            user = data["user"]
        if not user and "graphql" in data:
            user = data.get("graphql", {}).get("user")
        if not user and "username" in data:
            user = data

        if not user or not isinstance(user, dict):
            status = data.get("status", "")
            message = data.get("message", "")
            top_keys = ", ".join(sorted(data.keys()))
            self._log.error(
                f"Unexpected API structure. status={status}, message={message}, keys=[{top_keys}]",
                context="parse",
            )
            if status == "fail" or message:
                raise InstagramError(message or "Instagram rejected the request")
            raise InstagramError(f"Instagram API changed format. Top-level keys: [{top_keys}].")

        return self._build_profile_info(user, username)

    def _build_profile_info(self, user: dict, fallback_username: str) -> ProfileInfo:
        """Build a ProfileInfo from a user dict (shared by API and page scrape paths)."""
        username = user.get("username", fallback_username)

        # User ID: handle int, int-as-string, or string
        user_id = ""
        for key in ("id", "pk"):
            val = user.get(key)
            if val is not None:
                user_id = str(val)
                if user_id:
                    break

        if user_id:
            self._cached_user_ids[username] = user_id

        # Post count: try both GraphQL and v1 API field names
        post_count = (
            user.get("edge_owner_to_timeline_media", {}).get("count", 0)
            or user.get("media_count", 0)
        )

        # Follower count: try both field names
        follower_count = (
            user.get("edge_followed_by", {}).get("count", 0)
            or user.get("follower_count", 0)
        )

        self._log.info(f"Parsed profile @{username} (id={user_id}, posts={post_count})", context="parse")

        return ProfileInfo(
            username=username,
            full_name=user.get("full_name", ""),
            biography=user.get("biography", ""),
            profile_pic_url=user.get("profile_pic_url_hd") or user.get("profile_pic_url", ""),
            is_private=user.get("is_private", False),
            post_count=post_count,
            follower_count=follower_count,
            user_id=user_id,
        )

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

        self._log.info(f"Fetched {len(all_media)} new media items for @{username}", context="api")
        return all_media

    def _fetch_page_v1(self, user_id: str, cursor: Optional[str]) -> tuple[list, Optional[str]]:
        url = f"{BASE_URL}/api/v1/feed/user/{user_id}/"
        params = {"count": "33"}
        if cursor:
            params["max_id"] = cursor
        try:
            resp = self._get(url, params=params, referer=BASE_URL + "/", is_api=True)
            self._log.info(f"v1 feed HTTP {resp.status_code} for user {user_id}", context="api")
            if resp.status_code != 200:
                return [], None
            data = resp.json()
            items = data.get("items", [])
            next_cursor = data.get("next_max_id")
            return items, next_cursor
        except Exception as e:
            self._log.warn(f"v1 page fetch failed: {e}", context="api")
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
                is_api=True,
            )
            self._log.info(f"GraphQL feed HTTP {resp.status_code} for @{username}", context="api")
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
            self._log.warn(f"GraphQL page fetch failed: {e}", context="api")
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
            self._log.warn(f"Failed to parse media node: {e}", context="parse")
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
            resp = self._get(url, referer=f"{BASE_URL}/{username}/", is_api=True)
            self._log.info(f"Stories HTTP {resp.status_code} for @{username}", context="api")
            if resp.status_code != 200:
                self._log.warn(f"Stories returned HTTP {resp.status_code} for @{username}", context="api")
                return []
            self._validate_api_response(resp, f"fetch_stories(@{username})")
            data = resp.json()
            reel = data.get("reel") or data.get("reels", {}).get(user_id, {})
            items = reel.get("items", []) if reel else []
            results = []
            for item in items:
                media = self._parse_story_item(item, username)
                if media:
                    results.append(media)
            self._log.info(f"Found {len(results)} stories for @{username}", context="api")
            return results
        except (SessionError, InstagramError):
            raise
        except Exception as e:
            self._log.warn(f"Stories fetch failed for @{username}: {e}", context="api")
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
        self._log.info(f"Found {len(results)} highlight items for @{username}", context="api")
        return results

    def _fetch_highlight_reel_ids(self, user_id: str, username: str) -> list[str]:
        url = f"{BASE_URL}/api/v1/highlights/{user_id}/highlights_tray/"
        try:
            resp = self._get(url, referer=f"{BASE_URL}/{username}/", is_api=True)
            self._log.info(f"Highlights tray HTTP {resp.status_code} for @{username}", context="api")
            if resp.status_code != 200:
                return []
            self._validate_api_response(resp, f"fetch_highlights(@{username})")
            data = resp.json()
            tray = data.get("tray", [])
            return [str(r.get("id", "")) for r in tray if r.get("id")]
        except (SessionError, InstagramError):
            raise
        except Exception as e:
            self._log.warn(f"Highlight IDs fetch failed for @{username}: {e}", context="api")
            return []

    def _fetch_highlight_items(self, reel_id: str, username: str) -> list[DiscoveredMedia]:
        full_id = reel_id if reel_id.startswith("highlight:") else f"highlight:{reel_id}"
        url = f"{BASE_URL}/api/v1/feed/reels_media/"
        try:
            resp = self._get(url, params={"reel_ids": full_id}, referer=f"{BASE_URL}/{username}/", is_api=True)
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
        except (SessionError, InstagramError):
            raise
        except Exception as e:
            self._log.warn(f"Highlight items fetch failed: {e}", context="api")
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
