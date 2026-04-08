"""
thumbnail_cache.py — 3-tier thumbnail cache (memory LRU → disk JPEG → Pillow generation).
"""
import os
import threading
from collections import OrderedDict
from pathlib import Path
from typing import Optional

from app_settings import AppSettings


class ThumbnailCache:
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
        self._max_memory  = 500          # items
        self._thumb_size  = (200, 200)   # px
        self._memory: OrderedDict[str, bytes] = OrderedDict()
        self._mem_lock    = threading.Lock()
        self._in_flight:  set[str] = set()
        self._gen_lock    = threading.Lock()

        # Disk cache
        import tempfile
        cache_root = Path(tempfile.gettempdir()) / "InstaArchive" / "Thumbnails"
        cache_root.mkdir(parents=True, exist_ok=True)
        self._disk_dir = cache_root

        self._initialized = True

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get(self, instagram_id: str, local_path: Optional[str]) -> Optional[bytes]:
        """Return JPEG thumbnail bytes, generating/caching as needed. Thread-safe."""
        # 1. Memory
        hit = self._get_memory(instagram_id)
        if hit:
            return hit

        # 2. Disk
        disk_bytes = self._load_disk(instagram_id)
        if disk_bytes:
            self._put_memory(instagram_id, disk_bytes)
            return disk_bytes

        # 3. Generate
        if not local_path or not os.path.exists(local_path):
            return None

        return self._generate(instagram_id, local_path)

    def invalidate(self, instagram_id: str):
        with self._mem_lock:
            self._memory.pop(instagram_id, None)
        disk = self._disk_path(instagram_id)
        if disk.exists():
            disk.unlink(missing_ok=True)

    def clear_profile(self, username: str, ids: list[str]):
        for iid in ids:
            self.invalidate(iid)

    def clear_all(self):
        with self._mem_lock:
            self._memory.clear()
        import shutil
        shutil.rmtree(self._disk_dir, ignore_errors=True)
        self._disk_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Memory cache (LRU via OrderedDict)
    # ------------------------------------------------------------------

    def _get_memory(self, key: str) -> Optional[bytes]:
        with self._mem_lock:
            if key in self._memory:
                self._memory.move_to_end(key)
                return self._memory[key]
        return None

    def _put_memory(self, key: str, data: bytes):
        with self._mem_lock:
            if key in self._memory:
                self._memory.move_to_end(key)
            else:
                self._memory[key] = data
                if len(self._memory) > self._max_memory:
                    self._memory.popitem(last=False)

    # ------------------------------------------------------------------
    # Disk cache
    # ------------------------------------------------------------------

    def _disk_path(self, instagram_id: str) -> Path:
        return self._disk_dir / f"{instagram_id}.jpg"

    def _load_disk(self, instagram_id: str) -> Optional[bytes]:
        path = self._disk_path(instagram_id)
        if path.exists():
            try:
                return path.read_bytes()
            except OSError:
                return None
        return None

    def _save_disk(self, instagram_id: str, data: bytes):
        try:
            self._disk_path(instagram_id).write_bytes(data)
        except OSError:
            pass

    # ------------------------------------------------------------------
    # Generation via Pillow
    # ------------------------------------------------------------------

    def _generate(self, instagram_id: str, local_path: str) -> Optional[bytes]:
        # Avoid duplicate generation
        with self._gen_lock:
            if instagram_id in self._in_flight:
                return None
            self._in_flight.add(instagram_id)

        try:
            return self._do_generate(instagram_id, local_path)
        finally:
            with self._gen_lock:
                self._in_flight.discard(instagram_id)

    def _do_generate(self, instagram_id: str, local_path: str) -> Optional[bytes]:
        try:
            from PIL import Image
            import io

            with Image.open(local_path) as img:
                img = img.convert("RGB")
                img.thumbnail(self._thumb_size, Image.LANCZOS)
                buf = io.BytesIO()
                img.save(buf, format="JPEG", quality=75, optimize=True)
                data = buf.getvalue()

            self._save_disk(instagram_id, data)
            self._put_memory(instagram_id, data)
            return data
        except Exception as e:
            print(f"[ThumbnailCache] Failed to generate for {instagram_id}: {e}")
            return None
