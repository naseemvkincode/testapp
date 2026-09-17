; TestApp Inno Setup Script
; Works for both v1.0.0 and v1.1.0 upgrades

#define MyAppName "TestApp"
#define MyAppPublisher "TestApp"
#define MyAppExeName "TestApp.exe"
#define MyUpdaterExeName "Updater.exe"

; Default version - change this when building v1.1.0
#define MyAppVersion "1.0.0"
#define MyAppVersionNum "1.0.0.0"

; Source directory - where flutter build windows --release outputs files
; Flutter output: build\windows\x64\runner\Release\
#define MySourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B1E4F5A2-3C7D-4E8F-9A1B-2D3E4F5A6B7C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=..\output
OutputBaseFilename=TestApp-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=force
CloseApplicationsFilter={#MyAppExeName}
RestartApplications=no
AllowCancelDuringInstall=yes
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
; Main application files from Flutter build output
Source: "{#MySourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion

; Flutter data directory
Source: "{#MySourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; Updater - bundled with the app
Source: "..\Updater.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Only launch the app after install if it was an upgrade (not first install)
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent; Check: IsUpgrade

[Code]
function IsUpgrade: Boolean;
var
  ResultCode: Integer;
begin
  Result := RegKeyExists(HKEY_LOCAL_MACHINE,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B1E4F5A2-3C7D-4E8F-9A1B-2D3E4F5A6B7C}_is1');
end;

// Ensure the app is not running before install
function InitializeSetup: Boolean;
var
  ResultCode: Integer;
  WbExec: Integer;
begin
  Result := True;

  // Try to close TestApp.exe if it is running
  Exec('taskkill', '/F /IM {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill', '/F /IM {#MyUpdaterExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Small delay to let files release
  Sleep(500);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  AppPath: String;
begin
  if CurStep = ssPostInstall then
  begin
    AppPath := ExpandConstant('{app}');
    RegWriteStringValue(HKEY_LOCAL_MACHINE,
      'Software\TestApp',
      'InstallPath', AppPath);
    RegWriteStringValue(HKEY_LOCAL_MACHINE,
      'Software\TestApp',
      'Version', '{#MyAppVersion}');
  end;
end;
