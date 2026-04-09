"""
ui.py — Native PyQt6 desktop UI for InstaArchive (Windows).
Communicates with the Flask backend API on localhost.
"""

import json
import os
import subprocess
import sys
import webbrowser
from datetime import datetime
from pathlib import Path

import requests as _req
from PyQt6.QtCore import Qt, QTimer, QThread, pyqtSignal, QUrl, QSize
from PyQt6.QtGui import (
    QFont, QColor, QPalette, QPixmap, QPainter,
    QBrush, QLinearGradient, QCursor, QIcon,
)
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QLineEdit, QFrame, QScrollArea, QGridLayout,
    QMessageBox, QDialog, QStackedWidget, QToolButton, QComboBox,
    QCheckBox, QSpinBox, QSizePolicy,
)

# Optional: native login via embedded browser
try:
    from PyQt6.QtWebEngineWidgets import QWebEngineView
    from PyQt6.QtWebEngineCore import QWebEngineProfile, QWebEnginePage
    HAS_WEBENGINE = True
except ImportError:
    HAS_WEBENGINE = False

# ---------------------------------------------------------------------------
# Backend API base
# ---------------------------------------------------------------------------

API = "http://localhost:8485"
APPDATA_DIR = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "InstaArchive"
COOKIES_PATH = APPDATA_DIR / "cookies.json"
PICTURES_DIR = Path(os.environ.get("USERPROFILE", Path.home())) / "Pictures" / "InstaArchive"
MEDIA_TYPES = ["Posts", "Reels", "Videos", "Highlights", "Stories", "Profile Pictures"]

# ---------------------------------------------------------------------------
# Theme constants
# ---------------------------------------------------------------------------

BG       = "#0d0d0d"
CARD     = "#161616"
CARD2    = "#1c1c1c"
BORDER   = "#272727"
TEXT     = "#efefef"
SUB      = "#777"
ACCENT   = "#a78bfa"
ACCENT2  = "#7c3aed"
GREEN    = "#4ade80"
GREEN_BG = "#052e16"
GREEN_BD = "#14532d"
RED      = "#f87171"
RED_BG   = "#1a0808"
RED_BD   = "#7f1d1d"
ORANGE   = "#fb923c"

STYLESHEET = f"""
QWidget {{ background:{BG}; color:{TEXT}; font-family:'Segoe UI',Arial,sans-serif; font-size:13px; border:none; }}
QMainWindow, QDialog {{ background:{BG}; }}
QScrollArea {{ background:transparent; border:none; }}
QScrollArea > QWidget > QWidget {{ background:transparent; }}
QScrollBar:vertical {{ background:{BG}; width:5px; margin:0; }}
QScrollBar::handle:vertical {{ background:#333; border-radius:2px; min-height:20px; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height:0; }}
QScrollBar:horizontal {{ background:{BG}; height:5px; margin:0; }}
QScrollBar::handle:horizontal {{ background:#333; border-radius:2px; min-width:20px; }}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {{ width:0; }}
QPushButton {{ background:{CARD2}; color:{TEXT}; border:1px solid {BORDER}; border-radius:7px; padding:6px 16px; font-size:12px; font-weight:500; }}
QPushButton:hover {{ background:#222; border-color:#3a3a3a; }}
QPushButton:pressed {{ background:#111; }}
QPushButton#primary {{ background:qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 {ACCENT2},stop:1 {ACCENT}); color:#fff; border:none; font-weight:600; border-radius:7px; }}
QPushButton#primary:hover {{ background:{ACCENT2}; }}
QPushButton#danger {{ background:{RED_BG}; color:{RED}; border:1px solid {RED_BD}; border-radius:7px; }}
QPushButton#danger:hover {{ background:#220a0a; }}
QPushButton#sync {{ background:{GREEN_BG}; color:{GREEN}; border:1px solid {GREEN_BD}; border-radius:7px; }}
QPushButton#sync:hover {{ background:#063a1a; }}
QPushButton#ghost {{ background:transparent; color:{ACCENT}; border:none; font-size:12px; padding:4px 8px; }}
QPushButton#ghost:hover {{ color:{TEXT}; }}
QLineEdit {{ background:{CARD}; border:1px solid {BORDER}; border-radius:7px; padding:8px 12px; color:{TEXT}; font-size:13px; }}
QLineEdit:focus {{ border-color:{ACCENT}; }}
QFrame#sidebar {{ background:{CARD}; border-right:1px solid {BORDER}; }}
QFrame#profileRow {{ background:{CARD}; border:1px solid {BORDER}; border-radius:10px; }}
QFrame#profileRow:hover {{ border-color:#3a3a3a; background:#181818; }}
QFrame#statCard {{ background:{CARD}; border:1px solid {BORDER}; border-radius:10px; }}
QLabel#sectionHead {{ font-size:10px; font-weight:700; color:{SUB}; letter-spacing:1.5px; }}
QLabel#heading {{ font-size:18px; font-weight:700; color:{TEXT}; }}
QLabel#sub {{ color:{SUB}; font-size:12px; }}
QToolButton#collapse {{ background:transparent; border:none; color:{TEXT}; font-size:13px; font-weight:600; text-align:left; padding:8px 0; }}
QToolButton#collapse:hover {{ color:{ACCENT}; }}
QComboBox {{ background:{CARD}; border:1px solid {BORDER}; border-radius:7px; padding:6px 12px; color:{TEXT}; font-size:13px; }}
QComboBox:hover {{ border-color:#3a3a3a; }}
QComboBox::drop-down {{ border:none; }}
QComboBox QAbstractItemView {{ background:{CARD}; color:{TEXT}; border:1px solid {BORDER}; selection-background-color:{ACCENT2}; }}
QSpinBox {{ background:{CARD}; border:1px solid {BORDER}; border-radius:7px; padding:6px 12px; color:{TEXT}; font-size:13px; }}
QSpinBox:focus {{ border-color:{ACCENT}; }}
QCheckBox {{ color:{TEXT}; font-size:13px; spacing:8px; }}
QCheckBox::indicator {{ width:16px; height:16px; border-radius:4px; border:1px solid {BORDER}; background:{CARD}; }}
QCheckBox::indicator:checked {{ background:{ACCENT2}; border-color:{ACCENT2}; }}
"""


# ---------------------------------------------------------------------------
# Reusable widgets
# ---------------------------------------------------------------------------

class Avatar(QLabel):
    """Generates a gradient circle with the first letter of a username."""
    def __init__(self, letter: str, size: int = 36, parent=None):
        super().__init__(parent)
        self.setFixedSize(size, size)
        pix = QPixmap(size, size)
        pix.fill(Qt.GlobalColor.transparent)
        p = QPainter(pix)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        g = QLinearGradient(0, 0, size, size)
        g.setColorAt(0.0, QColor("#7c3aed"))
        g.setColorAt(0.5, QColor("#ec4899"))
        g.setColorAt(1.0, QColor("#f97316"))
        p.setBrush(QBrush(g))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(0, 0, size, size)
        p.setPen(QColor("#fff"))
        p.setFont(QFont("Segoe UI", int(size * 0.38), QFont.Weight.Bold))
        p.drawText(pix.rect(), Qt.AlignmentFlag.AlignCenter, letter.upper())
        p.end()
        self.setPixmap(pix)


class StatCard(QFrame):
    """Small card displaying a value + label."""
    def __init__(self, value: str, label: str, parent=None):
        super().__init__(parent)
        self.setObjectName("statCard")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(3)
        self._v = QLabel(value)
        self._v.setFont(QFont("Segoe UI", 20, QFont.Weight.Bold))
        self._l = QLabel(label.upper())
        self._l.setObjectName("sectionHead")
        lay.addWidget(self._v)
        lay.addWidget(self._l)

    def set(self, v: str):
        self._v.setText(v)


class Thumb(QLabel):
    """Clickable thumbnail that opens the file."""
    def __init__(self, path: Path, size: int = 110, parent=None):
        super().__init__(parent)
        self.setFixedSize(size, size)
        self._path = path
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        if path.suffix.lower() in (".mp4", ".mov"):
            self.setText("\u25b6")
            self.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self.setStyleSheet(f"border-radius:6px;background:{CARD2};color:{SUB};font-size:24px;")
        else:
            pix = QPixmap(str(path))
            if pix.isNull():
                self.setText("?")
                self.setAlignment(Qt.AlignmentFlag.AlignCenter)
                self.setStyleSheet(f"border-radius:6px;background:{CARD2};color:{SUB};")
            else:
                self.setPixmap(pix.scaled(
                    size, size,
                    Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                    Qt.TransformationMode.SmoothTransformation,
                ))
                self.setStyleSheet("border-radius:6px;")
        self.setScaledContents(False)

    def mousePressEvent(self, _):
        if sys.platform == "win32":
            os.startfile(str(self._path))
        else:
            subprocess.Popen(["open", str(self._path)])


class MediaSection(QWidget):
    """Collapsible grid of thumbnails for a given media type."""
    def __init__(self, title: str, files: list, parent=None):
        super().__init__(parent)
        self.setStyleSheet("background:transparent;")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        hdr = QHBoxLayout()
        hdr.setContentsMargins(0, 0, 0, 0)
        self._btn = QToolButton()
        self._btn.setObjectName("collapse")
        self._btn.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self._btn.setCheckable(True)
        self._btn.setChecked(True)
        self._btn.setText(f"\u25be  {title}  ({len(files)})")
        self._btn.clicked.connect(self._toggle)
        hdr.addWidget(self._btn)
        hdr.addStretch()
        lay.addLayout(hdr)

        div = QFrame()
        div.setFixedHeight(1)
        div.setStyleSheet(f"background:{BORDER};")
        lay.addWidget(div)
        lay.addSpacing(10)

        self._body = QWidget()
        self._body.setStyleSheet("background:transparent;")
        grid = QGridLayout(self._body)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(6)
        cols = 6
        for i, f in enumerate(files[:60]):
            grid.addWidget(Thumb(f, 110), i // cols, i % cols)
        if not files:
            grid.addWidget(QLabel("No media yet."), 0, 0)
        lay.addWidget(self._body)
        lay.addSpacing(20)

    def _toggle(self, checked: bool):
        self._body.setVisible(checked)
        t = self._btn.text()
        self._btn.setText(("\u25be" if checked else "\u25b8") + t[1:])


# ---------------------------------------------------------------------------
# Login dialog (embedded browser or fallback)
# ---------------------------------------------------------------------------

class LoginDialog(QDialog):
    success = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Log In to Instagram")
        self.resize(500, 700)
        self.setModal(True)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)

        if HAS_WEBENGINE:
            info = QLabel("Log in below \u2014 window closes automatically once session is captured.")
            info.setWordWrap(True)
            info.setStyleSheet(f"padding:10px 14px;color:{SUB};font-size:12px;")
            lay.addWidget(info)
            self._profile = QWebEngineProfile("InstaLogin", self)
            self._page = QWebEnginePage(self._profile, self)
            self._view = QWebEngineView(self)
            self._view.setPage(self._page)
            self._view.load(QUrl("https://www.instagram.com/accounts/login/"))
            lay.addWidget(self._view)
            self._cookies: dict = {}
            self._done = False
            self._profile.cookieStore().cookieAdded.connect(self._on_cookie)
        else:
            lay.setContentsMargins(24, 24, 24, 24)
            lay.setSpacing(16)
            info = QLabel(
                "PyQt6-WebEngine is not installed.\n\n"
                "Please log in to Instagram in your regular browser, then paste your "
                "session cookies below.\n\n"
                "Alternatively, install PyQt6-WebEngine:\n"
                "  pip install PyQt6-WebEngine"
            )
            info.setWordWrap(True)
            info.setStyleSheet(f"color:{SUB};font-size:13px;")
            lay.addWidget(info)

            btn_open = QPushButton("Open Instagram in Browser")
            btn_open.setObjectName("primary")
            btn_open.clicked.connect(lambda: webbrowser.open("https://www.instagram.com/accounts/login/"))
            lay.addWidget(btn_open)
            lay.addStretch()

            close_btn = QPushButton("Close")
            close_btn.clicked.connect(self.reject)
            lay.addWidget(close_btn)

    def _on_cookie(self, cookie):
        name = cookie.name().data().decode("utf-8", errors="ignore")
        value = cookie.value().data().decode("utf-8", errors="ignore")
        self._cookies[name] = {"name": name, "value": value, "domain": cookie.domain()}
        if name == "sessionid" and value and not self._done:
            self._done = True
            QTimer.singleShot(1500, self._finalize)

    def _finalize(self):
        APPDATA_DIR.mkdir(parents=True, exist_ok=True)
        COOKIES_PATH.write_text(json.dumps(list(self._cookies.values()), indent=2))
        # Also push cookies to backend via API
        try:
            _req.post(f"{API}/api/login/cookies", json=list(self._cookies.values()), timeout=5)
        except Exception:
            pass
        self.success.emit()
        self.accept()


# ---------------------------------------------------------------------------
# Background API worker
# ---------------------------------------------------------------------------

class Worker(QThread):
    profiles_done = pyqtSignal(list)
    status_done   = pyqtSignal(dict)
    profile_done  = pyqtSignal(dict)
    settings_done = pyqtSignal(dict)
    err           = pyqtSignal(str)

    def __init__(self, action: str, arg: str = "", payload: dict = None):
        super().__init__()
        self.action = action
        self.arg = arg
        self.payload = payload

    def run(self):
        try:
            if self.action == "profiles":
                self.profiles_done.emit(_req.get(f"{API}/api/profiles", timeout=5).json())
            elif self.action == "status":
                self.status_done.emit(_req.get(f"{API}/api/status", timeout=5).json())
            elif self.action == "profile":
                self.profile_done.emit(_req.get(f"{API}/api/profile/{self.arg}", timeout=5).json())
            elif self.action == "sync":
                _req.post(f"{API}/api/sync/{self.arg}", timeout=5)
            elif self.action == "sync_all":
                _req.post(f"{API}/api/sync/all", timeout=5)
            elif self.action == "add":
                _req.post(f"{API}/api/profiles", json={"username": self.arg}, timeout=10)
            elif self.action == "remove":
                _req.delete(f"{API}/api/profiles/{self.arg}", timeout=5)
            elif self.action == "stop":
                _req.post(f"{API}/api/stop", timeout=5)
            elif self.action == "skip":
                _req.post(f"{API}/api/skip/{self.arg}", timeout=5)
            elif self.action == "settings_get":
                self.settings_done.emit(_req.get(f"{API}/api/settings", timeout=5).json())
            elif self.action == "settings_save":
                _req.post(f"{API}/api/settings", json=self.payload, timeout=5)
        except Exception as e:
            self.err.emit(str(e))


# ---------------------------------------------------------------------------
# Profile row
# ---------------------------------------------------------------------------

class ProfileRow(QFrame):
    clicked    = pyqtSignal(str)
    sync_req   = pyqtSignal(str)
    remove_req = pyqtSignal(str)

    def __init__(self, p: dict, parent=None):
        super().__init__(parent)
        self.setObjectName("profileRow")
        self.username = p["username"]
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.setFixedHeight(66)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 0, 14, 0)
        lay.setSpacing(12)
        lay.addWidget(Avatar(self.username[0], 38))

        info = QVBoxLayout()
        info.setSpacing(2)
        name = QLabel(f"@{p['username']}")
        name.setFont(QFont("Segoe UI", 13, QFont.Weight.Medium))
        parts = [f"{p.get('totalDownloaded', 0)} items"]
        if p.get("displayName") and p["displayName"] != p["username"]:
            parts.append(p["displayName"])
        meta = QLabel("  \u00b7  ".join(parts))
        meta.setObjectName("sub")
        info.addWidget(name)
        info.addWidget(meta)
        lay.addLayout(info, 1)

        status = p.get("status", "idle")
        badge = QLabel()
        badge.setFixedHeight(22)
        if status.startswith("downloading"):
            pct = status.split(":")[1] if ":" in status else ""
            badge.setText(f"  Syncing {pct}%  " if pct else "  Syncing  ")
            badge.setStyleSheet(
                f"color:{ACCENT};background:#1e1b4b;border-radius:5px;font-size:10px;font-weight:700;padding:2px 6px;"
            )
        elif p.get("isActive"):
            badge.setText("  Active  ")
            badge.setStyleSheet(
                f"color:{GREEN};background:{GREEN_BG};border-radius:5px;font-size:10px;font-weight:700;padding:2px 6px;"
            )
        else:
            badge.setText("  Paused  ")
            badge.setStyleSheet(
                f"color:{ORANGE};background:#1c1105;border-radius:5px;font-size:10px;font-weight:700;padding:2px 6px;"
            )
        lay.addWidget(badge)

        bs = QPushButton("Sync")
        bs.setObjectName("sync")
        bs.setFixedSize(60, 30)
        bs.clicked.connect(lambda: self.sync_req.emit(self.username))
        br = QPushButton("Remove")
        br.setObjectName("danger")
        br.setFixedSize(72, 30)
        br.clicked.connect(lambda: self.remove_req.emit(self.username))
        lay.addWidget(bs)
        lay.addWidget(br)

    def mousePressEvent(self, e):
        self.clicked.emit(self.username)


# ---------------------------------------------------------------------------
# Profile detail panel
# ---------------------------------------------------------------------------

class DetailPanel(QWidget):
    back       = pyqtSignal()
    sync_req   = pyqtSignal(str)
    remove_req = pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._username = ""
        self.setStyleSheet("background:transparent;")
        root = QVBoxLayout(self)
        root.setContentsMargins(28, 24, 28, 24)
        root.setSpacing(0)

        back_btn = QPushButton("\u2190 Back to Profiles")
        back_btn.setObjectName("ghost")
        back_btn.setFixedWidth(160)
        back_btn.clicked.connect(self.back.emit)
        root.addWidget(back_btn)
        root.addSpacing(16)

        hdr = QHBoxLayout()
        hdr.setSpacing(16)
        self._av_container = QWidget()
        self._av_container.setFixedSize(60, 60)
        self._av_container.setStyleSheet("background:transparent;")
        av_lay = QVBoxLayout(self._av_container)
        av_lay.setContentsMargins(0, 0, 0, 0)
        self._av = Avatar("?", 60)
        av_lay.addWidget(self._av)
        hdr.addWidget(self._av_container)

        col = QVBoxLayout()
        col.setSpacing(4)
        self._name_lbl = QLabel("@username")
        self._name_lbl.setObjectName("heading")
        self._display_lbl = QLabel("")
        self._display_lbl.setObjectName("sub")
        self._bio_lbl = QLabel("")
        self._bio_lbl.setObjectName("sub")
        self._bio_lbl.setWordWrap(True)
        col.addWidget(self._name_lbl)
        col.addWidget(self._display_lbl)
        col.addWidget(self._bio_lbl)
        hdr.addLayout(col, 1)
        root.addLayout(hdr)
        root.addSpacing(20)

        acts = QHBoxLayout()
        acts.setSpacing(10)
        self._sync_btn = QPushButton("Sync Now")
        self._sync_btn.setObjectName("sync")
        self._sync_btn.setFixedHeight(34)
        self._remove_btn = QPushButton("Remove Profile")
        self._remove_btn.setObjectName("danger")
        self._remove_btn.setFixedHeight(34)
        open_btn = QPushButton("Open Folder")
        open_btn.setFixedHeight(34)
        self._sync_btn.clicked.connect(lambda: self.sync_req.emit(self._username))
        self._remove_btn.clicked.connect(lambda: self.remove_req.emit(self._username))
        open_btn.clicked.connect(self._open_folder)
        acts.addWidget(self._sync_btn)
        acts.addWidget(self._remove_btn)
        acts.addWidget(open_btn)
        acts.addStretch()
        root.addLayout(acts)
        root.addSpacing(20)

        self._sg = QGridLayout()
        self._sg.setSpacing(10)
        self._sc: dict[str, StatCard] = {}
        labels = ["Total Media", "Storage Used", "Last Checked",
                  "Last New Content", "Date Added", "Status"]
        for i, lbl in enumerate(labels):
            c = StatCard("-", lbl)
            self._sc[lbl] = c
            self._sg.addWidget(c, i // 3, i % 3)
        root.addLayout(self._sg)
        root.addSpacing(24)

        mh = QLabel("MEDIA")
        mh.setObjectName("sectionHead")
        root.addWidget(mh)
        root.addSpacing(10)

        self._media_container = QWidget()
        self._media_container.setStyleSheet("background:transparent;")
        self._media_lay = QVBoxLayout(self._media_container)
        self._media_lay.setContentsMargins(0, 0, 0, 0)
        self._media_lay.setSpacing(0)
        self._media_lay.addStretch()
        root.addWidget(self._media_container, 1)

    def _open_folder(self):
        d = PICTURES_DIR / self._username
        if d.exists():
            if sys.platform == "win32":
                os.startfile(str(d))
            else:
                subprocess.Popen(["open", str(d)])

    def load(self, data: dict):
        self._username = data.get("username", "")
        # Replace avatar
        lay = self._av_container.layout()
        old = lay.itemAt(0)
        if old and old.widget():
            old.widget().deleteLater()
        self._av = Avatar(self._username[0] if self._username else "?", 60)
        lay.addWidget(self._av)

        self._name_lbl.setText(f"@{self._username}")
        disp = data.get("displayName", "")
        self._display_lbl.setText(disp if disp != self._username else "")
        self._bio_lbl.setText(data.get("bio", ""))

        def fmt_bytes(b):
            b = b or 0
            for u in ("B", "KB", "MB", "GB"):
                if b < 1024:
                    return f"{b:.1f} {u}" if u != "B" else f"{int(b)} B"
                b /= 1024
            return f"{b:.1f} TB"

        def fmt_date(iso):
            if not iso:
                return "Never"
            try:
                return datetime.fromisoformat(iso.replace("Z", "")).strftime("%m/%d/%Y %I:%M %p")
            except Exception:
                return iso

        stats = {
            "Total Media": str(data.get("totalIndexed", 0)),
            "Storage Used": fmt_bytes(data.get("totalFileSize", 0)),
            "Last Checked": fmt_date(data.get("lastChecked")),
            "Last New Content": fmt_date(data.get("lastNewContent")),
            "Date Added": fmt_date(data.get("dateAdded")),
            "Status": "Active" if data.get("isActive") else "Paused",
        }
        for k, v in stats.items():
            if k in self._sc:
                self._sc[k].set(v)

        self._load_media()

    def _load_media(self):
        while self._media_lay.count() > 1:
            item = self._media_lay.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        profile_dir = PICTURES_DIR / self._username
        found = False
        for mt in MEDIA_TYPES:
            d = profile_dir / mt
            if not d.exists():
                continue
            files = sorted(
                [f for f in d.iterdir() if f.suffix.lower() in {".jpg", ".jpeg", ".png", ".mp4", ".mov"}],
                key=lambda f: f.stat().st_mtime,
                reverse=True,
            )
            if not files:
                continue
            found = True
            self._media_lay.insertWidget(self._media_lay.count() - 1, MediaSection(mt, files))
        if not found:
            lbl = QLabel("No media downloaded yet. Hit Sync to start.")
            lbl.setObjectName("sub")
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self._media_lay.insertWidget(0, lbl)


# ---------------------------------------------------------------------------
# Settings panel
# ---------------------------------------------------------------------------

class SettingsPanel(QWidget):
    back = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setStyleSheet("background:transparent;")
        self._workers: list[Worker] = []
        root = QVBoxLayout(self)
        root.setContentsMargins(28, 24, 28, 24)
        root.setSpacing(0)

        back_btn = QPushButton("\u2190 Back")
        back_btn.setObjectName("ghost")
        back_btn.setFixedWidth(100)
        back_btn.clicked.connect(self.back.emit)
        root.addWidget(back_btn)
        root.addSpacing(12)

        title = QLabel("Settings")
        title.setObjectName("heading")
        root.addWidget(title)
        root.addSpacing(20)

        form = QGridLayout()
        form.setSpacing(12)
        form.setColumnMinimumWidth(0, 180)
        row = 0

        # Download path
        form.addWidget(QLabel("Download Path"), row, 0)
        self._path_edit = QLineEdit()
        self._path_edit.setPlaceholderText("~/Pictures/InstaArchive")
        form.addWidget(self._path_edit, row, 1)
        row += 1

        # Check interval
        form.addWidget(QLabel("Check Interval"), row, 0)
        self._interval_combo = QComboBox()
        self._interval_combo.addItems(["1 hour", "3 hours", "6 hours", "12 hours", "24 hours", "3 days", "7 days"])
        self._interval_values = [1, 3, 6, 12, 24, 72, 168]
        form.addWidget(self._interval_combo, row, 1)
        row += 1

        # Content types
        form.addWidget(QLabel("Content Types"), row, 0)
        ct_layout = QVBoxLayout()
        ct_layout.setSpacing(6)
        self._cb_posts = QCheckBox("Posts")
        self._cb_reels = QCheckBox("Reels")
        self._cb_videos = QCheckBox("Videos")
        self._cb_highlights = QCheckBox("Highlights")
        self._cb_stories = QCheckBox("Stories")
        for cb in [self._cb_posts, self._cb_reels, self._cb_videos, self._cb_highlights, self._cb_stories]:
            ct_layout.addWidget(cb)
        ct_widget = QWidget()
        ct_widget.setLayout(ct_layout)
        ct_widget.setStyleSheet("background:transparent;")
        form.addWidget(ct_widget, row, 1)
        row += 1

        # Concurrent profiles
        form.addWidget(QLabel("Concurrent Profiles"), row, 0)
        self._conc_profiles = QSpinBox()
        self._conc_profiles.setRange(1, 10)
        form.addWidget(self._conc_profiles, row, 1)
        row += 1

        # Concurrent files
        form.addWidget(QLabel("Files per Profile"), row, 0)
        self._conc_files = QSpinBox()
        self._conc_files.setRange(1, 20)
        form.addWidget(self._conc_files, row, 1)
        row += 1

        # Web server port
        form.addWidget(QLabel("Web Server Port"), row, 0)
        self._port_spin = QSpinBox()
        self._port_spin.setRange(1024, 65535)
        form.addWidget(self._port_spin, row, 1)
        row += 1

        # Web password
        form.addWidget(QLabel("Web Password"), row, 0)
        self._password_edit = QLineEdit()
        self._password_edit.setPlaceholderText("Leave blank for no password")
        form.addWidget(self._password_edit, row, 1)
        row += 1

        root.addLayout(form)
        root.addSpacing(24)

        save_btn = QPushButton("Save Settings")
        save_btn.setObjectName("primary")
        save_btn.setFixedHeight(40)
        save_btn.setFixedWidth(200)
        save_btn.clicked.connect(self._save)
        root.addWidget(save_btn)
        root.addStretch()

    def load_settings(self):
        w = Worker("settings_get")
        w.settings_done.connect(self._apply)
        w.finished.connect(lambda: self._workers.remove(w) if w in self._workers else None)
        self._workers.append(w)
        w.start()

    def _apply(self, data: dict):
        self._path_edit.setText(data.get("download_path", ""))
        hours = data.get("check_interval_hours", 24)
        if hours in self._interval_values:
            self._interval_combo.setCurrentIndex(self._interval_values.index(hours))
        self._cb_posts.setChecked(data.get("download_posts", True))
        self._cb_reels.setChecked(data.get("download_reels", True))
        self._cb_videos.setChecked(data.get("download_videos", True))
        self._cb_highlights.setChecked(data.get("download_highlights", True))
        self._cb_stories.setChecked(data.get("download_stories", False))
        self._conc_profiles.setValue(data.get("max_concurrent_profiles", 3))
        self._conc_files.setValue(data.get("max_concurrent_files", 6))
        self._port_spin.setValue(data.get("web_server_port", 8485))
        self._password_edit.setText(data.get("web_server_password", ""))

    def _save(self):
        payload = {
            "download_path": self._path_edit.text(),
            "check_interval_hours": self._interval_values[self._interval_combo.currentIndex()],
            "download_posts": self._cb_posts.isChecked(),
            "download_reels": self._cb_reels.isChecked(),
            "download_videos": self._cb_videos.isChecked(),
            "download_highlights": self._cb_highlights.isChecked(),
            "download_stories": self._cb_stories.isChecked(),
            "max_concurrent_profiles": self._conc_profiles.value(),
            "max_concurrent_files": self._conc_files.value(),
            "web_server_port": self._port_spin.value(),
            "web_server_password": self._password_edit.text(),
        }
        w = Worker("settings_save", payload=payload)
        w.finished.connect(lambda: self._workers.remove(w) if w in self._workers else None)
        self._workers.append(w)
        w.start()
        QMessageBox.information(self, "Settings", "Settings saved.")


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("InstaArchive")
        self.resize(1100, 700)
        self.setMinimumSize(900, 560)
        self._workers: list[Worker] = []
        self._build()
        self._launch_backend()
        QTimer.singleShot(1600, self._refresh)
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._refresh)
        self._timer.start(5000)

    def _launch_backend(self):
        """Start the Flask backend (main.py) as a subprocess."""
        main_py = Path(__file__).parent / "main.py"
        if not main_py.exists():
            return
        try:
            kwargs = {}
            if sys.platform == "win32":
                kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
            self._backend = subprocess.Popen(
                [sys.executable, str(main_py)],
                cwd=str(main_py.parent),
                **kwargs,
            )
        except Exception as e:
            self._status.setText(f"Backend error: {e}")

    def _build(self):
        root = QWidget()
        self.setCentralWidget(root)
        lay = QHBoxLayout(root)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # --- Sidebar ---
        sb = QFrame()
        sb.setObjectName("sidebar")
        sb.setFixedWidth(272)
        sl = QVBoxLayout(sb)
        sl.setContentsMargins(18, 24, 18, 18)
        sl.setSpacing(6)

        logo = QLabel("InstaArchive")
        logo.setFont(QFont("Segoe UI", 17, QFont.Weight.Bold))
        sl.addWidget(logo)
        sub_lbl = QLabel("Instagram Archiver")
        sub_lbl.setObjectName("sub")
        sl.addWidget(sub_lbl)
        sl.addSpacing(16)

        # Login status
        self._login_badge = QLabel("\u25cf Not logged in")
        self._login_badge.setStyleSheet(f"color:{ORANGE};font-size:11px;")
        sl.addWidget(self._login_badge)
        login_btn = QPushButton("Log In to Instagram")
        login_btn.setObjectName("primary")
        login_btn.setFixedHeight(36)
        login_btn.clicked.connect(self._open_login)
        sl.addWidget(login_btn)
        sl.addSpacing(20)

        # Add profile
        al = QLabel("ADD PROFILE")
        al.setObjectName("sectionHead")
        sl.addWidget(al)
        sl.addSpacing(4)
        self._add_input = QLineEdit()
        self._add_input.setPlaceholderText("@username or URL")
        self._add_input.returnPressed.connect(self._add_profile)
        sl.addWidget(self._add_input)
        sl.addSpacing(6)
        add_btn = QPushButton("Add Profile")
        add_btn.setObjectName("primary")
        add_btn.setFixedHeight(36)
        add_btn.clicked.connect(self._add_profile)
        sl.addWidget(add_btn)
        sl.addSpacing(16)

        # Action buttons
        sync_btn = QPushButton("Sync All Profiles")
        sync_btn.setObjectName("sync")
        sync_btn.setFixedHeight(36)
        sync_btn.clicked.connect(self._sync_all)
        sl.addWidget(sync_btn)
        sl.addSpacing(6)

        stop_btn = QPushButton("Stop All Downloads")
        stop_btn.setObjectName("danger")
        stop_btn.setFixedHeight(34)
        stop_btn.clicked.connect(self._stop_all)
        sl.addWidget(stop_btn)
        sl.addSpacing(6)

        settings_btn = QPushButton("Settings")
        settings_btn.setFixedHeight(34)
        settings_btn.clicked.connect(self._show_settings)
        sl.addWidget(settings_btn)
        sl.addSpacing(6)

        web_btn = QPushButton("Open Web Dashboard")
        web_btn.setFixedHeight(34)
        web_btn.clicked.connect(lambda: webbrowser.open(API))
        sl.addWidget(web_btn)
        sl.addStretch()

        self._status = QLabel("Connecting\u2026")
        self._status.setObjectName("sub")
        self._status.setWordWrap(True)
        sl.addWidget(self._status)
        lay.addWidget(sb)

        # --- Content area (stacked pages) ---
        self._stack = QStackedWidget()
        lay.addWidget(self._stack, 1)

        # Page 0 — profile list
        lp = QWidget()
        ll = QVBoxLayout(lp)
        ll.setContentsMargins(28, 24, 28, 24)
        ll.setSpacing(16)

        sr = QHBoxLayout()
        sr.setSpacing(12)
        self._s_profiles = StatCard("-", "Profiles")
        self._s_active = StatCard("-", "Active")
        self._s_media = StatCard("-", "Media")
        self._s_status = StatCard("Idle", "Status")
        for c in [self._s_profiles, self._s_active, self._s_media, self._s_status]:
            sr.addWidget(c)
        ll.addLayout(sr)

        ph = QLabel("PROFILES")
        ph.setObjectName("sectionHead")
        ll.addWidget(ph)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        self._list_container = QWidget()
        self._list_container.setStyleSheet("background:transparent;")
        self._list_lay = QVBoxLayout(self._list_container)
        self._list_lay.setContentsMargins(0, 0, 0, 0)
        self._list_lay.setSpacing(8)
        self._list_lay.addStretch()
        scroll.setWidget(self._list_container)
        ll.addWidget(scroll)
        self._stack.addWidget(lp)

        # Page 1 — profile detail
        ds = QScrollArea()
        ds.setWidgetResizable(True)
        self._detail = DetailPanel()
        self._detail.back.connect(self._show_list)
        self._detail.sync_req.connect(self._sync_profile)
        self._detail.remove_req.connect(self._remove_profile)
        ds.setWidget(self._detail)
        self._stack.addWidget(ds)

        # Page 2 — settings
        ss = QScrollArea()
        ss.setWidgetResizable(True)
        self._settings_panel = SettingsPanel()
        self._settings_panel.back.connect(self._show_list)
        ss.setWidget(self._settings_panel)
        self._stack.addWidget(ss)

        self._stack.setCurrentIndex(0)
        self._check_login()

    # --- Login ---

    def _check_login(self):
        if COOKIES_PATH.exists():
            self._login_badge.setText("\u25cf Logged in")
            self._login_badge.setStyleSheet(f"color:{GREEN};font-size:11px;")

    def _open_login(self):
        dlg = LoginDialog(self)
        dlg.success.connect(self._on_login)
        dlg.exec()

    def _on_login(self):
        self._login_badge.setText("\u25cf Logged in")
        self._login_badge.setStyleSheet(f"color:{GREEN};font-size:11px;")
        self._status.setText("Logged in \u2014 session active")

    # --- Worker management ---

    def _run(self, action: str, arg: str = "", payload: dict = None):
        w = Worker(action, arg, payload)
        w.profiles_done.connect(self._on_profiles)
        w.status_done.connect(self._on_status)
        w.profile_done.connect(self._on_profile)
        w.err.connect(lambda e: self._status.setText(f"\u26a0 {e}"))
        w.finished.connect(lambda: self._workers.remove(w) if w in self._workers else None)
        self._workers.append(w)
        w.start()

    def _refresh(self):
        self._run("profiles")
        self._run("status")

    # --- Data handlers ---

    def _on_profiles(self, profiles: list):
        while self._list_lay.count() > 1:
            item = self._list_lay.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        if not profiles:
            lbl = QLabel("No profiles yet \u2014 add one using the sidebar.")
            lbl.setObjectName("sub")
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self._list_lay.insertWidget(0, lbl)
            return
        for p in profiles:
            row = ProfileRow(p)
            row.clicked.connect(self._show_detail)
            row.sync_req.connect(self._sync_profile)
            row.remove_req.connect(self._remove_profile)
            self._list_lay.insertWidget(self._list_lay.count() - 1, row)

    def _on_status(self, s: dict):
        self._s_profiles.set(str(s.get("totalProfiles", 0)))
        self._s_active.set(str(s.get("activeProfiles", 0)))
        m = s.get("totalMediaIndexed", 0)
        self._s_media.set(f"{m / 1000:.1f}K" if m >= 1000 else str(m))
        self._s_status.set("Downloading" if s.get("isDownloading") else "Idle")
        self._status.setText("\u25cf Connected")
        self._status.setStyleSheet(f"color:{GREEN};font-size:11px;")

    def _on_profile(self, data: dict):
        if data.get("error"):
            self._status.setText(data["error"])
            return
        self._detail.load(data)
        self._stack.setCurrentIndex(1)

    # --- Navigation ---

    def _show_list(self):
        self._stack.setCurrentIndex(0)
        self._refresh()

    def _show_detail(self, u: str):
        self._run("profile", u)

    def _show_settings(self):
        self._settings_panel.load_settings()
        self._stack.setCurrentIndex(2)

    # --- Actions ---

    def _add_profile(self):
        u = self._add_input.text().strip().lstrip("@")
        if not u:
            return
        self._add_input.clear()
        self._run("add", u)
        QTimer.singleShot(1200, self._refresh)

    def _sync_profile(self, u: str):
        self._run("sync", u)
        QTimer.singleShot(1000, self._refresh)

    def _sync_all(self):
        self._run("sync_all")
        QTimer.singleShot(1000, self._refresh)

    def _stop_all(self):
        self._run("stop")
        QTimer.singleShot(500, self._refresh)

    def _remove_profile(self, u: str):
        reply = QMessageBox.question(
            self, "Remove Profile",
            f"Remove @{u}?\n\nDownloaded files will remain on disk.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        self._run("remove", u)
        QTimer.singleShot(800, self._refresh)
        if self._stack.currentIndex() == 1:
            self._show_list()

    def closeEvent(self, event):
        # Kill backend when the UI closes
        if hasattr(self, "_backend") and self._backend.poll() is None:
            self._backend.terminate()
        event.accept()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setStyleSheet(STYLESHEET)
    pal = QPalette()
    pal.setColor(QPalette.ColorRole.Window, QColor(BG))
    pal.setColor(QPalette.ColorRole.WindowText, QColor(TEXT))
    pal.setColor(QPalette.ColorRole.Base, QColor(CARD))
    pal.setColor(QPalette.ColorRole.Text, QColor(TEXT))
    pal.setColor(QPalette.ColorRole.Button, QColor(CARD))
    pal.setColor(QPalette.ColorRole.ButtonText, QColor(TEXT))
    app.setPalette(pal)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
