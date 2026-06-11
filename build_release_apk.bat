@echo off
setlocal

cd /d "%~dp0"

echo Building release APK for arm64-v8a...
flutter build apk --release --target-platform android-arm64

if errorlevel 1 (
  echo Build failed.
  exit /b 1
)

echo.
echo Output file:
echo   build\app\outputs\flutter-apk\app-arm64-v8a-release.apk

endlocal
