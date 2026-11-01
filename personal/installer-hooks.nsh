; dmm-main-builds: back up DMM's app data before every install or update.
; The updater starts this installer and only then exits the app, so the backup
; script first waits for DMM to close. If the backup fails, nothing is installed.

!macro NSIS_HOOK_PREINSTALL
  InitPluginsDir
  File "/oname=$PLUGINSDIR\dmm-backup.ps1" "${__FILEDIR__}\dmm-backup.ps1"
  DetailPrint "Backing up Deadlock Mod Manager data..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\dmm-backup.ps1" -InstallDir "$INSTDIR" -Incoming "${VERSION}"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "Deadlock Mod Manager wasn't updated: backing up its data failed (code $0). Your current version is unchanged. Details: %USERPROFILE%\dmm-backups\backup.log" /SD IDOK
    Abort "Backup failed (code $0)"
  ${EndIf}
!macroend
