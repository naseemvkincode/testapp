; TestApp Inno Setup Installer

[Setup]
AppId={{05030232-5A51-47E0-9B1B-467ECFCA679E}
AppName=TestApp
AppVersion=1.3.0
DefaultDirName={autopf}\TestApp
UninstallDisplayIcon={app}\TestApp.exe

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

DisableProgramGroupPage=yes

OutputDir=C:\Vikn codes\testapp\installer
OutputBaseFilename=TestApp-Setup-1.3.0

SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "C:\Vikn codes\testapp\build\windows\x64\runner\Release\TestApp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Vikn codes\testapp\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Vikn codes\testapp\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; IMPORTANT: Updater.exe must be installed with TestApp
Source: "C:\Vikn codes\testapp\Updater.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\TestApp"; Filename: "{app}\TestApp.exe"
Name: "{autodesktop}\TestApp"; Filename: "{app}\TestApp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TestApp.exe"; Description: "{cm:LaunchProgram,TestApp}"; Flags: nowait postinstall skipifsilent