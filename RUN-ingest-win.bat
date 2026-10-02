@echo off
REM Fallback Ingest for the Windows work laptop, when mkultra2 is not available.
powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0setup-ingest-win.ps1\"' -Verb RunAs"
