"""
main.py — Entry point for InstaArchive Windows.
Starts the web server, scheduler, and system tray icon.
"""
import sys
import threading

from app_settings import AppSettings
from profile_store import ProfileStore
from download_manager import DownloadManager
from scheduler import SchedulerService
from web_server import WebServer
from tray_app import TrayApp


def main():
    settings = AppSettings()

    # Core singletons
    profile_store    = ProfileStore()
    download_manager = DownloadManager()
    scheduler        = SchedulerService()
    web_server       = WebServer()

    # Start the web server
    if settings.web_server_enabled:
        web_server.start()

    # Start background scheduler
    scheduler.start(profile_store, download_manager)

    # Open dashboard in browser on first launch
    import webbrowser
    t = threading.Timer(1.0, lambda: webbrowser.open(web_server.url))
    t.daemon = True
    t.start()

    # Run tray icon (blocking — keeps app alive)
    tray = TrayApp(web_server, download_manager, profile_store, scheduler)
    tray.run()


if __name__ == "__main__":
    # On Windows, freeze_support() is needed for multiprocessing with PyInstaller
    import multiprocessing
    multiprocessing.freeze_support()
    main()
