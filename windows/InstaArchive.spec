# InstaArchive.spec — PyInstaller build spec
# Build with: pyinstaller InstaArchive.spec
#
# Supports: Windows x64 and Windows ARM64 (Surface Pro X, Copilot+ PCs)
# For ARM64: run this spec on an ARM64 machine with ARM64 Python installed,
# or use cross-compilation (see build.bat for details).

block_cipher = None

a = Analysis(
    ['src/main.py'],
    pathex=['src'],
    binaries=[],
    datas=[],
    hiddenimports=[
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
    # No console window — pure tray app
    console=False,
    disable_windowed_traceback=False,
    # ARM64 note: PyInstaller auto-detects target_arch from the running Python.
    # On ARM64 Python → produces ARM64 exe. On x64 Python → produces x64 exe.
    # Leave as None to match the host Python architecture.
    target_arch=None,
    argv_emulation=False,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/icon.ico',
    version='version_info.txt',
)
