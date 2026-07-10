' Claude & Codex Usage (Windows) - hidden launcher
' Starts the PowerShell tray widget with no console window flash.
Dim sh, fso, dir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & dir & "\claude-codex-usage.ps1""", 0, False
