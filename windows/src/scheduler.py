"""
scheduler.py — Periodic background checks using APScheduler.
"""
import threading
from datetime import datetime, timedelta
from typing import Optional

from app_settings import AppSettings


class SchedulerService:
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
        self._scheduler  = None
        self._profile_store = None
        self._download_manager = None
        self.is_active: bool = False
        self.next_check: Optional[datetime] = None
        self._initialized = True

    def start(self, profile_store, download_manager):
        self._profile_store    = profile_store
        self._download_manager = download_manager
        self._start_scheduler()

    def _start_scheduler(self):
        try:
            from apscheduler.schedulers.background import BackgroundScheduler
        except ImportError:
            print("[Scheduler] APScheduler not installed — scheduling disabled")
            return

        if self._scheduler and self._scheduler.running:
            self._scheduler.shutdown(wait=False)

        interval_hours = self._settings.check_interval_hours
        self._scheduler = BackgroundScheduler(daemon=True)
        self._scheduler.add_job(
            self._run_check,
            trigger="interval",
            hours=interval_hours,
            id="profile_check",
            replace_existing=True,
        )
        self._scheduler.start()
        self.is_active = True
        self.next_check = datetime.now() + timedelta(hours=interval_hours)
        print(f"[Scheduler] Started — interval {interval_hours}h, next check {self.next_check}")

    def stop(self):
        if self._scheduler and self._scheduler.running:
            self._scheduler.shutdown(wait=False)
        self.is_active = False
        self.next_check = None
        print("[Scheduler] Stopped")

    def restart(self):
        self.stop()
        self._start_scheduler()

    def _run_check(self):
        print("[Scheduler] Running scheduled check...")
        if self._profile_store and self._download_manager:
            self._download_manager.check_all_profiles(self._profile_store)
        interval_hours = self._settings.check_interval_hours
        self.next_check = datetime.now() + timedelta(hours=interval_hours)
