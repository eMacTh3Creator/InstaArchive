"""
web_server.py — Flask-based web interface + REST API.
Reuses the same HTML/JS from the macOS version with minor adaptations.
"""
import json
import os
import secrets
import threading
from datetime import datetime
from pathlib import Path
from typing import Optional

from flask import Flask, request, jsonify, make_response, redirect, url_for, Response

from app_settings import AppSettings
from storage_manager import StorageManager

# Lazy imports to avoid circular deps at module level
def _dm():
    from download_manager import DownloadManager
    return DownloadManager()

def _store():
    from profile_store import ProfileStore
    return ProfileStore()


app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

_settings  = AppSettings()
_storage   = StorageManager()
_sessions: set[str] = set()
_sess_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def _password_required() -> bool:
    return bool(_settings.web_server_password)

def _is_authed() -> bool:
    if not _password_required():
        return True
    token = request.cookies.get("ia_token", "")
    with _sess_lock:
        return token in _sessions

def _require_auth():
    if not _is_authed():
        if request.path.startswith("/api/"):
            return jsonify({"error": "Unauthorized"}), 401
        return redirect("/login")
    return None

def _fmt_status(username: str) -> str:
    dm = _dm()
    s = dm.get_status(username)
    return s.to_str()


# ---------------------------------------------------------------------------
# Auth routes
# ---------------------------------------------------------------------------

@app.route("/login", methods=["GET"])
def login_page():
    return Response(LOGIN_HTML, mimetype="text/html")

@app.route("/api/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    password = data.get("password", "")
    if password == _settings.web_server_password:
        token = secrets.token_hex(32)
        with _sess_lock:
            _sessions.add(token)
        resp = make_response(jsonify({"success": True}))
        resp.set_cookie("ia_token", token, httponly=True, samesite="Strict", path="/")
        return resp
    return jsonify({"error": "Wrong password"}), 401

@app.route("/api/logout", methods=["POST"])
def api_logout():
    token = request.cookies.get("ia_token", "")
    with _sess_lock:
        _sessions.discard(token)
    resp = make_response(jsonify({"success": True}))
    resp.delete_cookie("ia_token")
    return resp


# ---------------------------------------------------------------------------
# Main page
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    guard = _require_auth()
    if guard:
        return guard
    return Response(INDEX_HTML, mimetype="text/html")


# ---------------------------------------------------------------------------
# Profile API
# ---------------------------------------------------------------------------

@app.route("/api/profiles", methods=["GET"])
def get_profiles():
    guard = _require_auth()
    if guard:
        return guard
    store = _store()
    dm    = _dm()
    result = []
    for p in store.profiles:
        result.append({
            "username":       p["username"],
            "displayName":    p.get("display_name", p["username"]),
            "isActive":       p.get("is_active", True),
            "totalDownloaded": p.get("total_downloaded", 0),
            "dateAdded":      p.get("date_added", ""),
            "lastChecked":    p.get("last_checked"),
            "status":         _fmt_status(p["username"]),
        })
    return jsonify(result)


@app.route("/api/profiles", methods=["POST"])
def add_profile():
    guard = _require_auth()
    if guard:
        return guard
    data     = request.get_json(silent=True) or {}
    username = _clean_username(data.get("username", ""))
    if not username:
        return jsonify({"error": "Username is required"}), 400

    store = _store()
    try:
        store.add_profile(username)
        return jsonify({"success": True, "message": f"Added @{username} to your archive", "username": username})
    except ValueError as e:
        return jsonify({"error": str(e)}), 409


@app.route("/api/profiles/<username>", methods=["DELETE"])
def delete_profile(username):
    guard = _require_auth()
    if guard:
        return guard
    username = _clean_username(username)
    store    = _store()
    if not store.get_profile(username):
        return jsonify({"error": "Profile not found"}), 404
    store.remove_profile(username)
    return jsonify({"success": True, "message": f"Removed @{username}"})


@app.route("/api/profile/<username>", methods=["GET"])
def get_profile_detail(username):
    guard = _require_auth()
    if guard:
        return guard
    username = _clean_username(username)
    store    = _store()
    profile  = store.get_profile(username)
    if not profile:
        return jsonify({"error": "Profile not found"}), 404

    dm    = _dm()
    items = dm.media_items_for(username)

    type_counts: dict[str, int] = {}
    total_size  = 0
    for item in items:
        type_counts[item.media_type] = type_counts.get(item.media_type, 0) + 1
        total_size += item.file_size or 0

    return jsonify({
        "username":        profile["username"],
        "displayName":     profile.get("display_name", profile["username"]),
        "bio":             profile.get("bio", ""),
        "isActive":        profile.get("is_active", True),
        "totalDownloaded": profile.get("total_downloaded", 0),
        "dateAdded":       profile.get("date_added", ""),
        "lastChecked":     profile.get("last_checked"),
        "lastNewContent":  profile.get("last_new_content"),
        "mediaByType":     type_counts,
        "totalFileSize":   total_size,
        "totalIndexed":    len(items),
        "status":          _fmt_status(username),
    })


# ---------------------------------------------------------------------------
# Status API
# ---------------------------------------------------------------------------

@app.route("/api/status", methods=["GET"])
def get_status():
    guard = _require_auth()
    if guard:
        return guard
    dm     = _dm()
    store  = _store()
    profs  = store.profiles
    return jsonify({
        "isDownloading":    dm.is_running,
        "totalProfiles":    len(profs),
        "activeProfiles":   sum(1 for p in profs if p.get("is_active", True)),
        "totalMediaIndexed": dm.total_downloaded,
        "currentActivity":  dm.current_activity,
    })


# ---------------------------------------------------------------------------
# Sync API
# ---------------------------------------------------------------------------

@app.route("/api/sync/all", methods=["POST"])
def sync_all():
    guard = _require_auth()
    if guard:
        return guard
    dm    = _dm()
    store = _store()
    if dm.is_running:
        return jsonify({"success": True, "message": "Sync already running"})
    dm.check_all_profiles(store)
    return jsonify({"success": True, "message": "Sync started for all profiles"})


@app.route("/api/sync/<username>", methods=["POST"])
def sync_profile(username):
    guard = _require_auth()
    if guard:
        return guard
    username = _clean_username(username)
    store    = _store()
    profile  = store.get_profile(username)
    if not profile:
        return jsonify({"error": "Profile not found"}), 404
    dm = _dm()
    if username in dm.active_usernames:
        return jsonify({"success": True, "message": f"Already syncing @{username}"})
    dm.check_profile(profile, store)
    return jsonify({"success": True, "message": f"Sync started for @{username}"})


# ---------------------------------------------------------------------------
# Stop / Skip API
# ---------------------------------------------------------------------------

@app.route("/api/stop", methods=["POST"])
def stop_all():
    guard = _require_auth()
    if guard:
        return guard
    _dm().stop_all()
    return jsonify({"success": True, "message": "Stopping all downloads"})


@app.route("/api/skip/<username>", methods=["POST"])
def skip_profile(username):
    guard = _require_auth()
    if guard:
        return guard
    username = _clean_username(username)
    _dm().skip_profile(username)
    return jsonify({"success": True, "message": f"Skipping @{username}"})


# ---------------------------------------------------------------------------
# Settings API
# ---------------------------------------------------------------------------

@app.route("/api/settings", methods=["GET"])
def get_settings():
    guard = _require_auth()
    if guard:
        return guard
    s = _settings
    return jsonify({
        "download_path":         s.download_path,
        "check_interval_hours":  s.check_interval_hours,
        "download_posts":        s.download_posts,
        "download_reels":        s.download_reels,
        "download_videos":       s.download_videos,
        "download_highlights":   s.download_highlights,
        "download_stories":      s.download_stories,
        "max_concurrent_profiles": s.max_concurrent_profiles,
        "max_concurrent_files":  s.max_concurrent_files,
        "web_server_port":       s.web_server_port,
        "web_server_password":   s.web_server_password,
    })


@app.route("/api/settings", methods=["POST"])
def update_settings():
    guard = _require_auth()
    if guard:
        return guard
    data = request.get_json(silent=True) or {}
    allowed = {
        "download_path", "check_interval_hours", "download_posts", "download_reels",
        "download_videos", "download_highlights", "download_stories",
        "max_concurrent_profiles", "max_concurrent_files",
        "web_server_port", "web_server_password",
    }
    updates = {k: v for k, v in data.items() if k in allowed}
    _settings.update(updates)
    return jsonify({"success": True})


# ---------------------------------------------------------------------------
# Export / Import
# ---------------------------------------------------------------------------

@app.route("/api/export", methods=["GET"])
def export_profiles():
    guard = _require_auth()
    if guard:
        return guard
    store = _store()
    data  = json.dumps(store.profiles, indent=2, default=str)
    resp  = make_response(data)
    resp.headers["Content-Type"]        = "application/json"
    resp.headers["Content-Disposition"] = "attachment; filename=instaarchive-profiles.json"
    return resp


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _clean_username(raw: str) -> str:
    clean = (raw or "").strip()
    if "instagram.com/" in clean:
        idx   = clean.index("instagram.com/") + len("instagram.com/")
        clean = clean[idx:].split("?")[0].split("/")[0]
    if clean.startswith("@"):
        clean = clean[1:]
    return clean.lower()


# ---------------------------------------------------------------------------
# Server runner
# ---------------------------------------------------------------------------

class WebServer:
    _instance = None
    _slock = threading.Lock()

    def __new__(cls):
        with cls._slock:
            if cls._instance is None:
                cls._instance = super().__new__(cls)
                cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._thread: Optional[threading.Thread] = None
        self.is_running = False
        self._initialized = True

    def start(self):
        if self.is_running:
            return
        port = _settings.web_server_port

        import logging
        log = logging.getLogger("werkzeug")
        log.setLevel(logging.ERROR)

        def _run():
            app.run(host="127.0.0.1", port=port, debug=False, use_reloader=False)

        self._thread = threading.Thread(target=_run, daemon=True, name="flask-server")
        self._thread.start()
        self.is_running = True
        print(f"[WebServer] Running on http://127.0.0.1:{port}")

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{_settings.web_server_port}"


# ---------------------------------------------------------------------------
# Embedded HTML (same dark design as macOS version)
# ---------------------------------------------------------------------------

LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>InstaArchive — Login</title>
<style>
:root{--bg:#0a0a0a;--card:#161616;--border:#2a2a2a;--text:#e8e8e8;--sub:#888;--accent:#6366f1;--ah:#818cf8;--red:#ef4444}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;align-items:center;justify-content:center}
.box{width:340px;padding:36px 28px;background:var(--card);border:1px solid var(--border);border-radius:14px}
h1{font-size:20px;font-weight:600;margin-bottom:6px;text-align:center}
.sub{color:var(--sub);font-size:13px;text-align:center;margin-bottom:24px}
input[type=password]{width:100%;padding:10px 14px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:14px;outline:none;margin-bottom:16px}
input[type=password]:focus{border-color:var(--accent)}
.btn{width:100%;padding:10px;border-radius:8px;border:none;background:var(--accent);color:#fff;font-size:14px;font-weight:500;cursor:pointer}
.btn:hover{background:var(--ah)}
.err{color:var(--red);font-size:13px;text-align:center;margin-bottom:12px;display:none}
</style></head>
<body><div class="box">
<h1>InstaArchive</h1><p class="sub">Enter your password to continue</p>
<div class="err" id="err"></div>
<form onsubmit="login(event)">
<input type="password" id="pw" placeholder="Password" autofocus/>
<button type="submit" class="btn">Log In</button>
</form></div>
<script>
async function login(e){e.preventDefault();const pw=document.getElementById('pw').value;const err=document.getElementById('err');
try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw})});
const d=await r.json();if(d.success){window.location.href='/';}else{err.textContent=d.error||'Wrong password';err.style.display='block';}}
catch{err.textContent='Connection failed';err.style.display='block';}}
</script></body></html>"""


INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>InstaArchive</title>
<style>
:root{--bg:#0a0a0a;--card:#161616;--border:#2a2a2a;--text:#e8e8e8;--sub:#888;--accent:#6366f1;--ah:#818cf8;--green:#22c55e;--red:#ef4444;--orange:#f59e0b}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
.container{max-width:660px;margin:0 auto;padding:40px 20px}
h1{font-size:24px;font-weight:600;margin-bottom:4px}
.subtitle{color:var(--sub);font-size:14px;margin-bottom:32px}
.status-bar{display:flex;gap:24px;margin-bottom:28px;padding:14px 18px;background:var(--card);border:1px solid var(--border);border-radius:10px}
.stat{display:flex;flex-direction:column}
.stat-val{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums}
.stat-label{font-size:11px;color:var(--sub);margin-top:2px;text-transform:uppercase;letter-spacing:.5px}
.add-form{display:flex;gap:10px;margin-bottom:28px}
.add-form input{flex:1;padding:10px 14px;border-radius:8px;border:1px solid var(--border);background:var(--card);color:var(--text);font-size:14px;outline:none;transition:border-color .15s}
.add-form input:focus{border-color:var(--accent)}
.add-form input::placeholder{color:#555}
.btn{padding:10px 20px;border-radius:8px;border:none;font-size:14px;font-weight:500;cursor:pointer;transition:all .15s}
.btn-primary{background:var(--accent);color:#fff}
.btn-primary:hover{background:var(--ah)}
.btn-primary:disabled{opacity:.5;cursor:not-allowed}
.btn-sm{padding:5px 12px;font-size:12px;border-radius:6px}
.btn-danger{background:transparent;color:var(--red);border:1px solid #3a1515}
.btn-danger:hover{background:#1a0808}
.btn-outline{background:transparent;color:var(--sub);border:1px solid var(--border)}
.btn-outline:hover{color:var(--text);border-color:#444}
.btn-sync{background:transparent;color:var(--green);border:1px solid #14532d}
.btn-sync:hover{background:#052e16}
.section-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
.section-head h2{font-size:16px;font-weight:600}
.section-actions{display:flex;gap:8px;align-items:center}
.profiles-list{display:flex;flex-direction:column;gap:8px}
.profile-row{display:flex;align-items:center;gap:12px;padding:12px 16px;background:var(--card);border:1px solid var(--border);border-radius:10px;transition:border-color .15s;cursor:pointer}
.profile-row:hover{border-color:#3a3a3a}
.avatar{width:36px;height:36px;border-radius:50%;background:linear-gradient(135deg,#7c3aed,#ec4899,#f97316);display:flex;align-items:center;justify-content:center;font-weight:700;font-size:15px;color:#fff;flex-shrink:0}
.profile-info{flex:1;min-width:0}
.profile-name{font-size:14px;font-weight:500}
.profile-meta{font-size:11px;color:var(--sub);margin-top:2px}
.badge{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:600}
.badge-active{background:#052e16;color:var(--green)}
.badge-paused{background:#1c1105;color:var(--orange)}
.badge-syncing{background:#1e1b4b;color:var(--ah)}
.toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%);padding:10px 20px;border-radius:8px;font-size:13px;font-weight:500;z-index:100;transition:opacity .3s}
.toast-success{background:#052e16;color:var(--green);border:1px solid #14532d}
.toast-error{background:#1a0808;color:var(--red);border:1px solid #7f1d1d}
.empty{text-align:center;padding:40px 20px;color:var(--sub)}
#fileInput{display:none}
.loading{text-align:center;padding:20px;color:var(--sub)}
.detail-panel{display:none}
.detail-panel.open{display:block}
.back-btn{background:none;border:none;color:var(--accent);font-size:13px;cursor:pointer;padding:0;margin-bottom:20px;display:flex;align-items:center;gap:4px}
.back-btn:hover{color:var(--ah)}
.detail-header{display:flex;align-items:center;gap:16px;margin-bottom:24px}
.detail-header .avatar{width:56px;height:56px;font-size:24px}
.detail-name{font-size:20px;font-weight:600}
.detail-sub{font-size:13px;color:var(--sub);margin-top:2px}
.detail-bio{font-size:13px;color:var(--sub);margin-top:4px;line-height:1.4}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin-bottom:24px}
.stat-card{padding:14px;background:var(--card);border:1px solid var(--border);border-radius:10px}
.stat-card .stat-val{font-size:18px}
.stat-card .stat-label{font-size:10px}
.media-breakdown{margin-bottom:24px}
.media-breakdown h3{font-size:14px;font-weight:600;margin-bottom:10px}
.media-row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--border);font-size:13px}
.media-row:last-child{border-bottom:none}
.media-count{color:var(--sub);font-variant-numeric:tabular-nums}
.detail-actions{display:flex;gap:10px;margin-bottom:24px}
</style>
</head>
<body>
<div class="container">
  <div id="listView">
    <h1>InstaArchive</h1>
    <p class="subtitle">Manage your archived Instagram profiles</p>
    <div class="status-bar">
      <div class="stat"><span class="stat-val" id="statProfiles">-</span><span class="stat-label">Profiles</span></div>
      <div class="stat"><span class="stat-val" id="statActive">-</span><span class="stat-label">Active</span></div>
      <div class="stat"><span class="stat-val" id="statMedia">-</span><span class="stat-label">Media</span></div>
      <div class="stat"><span class="stat-val" id="statStatus">-</span><span class="stat-label">Status</span></div>
    </div>
    <form class="add-form" onsubmit="addProfile(event)">
      <input type="text" id="usernameInput" placeholder="Username, @handle, or Instagram URL" autocomplete="off" spellcheck="false"/>
      <button type="submit" class="btn btn-primary" id="addBtn">Add</button>
    </form>
    <div class="section-head">
      <h2>Profiles</h2>
      <div class="section-actions">
        <button class="btn btn-sm btn-sync" onclick="syncAll()">Sync All</button>
        <button class="btn btn-sm btn-outline" onclick="exportProfiles()">Export</button>
        <button class="btn btn-sm btn-outline" onclick="document.getElementById('fileInput').click()">Import</button>
        <input type="file" id="fileInput" accept=".json" onchange="importProfiles(event)"/>
      </div>
    </div>
    <div id="profilesList" class="profiles-list"><div class="loading">Loading...</div></div>
  </div>

  <div id="detailView" class="detail-panel">
    <button class="back-btn" onclick="showList()">&#8592; Back</button>
    <div class="detail-header">
      <div class="avatar" id="detailAvatar"></div>
      <div>
        <div class="detail-name" id="detailName"></div>
        <div class="detail-sub" id="detailDisplayName"></div>
        <div class="detail-bio" id="detailBio"></div>
      </div>
    </div>
    <div class="detail-actions">
      <button class="btn btn-sm btn-sync" onclick="syncDetail()">Sync Now</button>
      <button class="btn btn-sm btn-danger" onclick="removeDetail()">Remove</button>
      <a id="detailIGLink" class="btn btn-sm btn-outline" target="_blank" rel="noopener">View on Instagram</a>
    </div>
    <div class="stats-grid" id="detailStats"></div>
    <div class="media-breakdown" id="mediaBreakdown">
      <h3>Media Breakdown</h3>
      <div id="mediaRows"></div>
    </div>
  </div>
</div>
<div class="toast" id="toast" style="opacity:0"></div>
<script>
let profiles=[];let currentDetail=null;
async function loadProfiles(){try{const r=await fetch('/api/profiles');if(r.status===401){location.href='/login';return;}profiles=await r.json();renderProfiles();}catch{document.getElementById('profilesList').innerHTML='<div class="empty">Could not connect</div>';}}
async function loadStatus(){try{const r=await fetch('/api/status');if(r.status===401)return;const s=await r.json();document.getElementById('statProfiles').textContent=s.totalProfiles;document.getElementById('statActive').textContent=s.activeProfiles;document.getElementById('statMedia').textContent=s.totalMediaIndexed>=1000?(s.totalMediaIndexed/1000).toFixed(1)+'K':s.totalMediaIndexed;document.getElementById('statStatus').textContent=s.isDownloading?'Downloading':'Idle';}catch{}}
function statusBadge(p){const s=p.status||'idle';if(s.startsWith('downloading'))return`<span class="badge badge-syncing">Syncing ${s.split(':')[1]||''}%</span>`;if(s==='checking')return'<span class="badge badge-syncing">Checking</span>';return`<span class="badge ${p.isActive?'badge-active':'badge-paused'}">${p.isActive?'Active':'Paused'}</span>`;}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function renderProfiles(){const el=document.getElementById('profilesList');if(!profiles.length){el.innerHTML='<div class="empty">No profiles yet.</div>';return;}el.innerHTML=profiles.map(p=>`<div class="profile-row" onclick="showDetail('${p.username}')"><div class="avatar">${p.username[0].toUpperCase()}</div><div class="profile-info"><div class="profile-name">@${p.username}</div><div class="profile-meta">${p.totalDownloaded} items${p.displayName!==p.username?' &middot; '+esc(p.displayName):''}</div></div>${statusBadge(p)}<button class="btn btn-sm btn-sync" onclick="event.stopPropagation();syncProfile('${p.username}')">Sync</button><button class="btn btn-sm btn-danger" onclick="event.stopPropagation();removeProfile('${p.username}')">Remove</button></div>`).join('');}
async function addProfile(e){e.preventDefault();const inp=document.getElementById('usernameInput');const u=inp.value.trim();if(!u)return;document.getElementById('addBtn').disabled=true;try{const r=await fetch('/api/profiles',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u})});const d=await r.json();if(d.error)showToast(d.error,'error');else{showToast(d.message,'success');inp.value='';}loadProfiles();loadStatus();}catch{showToast('Failed','error');}document.getElementById('addBtn').disabled=false;}
async function removeProfile(u){if(!confirm('Remove @'+u+'?'))return;try{await fetch('/api/profiles/'+u,{method:'DELETE'});showToast('Removed @'+u,'success');loadProfiles();loadStatus();}catch{showToast('Failed','error');}}
async function syncProfile(u){try{const r=await fetch('/api/sync/'+u,{method:'POST'});const d=await r.json();showToast(d.message,'success');setTimeout(loadProfiles,1000);}catch{showToast('Failed','error');}}
async function syncAll(){try{const r=await fetch('/api/sync/all',{method:'POST'});const d=await r.json();showToast(d.message,'success');setTimeout(loadProfiles,1000);}catch{showToast('Failed','error');}}
function exportProfiles(){window.location.href='/api/export';}
async function importProfiles(e){const file=e.target.files[0];if(!file)return;try{const text=await file.text();const imported=JSON.parse(text);const list=Array.isArray(imported)?imported:(imported.profiles||[]);let added=0;for(const p of list){const u=p.username||p;if(!u||typeof u!=='string')continue;try{const r=await fetch('/api/profiles',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u})});const d=await r.json();if(d.success)added++;}catch{}}showToast('Imported '+added+' profile'+(added===1?'':'s'),'success');loadProfiles();loadStatus();}catch{showToast('Invalid file','error');}e.target.value='';}
async function showDetail(u){currentDetail=u;try{const r=await fetch('/api/profile/'+u);const d=await r.json();if(d.error){showToast(d.error,'error');return;}document.getElementById('detailAvatar').textContent=d.username[0].toUpperCase();document.getElementById('detailName').textContent='@'+d.username;document.getElementById('detailDisplayName').textContent=d.displayName!==d.username?d.displayName:'';document.getElementById('detailBio').textContent=d.bio||'';document.getElementById('detailIGLink').href='https://www.instagram.com/'+d.username+'/';const fmtBytes=b=>{if(b>=1073741824)return(b/1073741824).toFixed(1)+' GB';if(b>=1048576)return(b/1048576).toFixed(1)+' MB';if(b>=1024)return(b/1024).toFixed(0)+' KB';return b+' B';};const fmtDate=iso=>{if(!iso)return'Never';const dt=new Date(iso);return dt.toLocaleDateString()+' '+dt.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});};document.getElementById('detailStats').innerHTML=[{v:d.totalIndexed,l:'Total Media'},{v:fmtBytes(d.totalFileSize),l:'Storage Used'},{v:fmtDate(d.lastChecked),l:'Last Checked'},{v:fmtDate(d.lastNewContent),l:'Last New Content'},{v:fmtDate(d.dateAdded),l:'Date Added'},{v:d.isActive?'Active':'Paused',l:'Status'}].map(s=>`<div class="stat-card"><div class="stat-val">${s.v}</div><div class="stat-label">${s.l}</div></div>`).join('');const types=d.mediaByType||{};const rows=Object.entries(types).sort((a,b)=>b[1]-a[1]);if(rows.length){document.getElementById('mediaBreakdown').style.display='block';document.getElementById('mediaRows').innerHTML=rows.map(([t,c])=>`<div class="media-row"><span>${t}</span><span class="media-count">${c}</span></div>`).join('');}else{document.getElementById('mediaBreakdown').style.display='none';}document.getElementById('listView').style.display='none';document.getElementById('detailView').className='detail-panel open';}catch{showToast('Failed to load','error');}}
function showList(){currentDetail=null;document.getElementById('detailView').className='detail-panel';document.getElementById('listView').style.display='block';loadProfiles();}
async function syncDetail(){if(!currentDetail)return;await syncProfile(currentDetail);setTimeout(()=>showDetail(currentDetail),1500);}
async function removeDetail(){if(!currentDetail)return;if(!confirm('Remove @'+currentDetail+'?'))return;try{await fetch('/api/profiles/'+currentDetail,{method:'DELETE'});showToast('Removed @'+currentDetail,'success');showList();}catch{showToast('Failed','error');}}
function showToast(msg,type){const el=document.getElementById('toast');el.textContent=msg;el.className='toast toast-'+type;el.style.opacity='1';setTimeout(()=>{el.style.opacity='0';},2500);}
loadProfiles();loadStatus();setInterval(()=>{loadStatus();if(!currentDetail)loadProfiles();},5000);
</script>
</body></html>"""
