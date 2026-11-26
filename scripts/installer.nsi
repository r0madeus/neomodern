; NeoModern Windows NSIS Installer
; Compatible with per-user Tauri NSIS installs and WinGet manifest (r0madeus.NeoModern)

Unicode True

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef SOURCE_DIR
  !define SOURCE_DIR "..\flutter_app\build\windows\x64\runner\Release"
!endif
!ifndef OUTFILE
  !define OUTFILE "NeoModern_${VERSION}_x64-setup.exe"
!endif

!include "MUI2.nsh"

Name "NeoModern"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\NeoModern"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ICON "..\src-tauri\icons\icon.ico"
!define MUI_UNICON "..\src-tauri\icons\icon.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
FunctionEnd

Function un.onInit
  SetShellVarContext current
FunctionEnd

Section "Install" SecInstall
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  SetOverwrite on

  ; Install all application files recursively (exclude debug symbols and import libs)
  File /r /x "*.pdb" /x "*.lib" /x "*.exp" "${SOURCE_DIR}\*.*"

  ; Create Start Menu shortcut
  CreateShortcut "$SMPROGRAMS\NeoModern.lnk" "$INSTDIR\neomodern.exe" "" "$INSTDIR\neomodern.exe" 0

  ; Write uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Write Windows Add/Remove Programs (ARP) registry entries
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "DisplayName" "NeoModern"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "Publisher" "r0madeus"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "DisplayIcon" "$INSTDIR\neomodern.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "QuietUninstallString" "$\"$INSTDIR\uninstall.exe$\" /S"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current

  ; Remove Start Menu shortcut
  Delete "$SMPROGRAMS\NeoModern.lnk"

  ; Move out of $INSTDIR before removing it; preserve %APPDATA%\io.github.r0madeus.neomodern
  SetOutPath "$LOCALAPPDATA"
  RMDir /r "$INSTDIR"

  ; Remove Windows Add/Remove Programs registry entry
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoModern"
SectionEnd
