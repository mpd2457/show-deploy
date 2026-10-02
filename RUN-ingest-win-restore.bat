@echo off
REM Undo RUN-ingest-win.bat. Add -Purge to also delete Ingest and Archive.
powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0restore-ingest-win.ps1\"' -Verb RunAs"
