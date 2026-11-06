; Lumora — Windows installer (Inno Setup 6.3+)
;
; Build (from the repository root, after `flutter build windows --release` and
; `cargo build --release -p lumora-ffi --features media` in core/):
;
;   iscc /DAppVersion=1.0.0 packaging\windows\lumora.iss
;
; Optional defines:
;   /DBuildDir=<dir>   Flutter release bundle   (default app\build\windows\x64\runner\Release)
;   /DFfiDll=<file>    lumora_ffi.dll           (default core\target\release\lumora_ffi.dll)
;   /DCliExe=<file>    lumorad.exe (optional)   (default core\target\release\lumorad.exe)
;
; What it does:
;   * installs the Flutter bundle (lumora.exe, flutter_windows.dll, data\…) + lumora_ffi.dll
;     (+ the VC++ runtime DLLs if they were copied next to lumora.exe, see README.md)
;   * registers the lumora:// URL protocol (lumora://add/…, lumora://join/…, lumora://remote/…)
;   * adds inbound Windows Firewall rules for lumora.exe (UDP: QUIC + hole punching + LAN discovery)
;   * Start-menu shortcut, optional desktop shortcut, clean uninstall (rules + protocol removed;
;     user data in %APPDATA% is kept unless the user ticks the box in the uninstaller prompt)

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef FfiDll
  #define FfiDll "..\..\core\target\release\lumora_ffi.dll"
#endif
#ifndef CliExe
  #define CliExe "..\..\core\target\release\lumorad.exe"
#endif

#define AppName "Lumora"
#define AppExe "lumora.exe"
#define AppPublisher "Lumora"
#define AppURL "https://getlumora.pages.dev"
#define AppUpdatesURL "https://github.com/hoangtuvungcao/get_lumora/releases"
#define FwRule "Lumora (UDP in)"
#define FwRuleLan "Lumora LAN discovery (UDP in)"

[Setup]
; Never change AppId: upgrades and uninstall are keyed on it.
AppId={{A6D65E34-2549-512E-A78A-D2A68993B394}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppUpdatesURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Firewall rules + HKLM protocol registration need elevation.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
SetupIconFile=..\..\branding\icons\windows\lumora.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir=Output
OutputBaseFilename=Lumora-Setup-{#AppVersion}-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Close a running Lumora (Restart Manager) so lumora_ffi.dll can be replaced.
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
; Free-form (tags like 1.2.0-beta are fine); the numeric VersionInfoVersion stays at its default.
VersionInfoTextVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
en.FirewallTask=Allow Lumora through Windows Firewall (recommended: direct, faster connections)
en.LaunchApp=Launch Lumora
en.RemoveData=Also delete your Lumora data (messages, keys, identity) from this PC?%n%nChoose No to keep them for a later reinstall.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "firewall"; Description: "{cm:FirewallTask}"; GroupDescription: "Network:"

[Files]
; Flutter bundle (lumora.exe, flutter_windows.dll, plugins, data\flutter_assets, icudtl.dat, VC runtime if bundled)
Source: "{#BuildDir}\*"; DestDir: "{app}"; Excludes: "lumora_ffi.dll,*.pdb,*.lib,*.exp"; Flags: ignoreversion recursesubdirs createallsubdirs
; Rust core (always taken from the cargo output so a stale copy in the bundle can't win)
Source: "{#FfiDll}"; DestDir: "{app}"; Flags: ignoreversion
; Optional headless daemon (JSON-lines API), handy for support/diagnostics
Source: "{#CliExe}"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\branding\icons\windows\lumora.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\lumora.ico"; AppUserModelID: "vn.lumora.app"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\lumora.ico"; AppUserModelID: "vn.lumora.app"; Tasks: desktopicon

[Registry]
; lumora:// URL protocol → lumora.exe "lumora://…" (main.dart reads it from argv)
Root: HKA; Subkey: "Software\Classes\lumora"; ValueType: string; ValueName: ""; ValueData: "URL:Lumora Protocol"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\lumora"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\lumora\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKA; Subkey: "Software\Classes\lumora\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""

[Run]
; Remove stale rules first (re-install / upgrade / moved install dir), then add fresh ones.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FwRule}"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring Windows Firewall..."; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FwRuleLan}"""; Flags: runhidden waituntilterminated; Tasks: firewall
; QUIC listener + STUN + UDP hole punching use one UDP socket on a random/configured port:
; allow inbound UDP for the program on every profile (hole punching mostly happens on "Public" Wi-Fi).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FwRule}"" dir=in action=allow program=""{app}\{#AppExe}"" protocol=UDP profile=any edge=deferuser enable=yes description=""Lumora P2P (QUIC, NAT hole punching)"""; Flags: runhidden waituntilterminated; Tasks: firewall
; LAN discovery (multicast) is limited to the local subnet.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FwRuleLan}"" dir=in action=allow program=""{app}\{#AppExe}"" protocol=UDP profile=private,domain remoteip=localsubnet enable=yes description=""Lumora LAN discovery"""; Flags: runhidden waituntilterminated; Tasks: firewall
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FwRule}"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFwRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FwRuleLan}"""; Flags: runhidden waituntilterminated; RunOnceId: "DelFwRuleLan"

[UninstallDelete]
Type: files; Name: "{app}\lumora.ico"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: string;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { path_provider: %APPDATA%\<CompanyName>\<ProductName> from Runner.rc. Identity keys and the
      encrypted DB live there; only remove them on explicit consent. }
    DataDir := ExpandConstant('{userappdata}\vn.lumora\Lumora');
    if DirExists(DataDir) and not UninstallSilent then
      if MsgBox(CustomMessage('RemoveData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
