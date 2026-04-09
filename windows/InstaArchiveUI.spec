# InstaArchiveUI.spec — PyInstaller build spec (native desktop UI)
# Build with: pyinstaller InstaArchiveUI.spec
#
# Supports: Windows x64 and Windows ARM64 (Surface Pro X, Copilot+ PCs)
# For ARM64: run this spec on an ARM64 machine with ARM64 Python installed.
#
# This builds the native PyQt6 desktop app. It launches the Flask backend
# as a subprocess and provides a full GUI window with sidebar, profile list,
# detail views, settings, and embedded Instagram login.

block_cipher = None

a = Analysis(
    ['src/ui.py'],
    pathex=['src'],
    binaries=[],
    datas=[
        ('src/main.py', 'src'),
        ('src/app_settings.py', 'src'),
        ('src/profile_store.py', 'src'),
        ('src/download_manager.py', 'src'),
        ('src/instagram_service.py', 'src'),
        ('src/storage_manager.py', 'src'),
        ('src/thumbnail_cache.py', 'src'),
        ('src/scheduler.py', 'src'),
        ('src/web_server.py', 'src'),
        ('src/logger.py', 'src'),
        ('src/tray_app.py', 'src'),
    ],
    hiddenimports=[
        # PyQt6
        'PyQt6.QtCore',
        'PyQt6.QtGui',
        'PyQt6.QtWidgets',
        'PyQt6.QtWebEngineWidgets',
        'PyQt6.QtWebEngineCore',
        # Backend dependencies
        'pystray._win32',
        'PIL._tkinter_finder',
        'PIL.Image',
        'PIL.ImageDraw',
        'apscheduler.schedulers.background',
        'apscheduler.triggers.interval',
        'apscheduler.executors.pool',
        'flask',
        'flask.json',
        'werkzeug',
        'werkzeug.serving',
        'werkzeug.routing',
        'werkzeug.exceptions',
        'jinja2',
        'jinja2.ext',
        'click',
        'itsdangerous',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'tkinter',
        'unittest',
        'pydoc',
        'doctest',
        'xmlrpc',
        'ftplib',
        'imaplib',
        'poplib',
        'smtplib',
        'telnetlib',
        'nntplib',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='InstaArchive',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    target_arch=None,
    argv_emulation=False,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/icon.ico',
    version='version_info.txt',
)
