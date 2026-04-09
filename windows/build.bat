@echo off
REM InstaArchive Windows build script
REM Requirements: Python 3.11+, pip install -r requirements.txt
REM
REM Usage:
REM   build.bat          — build tray-only version (lightweight, browser UI)
REM   build.bat ui       — build native desktop UI version (PyQt6 window)

echo ===========================================
echo  InstaArchive Windows Build
echo ===========================================

REM Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install Python 3.11+ from python.org
    pause
    exit /b 1
)

REM Install dependencies
echo Installing dependencies...
pip install -r requirements.txt --quiet
if errorlevel 1 (
    echo ERROR: Failed to install dependencies
    pause
    exit /b 1
)

REM Create assets folder if missing
if not exist "assets" mkdir assets

REM Generate placeholder icon if icon.ico doesn't exist
if not exist "assets\icon.ico" (
    echo Generating icon...
    python -c "from PIL import Image, ImageDraw; s=64; img=Image.new('RGBA',(s,s),(0,0,0,0)); d=ImageDraw.Draw(img); d.ellipse([4,4,60,60],fill='#6366f1'); d.rounded_rectangle([16,22,48,46],radius=4,fill='white'); d.ellipse([24,26,40,42],fill='#6366f1'); d.ellipse([27,29,37,39],fill='white'); img.save('assets/icon.ico')"
)

REM Choose build mode
if /i "%1"=="ui" (
    echo Building native desktop UI version...
    pyinstaller InstaArchiveUI.spec --clean --noconfirm
) else (
    echo Building tray-only version...
    pyinstaller InstaArchive.spec --clean --noconfirm
)

if errorlevel 1 (
    echo ERROR: Build failed
    pause
    exit /b 1
)

echo.
echo ===========================================
echo  Build complete!
echo  Output: dist\InstaArchive.exe
echo ===========================================
echo.
echo To create the installer, run installer.iss with Inno Setup.
pause
