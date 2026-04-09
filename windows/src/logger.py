"""
logger.py — Rotating log file for InstaArchive (Windows).
Keeps the last 20 entries in %APPDATA%/InstaArchive/logs/instaarchive.log.
Mirrors the macOS Logger.swift behavior.
"""
import os
import threading
from datetime import datetime
from pathlib import Path


def _log_dir() -> Path:
    base = os.environ.get("APPDATA", str(Path.home()))
    d = Path(base) / "InstaArchive" / "logs"
    d.mkdir(parents=True, exist_ok=True)
    return d


class Logger:
    _instance = None
    _lock_cls = threading.Lock()

    MAX_ENTRIES = 20

    def __new__(cls):
        with cls._lock_cls:
            if cls._instance is None:
                cls._instance = super().__new__(cls)
                cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._log_dir = _log_dir()
        self._log_path = self._log_dir / "instaarchive.log"
        self._entries: list[str] = []
        self._lock = threading.Lock()
        self._load()
        self._initialized = True

    @property
    def log_directory(self) -> Path:
        return self._log_dir

    def _load(self):
        if self._log_path.exists():
            try:
                text = self._log_path.read_text(encoding="utf-8").strip()
                if text:
                    self._entries = text.split("\n")[-self.MAX_ENTRIES:]
            except Exception:
                self._entries = []

    def _persist(self):
        try:
            self._log_path.write_text(
                "\n".join(self._entries[-self.MAX_ENTRIES:]) + "\n",
                encoding="utf-8",
            )
        except Exception:
            pass

    def _add(self, level: str, message: str, context: str = ""):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        ctx = f"[{context}] " if context else ""
        entry = f"[{ts}] [{level}] {ctx}{message}"
        with self._lock:
            self._entries.append(entry)
            if len(self._entries) > self.MAX_ENTRIES:
                self._entries = self._entries[-self.MAX_ENTRIES:]
            self._persist()
        # Also print for console/debug
        print(entry)

    def info(self, message: str, context: str = ""):
        self._add("INFO", message, context)

    def warn(self, message: str, context: str = ""):
        self._add("WARN", message, context)

    def error(self, message: str, context: str = ""):
        self._add("ERROR", message, context)

    def recent_entries(self, count: int = 20) -> list[str]:
        with self._lock:
            return list(self._entries[-count:])
