; LANShare - Inno Setup installer script
;
; Builds a standard Windows installer (setup.exe) around the Flutter
; "flutter build windows --release" output.
;
; Usage:
;   1) Local build:
;        flutter build windows --release
;        iscc installer\setup.iss
;      (Inno Setup will look for the build in ..\build\windows\x64\runner\Release
;       relative to this script by default - see MyAppReleaseDir below.)
;
;   2) CI build (see .github/workflows/windows-build.yml):
;        ISCC.exe /DMyAppReleaseDir="build\windows\x64\runner\Release" installer\setup.iss
;      The /D flag overrides MyAppReleaseDir so CI can point at wherever
;      Flutter actually put the build output.

#define MyAppName "LANShare"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "LANShare"
#define MyAppExeName "lanshare.exe"

; Default location Flutter puts the Release build in when you build
; locally from the repository root. Overridden by CI with /DMyAppReleaseDir=...
#ifndef MyAppReleaseDir
  #define MyAppReleaseDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{9F0F6C1B-6E7A-4F4A-9E77-2A6C6C3C7B1A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install by default so no admin prompt is required. Switch to
; "lowest" -> "admin" and DefaultDirName to {pf} if you need a machine-wide
; install instead.
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=LANShare-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
; Path is relative to this .iss file, which lives in installer\ at the repo root.
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Pull in the entire Release output (exe, flutter_windows.dll, plugin
; DLLs, and the data\ folder with Flutter assets/ICU data) recursively.
Source: "{#MyAppReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

; LANShare listens for/opens plain TCP connections on the LAN, so Windows
; Firewall will show a one-time "Allow access" prompt on first run - that's
; expected and just needs to be accepted for the app to work.
