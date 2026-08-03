; Inno Setup script for Relic — per-user install, no admin (UAC) prompt.
;
; Build:  ISCC.exe /DMyAppVersion=1.0.0 relic.iss
; The release script (app\scripts\build_release.ps1) reads the version from
; pubspec.yaml and passes it in, so pubspec stays the single source of truth.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "Relic"
#define MyAppExeName "relic_app.exe"
#define MyAppPublisher "Relic"
#define MyAppURL "https://relic.space"
; Flutter's Release output, relative to this script (app\installer\).
#define BuildDir "..\build\windows\x64\runner\Release"
; The `relic` CLI (the agent-facing shim over the local vault). Built by the
; release script via `cargo build --release -p relic-cli` into the workspace
; target dir. Path is relative to this script; override with /DCliExe=... .
#ifndef CliExe
  #define CliExe "..\..\target\release\relic.exe"
#endif
; The `sift` on-device ML sidecar (relic-sift). Built by the release script via
; `cargo build --release -p relic-sift`. Ships next to relic_app.exe (in {app})
; so the app's SiftSidecar.locate() finds it; onnxruntime.dll + the ONNX models
; are fetched at first ML use by `sift models download`. Override with /DSiftExe=.
#ifndef SiftExe
  #define SiftExe "..\..\target\release\sift.exe"
#endif

[Setup]
; Keep this GUID stable across releases so upgrades replace in place.
AppId={{B7E3A6F2-4C1D-4E8A-9F2B-1A7C5D9E0F34}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install: no elevation, and it matches the HKCU\...\Run autostart
; entry the app writes for itself.
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=relic-setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; We append the CLI dir to the per-user PATH, so tell Windows to broadcast the
; environment-change message (WM_SETTINGCHANGE) when the installer finishes.
ChangesEnvironment=yes

; --- Code signing (wired but inert until a certificate is configured) ---
; Define a SignTool named "relicsign" (in the build script or the Inno IDE),
; then uncomment the two lines below to sign the installer + uninstaller:
; SignTool=relicsign
; SignedUninstaller=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; The `relic` CLI: a lightweight, agent-facing shim over the local vault. It is
; self-contained (only needs the MSVC runtime the app already ships), so it goes
; in its own subdir — that lets us put just it on PATH, not the whole app dir.
Source: "{#CliExe}"; DestDir: "{app}\cli"; DestName: "relic.exe"; Flags: ignoreversion
; The CLI needs the VC++ runtime next to it too: it lives in its own dir (only
; {app}\cli goes on PATH) and Windows resolves DLLs from the exe's dir, not the
; parent. The build script stages these three into BuildDir (see 2a there).
Source: "{#BuildDir}\msvcp140.dll"; DestDir: "{app}\cli"; Flags: ignoreversion
Source: "{#BuildDir}\vcruntime140.dll"; DestDir: "{app}\cli"; Flags: ignoreversion
Source: "{#BuildDir}\vcruntime140_1.dll"; DestDir: "{app}\cli"; Flags: ignoreversion
; The `sift` ML sidecar must sit BESIDE relic_app.exe in {app} root (that's where
; SiftSidecar.locate() looks first). Models/onnxruntime.dll download at first use.
Source: "{#SiftExe}"; DestDir: "{app}"; DestName: "sift.exe"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; Self-update handoff: the app runs this installer silently with /RELAUNCH=1
; (see app\lib\data\self_update.dart), so the fresh build comes straight back
; up in the tray. Interactive installs use the postinstall checkbox above.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: ShouldRelaunch

[Registry]
; The app manages its own run-at-login value (HKCU\...\Run\Relic). We don't
; touch it at install, but uninstalling must remove it so no dangling autostart
; command is left pointing at a deleted exe.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Relic"; ValueType: none; Flags: uninsdeletevalue
; Put the `relic` CLI on the per-user PATH so a terminal (or an AI agent) can run
; `relic`. Per-user install => HKCU\Environment. Only appended when not already
; present (see NeedsAddPath); removed on uninstall (see CurUninstallStepChanged).
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\cli"; Check: NeedsAddPath(ExpandConstant('{app}\cli'))
; The `relic://` URL protocol: lets a browser (e.g. the website's post-checkout
; "Open Relic" button, or relic://open) launch/surface the app. Per-user install
; => HKCU\Software\Classes. `%1` is the clicked URL; main.cpp forwards it to Dart
; (cold start), and a running instance is re-surfaced by the single-instance
; mutex guard. The whole subtree is removed on uninstall (uninsdeletekey on root).
Root: HKCU; Subkey: "Software\Classes\relic"; ValueType: string; ValueName: ""; ValueData: "URL:Relic Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\relic"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\relic\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCU; Subkey: "Software\Classes\relic\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Code]
{ True when the app invoked this installer for a silent self-update
  (/RELAUNCH=1 on the command line) — gates the relaunch [Run] entry. }
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

{ True if Dir is not already a segment of the current per-user PATH. Used to
  avoid appending our CLI dir twice across reinstalls/upgrades. }
function NeedsAddPath(Dir: String): Boolean;
var
  OrigPath: String;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  { Pad both sides with ';' so we match whole segments, not substrings. }
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

{ Strip our CLI dir back out of the per-user PATH on uninstall, leaving the rest
  of the user's PATH untouched. }
procedure RemoveCliFromPath();
var
  Dir, OrigPath, Padded, Needle: String;
  P: Integer;
begin
  Dir := ExpandConstant('{app}\cli');
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
    exit;
  Padded := ';' + OrigPath + ';';
  Needle := ';' + Dir + ';';
  { Case-insensitive find of the padded segment. }
  P := Pos(Uppercase(Needle), Uppercase(Padded));
  if P = 0 then
    exit;
  { Remove the segment plus one of the surrounding separators. }
  Delete(Padded, P, Length(Needle) - 1);
  { Unpad: drop the leading and trailing ';' we added. }
  if (Length(Padded) > 0) and (Padded[1] = ';') then Delete(Padded, 1, 1);
  if (Length(Padded) > 0) and (Padded[Length(Padded)] = ';') then Delete(Padded, Length(Padded), 1);
  RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Padded);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveCliFromPath();
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{userappdata}\relic');
    if DirExists(DataDir) then
    begin
      if MsgBox('Also delete your Relic data (clipboard history, vault, settings)?'
        + #13#10 + DataDir + #13#10#13#10
        + 'Choose No to keep it for a future reinstall.',
        mbConfirmation, MB_YESNO) = IDYES then
      begin
        DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
