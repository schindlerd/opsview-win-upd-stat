# opsview-win-upd-stat
PowerShell script to send Windows Update status to Opsview via REST-API

This is a clientless solution (no NSClient++ needed) to check Windows Update status and pass results into a passive check.

## Requirements
- user/role with enough rights in Opsview
- define a passive check where script will paste its results in
- define a scheduled task on Windows server host to run script (powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy bypass -file \\networkshare\scripts\script.ps1)
