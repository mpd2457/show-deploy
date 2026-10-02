@echo off
powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0setup-gfx.ps1\" -MachineName GFX3' -Verb RunAs"
