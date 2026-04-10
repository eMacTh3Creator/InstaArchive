"""
tray_app.py — Windows system tray icon using pystray.
Right-click menu: Open Dashboard, Check All, Stop, Settings, Quit.
"""
import threading
import webbrowser
from pathlib import Path
from typing import Optional

from app_settings import AppSettings


def _create_icon_image():
    """Generate a simple camera-like icon using Pillow."""
    try:
        from PIL import Image, ImageDraw
        icon_path = Path(__file__).resolve().parent.parent / "assets" / "icon.ico"
        if icon_path.exists():
            return Image.open(icon_path)
        size = 64
        img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        # Background circle
        draw.ellipse([4, 4, 60, 60], fill="#6366f1")
        # Camera body
        draw.rounded_rectangle([16, 22, 48, 46], radius=4, fill="white")
        # Lens
        draw.ellipse([24, 26, 40, 42], fill="#6366f1")
        draw.ellipse([27, 29, 37, 39], fill="white")
        # Viewfinder
        draw.rectangle([38, 24, 44, 28], fill="white")
        return img
    except Exception:
        # Fallback: plain colored square
        from PIL import Image
        img = Image.new("RGB", (64, 64), "#6366f1")
        return img


class TrayApp:
    def __init__(self, web_server, download_manager, profile_store, scheduler):
        self._web_server       = web_server
        self._download_manager = download_manager
        self._profile_store    = profile_store
        self._scheduler        = scheduler
        self._settings         = AppSettings()
        self._icon             = None

    def run(self):
        """Blocking call — runs the tray icon event loop on the calling thread."""
        try:
            import pystray
            from pystray import MenuItem, Menu
        except ImportError:
            print("[Tray] pystray not installed — running headlessly")
            self._headless_run()
            return

        icon_image = _create_icon_image()

        def open_dashboard(icon, item):
            webbrowser.open(self._web_server.url)

        def check_all(icon, item):
            self._download_manager.check_all_profiles(self._profile_store)
            self._update_title(icon)

        def stop_all(icon, item):
            self._download_manager.stop_all()
            self._update_title(icon)

        def open_downloads(icon, item):
            import subprocess, os
            path = self._settings.download_path
            os.makedirs(path, exist_ok=True)
            subprocess.Popen(f'explorer "{path}"')

        def quit_app(icon, item):
            self._scheduler.stop()
            self._download_manager.stop_all()
            icon.stop()

        menu = Menu(
            MenuItem("Open Dashboard",  open_dashboard, default=True),
            Menu.SEPARATOR,
            MenuItem("Check All Profiles", check_all),
            MenuItem("Stop Downloads",     stop_all),
            Menu.SEPARATOR,
            MenuItem("Open Download Folder", open_downloads),
            Menu.SEPARATOR,
            MenuItem("Quit InstaArchive",  quit_app),
        )

        self._icon = pystray.Icon(
            "InstaArchive",
            icon_image,
            "InstaArchive",
            menu=menu,
        )
        self._icon.run()

    def _update_title(self, icon):
        dm = self._download_manager
        if dm.is_running:
            active = len(dm.active_usernames)
            icon.title = f"InstaArchive — Downloading ({active} active)"
        else:
            count = len(self._profile_store.profiles)
            icon.title = f"InstaArchive — {count} profiles"

    def _headless_run(self):
        """Run without a tray icon (e.g. in a terminal / CI)."""
        import signal
        import time
        print("[InstaArchive] Running in headless mode. Press Ctrl+C to quit.")
        stop = threading.Event()
        def _sig(sig, frame):
            stop.set()
        signal.signal(signal.SIGINT, _sig)
        signal.signal(signal.SIGTERM, _sig)
        while not stop.is_set():
            time.sleep(1)
