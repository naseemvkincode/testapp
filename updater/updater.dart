import 'dart:io';

const int updateTimeout = 300;
const int pollInterval = 1;

late File logFile;
late File lockFile;

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void log(String level, String message) {
  final timestamp = DateTime.now().toString().substring(0, 19);
  final line = '$timestamp [$level] $message';

  print(line);

  try {
    logFile.writeAsStringSync(
      '$line\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Lock file — prevents concurrent updaters
// ---------------------------------------------------------------------------

void acquireLock() {
  if (lockFile.existsSync()) {
    try {
      final lockPid = int.parse(
        lockFile.readAsStringSync().trim(),
      );

      if (isProcessRunning(lockPid)) {
        log('ERROR',
            'Another Updater.exe is running (PID $lockPid). Exiting.');
        exit(1);
      }

      log('WARNING', 'Stale lock found. Removing.');
      lockFile.deleteSync();
    } catch (_) {
      log('WARNING', 'Corrupt lock file. Removing.');
      try {
        lockFile.deleteSync();
      } catch (_) {}
    }
  }

  lockFile.writeAsStringSync('$pid');
  log('INFO', 'Lock acquired (PID $pid).');
}

void releaseLock() {
  try {
    if (lockFile.existsSync()) {
      lockFile.deleteSync();
    }
    log('INFO', 'Lock released.');
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

bool isProcessRunning(int processId) {
  try {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'PID eq $processId', '/NH'],
    );
    return result.stdout.toString().contains('$processId');
  } catch (_) {
    return false;
  }
}

bool waitForProcessClose(
  String exeName, {
  int timeout = updateTimeout,
}) {
  log('INFO', 'Waiting for $exeName to close...');

  final start = DateTime.now();

  while (DateTime.now().difference(start).inSeconds < timeout) {
    try {
      final result = Process.runSync(
        'tasklist',
        ['/FI', 'IMAGENAME eq $exeName', '/NH'],
      );

      final output = result.stdout.toString().toLowerCase();

      if (!output.contains(exeName.toLowerCase())) {
        log('INFO', '$exeName has closed.');
        // Small settle so any open file handles fully release before
        // the installer tries to overwrite files under {app}.
        sleep(const Duration(milliseconds: 500));
        return true;
      }
    } catch (e) {
      log('WARNING', 'Could not check process: $e');
    }

    sleep(const Duration(seconds: pollInterval));
  }

  log('ERROR', 'Timed out waiting for $exeName to close.');
  return false;
}

// ---------------------------------------------------------------------------
// File snapshot — used for before/after comparison
// ---------------------------------------------------------------------------

class ExeSnapshot {
  final bool exists;
  final int size;
  final DateTime? modified;
  final String? productVersion;

  ExeSnapshot({
    required this.exists,
    required this.size,
    required this.modified,
    required this.productVersion,
  });

  @override
  String toString() =>
      'exists=$exists, size=$size, modified=$modified, version=$productVersion';
}

/// Reads the Windows VERSIONINFO ProductVersion resource of an EXE.
/// Returns null if it cannot be read.
String? readProductVersion(String exePath) {
  try {
    final result = Process.runSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "(Get-Item -LiteralPath '$exePath').VersionInfo.ProductVersion",
      ],
    );

    if (result.exitCode != 0) return null;

    final out = result.stdout.toString().trim();
    if (out.isEmpty) return null;
    return out;
  } catch (_) {
    return null;
  }
}

ExeSnapshot snapshotExe(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    return ExeSnapshot(
      exists: false,
      size: 0,
      modified: null,
      productVersion: null,
    );
  }

  int size = 0;
  DateTime? modified;
  try {
    size = f.lengthSync();
    modified = f.lastModifiedSync();
  } catch (_) {}

  final version = readProductVersion(path);

  return ExeSnapshot(
    exists: true,
    size: size,
    modified: modified,
    productVersion: version,
  );
}

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------

/// Compares two version strings loosely (e.g. "1.8.0" vs "1.8.0.0").
/// Returns true when [actual] represents the [expected] version.
bool versionMatches(String? actual, String expected) {
  if (actual == null) return false;

  List<int> parse(String v) {
    final parts = <int>[];
    for (final p in v.split(RegExp(r'[.\-+]'))) {
      final n = int.tryParse(p.trim());
      if (n == null) break;
      parts.add(n);
    }
    while (parts.length < 4) {
      parts.add(0);
    }
    return parts.take(4).toList();
  }

  final a = parse(actual);
  final e = parse(expected);
  for (var i = 0; i < 4; i++) {
    if (a[i] != e[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Installer execution
// ---------------------------------------------------------------------------

/// Interprets Inno Setup exit codes. Only 0 means "install completed".
/// See https://jrsoftware.org/ishelp/index.php?topic=setupexitcodes
///
/// Returns (success, description).
({bool success, String description}) interpretInnoExitCode(int code) {
  switch (code) {
    case 0:
      return (success: true, description: 'Setup completed successfully.');
    case 1:
      return (
        success: false,
        description: 'Setup failed to initialize.'
      );
    case 2:
      return (
        success: false,
        description: 'User clicked Cancel or chose No in a prompt.'
      );
    case 3:
      return (
        success: false,
        description: 'Fatal error preparing to install.'
      );
    case 4:
      return (
        success: false,
        description: 'Fatal error during installation.'
      );
    case 5:
      return (
        success: false,
        description: 'User cancelled during installation.'
      );
    case 6:
      return (
        success: false,
        description: 'Setup was stopped by a preparing-to-install action.'
      );
    case 7:
      return (
        success: false,
        description: 'Preparation step said Setup cannot proceed.'
      );
    case 8:
      return (
        success: false,
        description: 'Preparation step said Setup cannot proceed; restart required.'
      );
    default:
      return (
        success: false,
        description: 'Unknown installer exit code: $code'
      );
  }
}

/// Runs the Inno Setup installer with admin elevation, and — critically —
/// FORCES the install directory to [installDir] using /DIR="..." so the
/// new files land in the SAME folder as the currently running app,
/// regardless of what DefaultDirName resolves to on this machine.
///
/// Returns the installer's actual exit code (as reported by PowerShell),
/// or -1 if we could not even start it.
int runInstaller(String installerPath, String installDir) {
  log('INFO', 'Starting installer with administrator elevation.');
  log('INFO', 'Installer   : $installerPath');
  log('INFO', 'Install dir : $installDir  (forced via /DIR)');

  // Inno Setup silent-install flags:
  //   /VERYSILENT        — no UI at all
  //   /SUPPRESSMSGBOXES  — suppress error message boxes
  //   /NORESTART         — never auto-reboot
  //   /SP-               — skip "This will install..." confirm
  //   /DIR="..."         — override DefaultDirName; MUST match running install
  //   /CLOSEAPPLICATIONS — let Inno close any leftover instances
  //   /RESTARTAPPLICATIONS=no  — we do the restart ourselves
  //   /LOG="..."         — write Inno's own install log for diagnostics
  final innoLogPath = '${logFile.parent.path}\\inno-install.log';

  final psScript = '''
\$ErrorActionPreference = "Stop"
try {
  \$process = Start-Process `
    -FilePath "$installerPath" `
    -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/SP-","/CLOSEAPPLICATIONS","/RESTARTAPPLICATIONS=no","/DIR=`"$installDir`"","/LOG=`"$innoLogPath`"" `
    -Verb RunAs `
    -Wait `
    -PassThru
  exit \$process.ExitCode
} catch {
  Write-Error \$_.Exception.Message
  exit 1223  # ERROR_CANCELLED (UAC declined etc.)
}
''';

  try {
    final result = Process.runSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        psScript,
      ],
    );

    log('INFO', 'Installer process finished.');
    log('INFO', 'PowerShell exit code (== installer exit code): ${result.exitCode}');

    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (stdout.isNotEmpty) log('INFO', 'PowerShell stdout: $stdout');
    if (stderr.isNotEmpty) log('WARNING', 'PowerShell stderr: $stderr');

    // Special: 1223 == UAC declined by user.
    if (result.exitCode == 1223) {
      log('ERROR', 'UAC elevation was declined by the user.');
    }

    return result.exitCode;
  } catch (e) {
    log('ERROR', 'Failed to start installer: $e');
    return -1;
  }
}

// ---------------------------------------------------------------------------
// Post-install verification
// ---------------------------------------------------------------------------

/// Verifies that the exe at [testappExePath] was actually replaced by the
/// installer and now matches [expectedVersion].
///
/// Verification is strict:
///   1. File must still exist and be non-empty.
///   2. ProductVersion (from the exe's VERSIONINFO resource) must match
///      [expectedVersion]. This is authoritative: it proves the new binary
///      is on disk at the expected path.
///   3. If ProductVersion cannot be read (rare — corrupt install), fall
///      back to: modified time must be newer than the pre-install snapshot
///      AND size must differ from the pre-install snapshot.
///
/// Returns true only if the file at the ORIGINAL path is really the new
/// version.
bool verifyReplacement({
  required String testappExePath,
  required ExeSnapshot before,
  required ExeSnapshot after,
  required String expectedVersion,
}) {
  log('INFO', 'Verifying replacement at: $testappExePath');
  log('INFO', 'Before install : $before');
  log('INFO', 'After  install : $after');
  log('INFO', 'Expected version: $expectedVersion');

  if (!after.exists) {
    log('ERROR', 'TestApp.exe missing at target path after install.');
    return false;
  }

  if (after.size <= 0) {
    log('ERROR', 'TestApp.exe is empty after install.');
    return false;
  }

  // Primary check — embedded ProductVersion.
  if (after.productVersion != null) {
    if (versionMatches(after.productVersion, expectedVersion)) {
      log('INFO',
          'ProductVersion check PASSED (${after.productVersion} == $expectedVersion).');
      return true;
    }
    log('ERROR',
        'ProductVersion mismatch: on-disk="${after.productVersion}", expected="$expectedVersion".');
    log('ERROR',
        'The installer did NOT replace the exe at $testappExePath. '
        'It probably installed into a different directory. Aborting relaunch.');
    return false;
  }

  // Fallback — could not read ProductVersion. Compare against snapshot.
  log('WARNING',
      'Could not read ProductVersion; falling back to mtime/size comparison.');

  final mtimeChanged = before.modified != null &&
      after.modified != null &&
      after.modified!.isAfter(before.modified!);

  final sizeChanged = before.size != after.size;

  if (mtimeChanged && sizeChanged) {
    log('INFO',
        'File replaced (mtime advanced AND size changed). Accepting.');
    return true;
  }

  log('ERROR',
      'File appears UNCHANGED (mtimeChanged=$mtimeChanged, sizeChanged=$sizeChanged). '
      'Refusing to relaunch what is almost certainly the old binary.');
  return false;
}

// ---------------------------------------------------------------------------
// Relaunch
// ---------------------------------------------------------------------------

bool startTestApp(String testappExePath) {
  log('INFO', 'Launching updated TestApp.exe from: $testappExePath');

  try {
    Process.start(
      testappExePath,
      const [],
      mode: ProcessStartMode.detached,
      workingDirectory: File(testappExePath).parent.path,
    );
    log('INFO', 'TestApp.exe launch requested.');
    return true;
  } catch (e) {
    log('ERROR', 'Failed to start TestApp.exe: $e');
    return false;
  }
}

// ---------------------------------------------------------------------------
// Cleanup and summary
// ---------------------------------------------------------------------------

void cleanupInstaller(String installerPath) {
  try {
    final file = File(installerPath);
    if (file.existsSync()) {
      file.deleteSync();
      log('INFO', 'Installer cleaned up.');
    }
  } catch (e) {
    log('WARNING', 'Could not clean up installer: $e');
  }
}

void writeLogSummary({
  required String installerPath,
  required String testappExePath,
  required String installDir,
  required String expectedVersion,
  required int installerExitCode,
  required ExeSnapshot? before,
  required ExeSnapshot? after,
  required String launchedPath,
  required bool success,
}) {
  final timestamp = DateTime.now().toString().substring(0, 19);
  final status = success ? 'SUCCESS' : 'FAILED';

  final summary = '''
==================================================
Update Summary
==================================================
Timestamp        : $timestamp
Status           : $status
Installer        : $installerPath
Install dir      : $installDir
TestApp target   : $testappExePath
Expected version : $expectedVersion
Installer exit   : $installerExitCode
Before snapshot  : ${before ?? '(not taken)'}
After  snapshot  : ${after ?? '(not taken)'}
Launched path    : ${launchedPath.isEmpty ? '(none)' : launchedPath}
==================================================
''';
  log('INFO', summary);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(List<String> args) {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    print('APPDATA environment variable not found.');
    exit(1);
  }

  final logDir = Directory('$appData\\TestApp');
  if (!logDir.existsSync()) {
    logDir.createSync(recursive: true);
  }

  logFile = File('${logDir.path}\\update.log');
  lockFile = File('${logDir.path}\\updater.lock');

  log('INFO', '==========================================');
  log('INFO', 'Updater.exe started.');
  log('INFO', 'Own path         : ${Platform.resolvedExecutable}');
  log('INFO', 'Arguments count  : ${args.length}');
  log('INFO', 'Arguments        : $args');

  if (args.length < 3) {
    log('ERROR',
        'Usage: Updater.exe <installer_path> <testapp_exe_path> <expected_version>');
    exit(1);
  }

  final installerPath = args[0];
  final testappExePath = args[1];
  final expectedVersion = args[2];

  final installDir = File(testappExePath).parent.path;

  log('INFO', 'Installer path   : $installerPath');
  log('INFO', 'TestApp exe path : $testappExePath');
  log('INFO', 'Install dir      : $installDir');
  log('INFO', 'Expected version : $expectedVersion');

  acquireLock();

  var success = false;
  var installerExitCode = -1;
  ExeSnapshot? before;
  ExeSnapshot? after;
  var launchedPath = '';

  try {
    // ------------------------------------------------------------------
    // 1. Validate installer file
    // ------------------------------------------------------------------
    final installerFile = File(installerPath);
    if (!installerFile.existsSync()) {
      log('ERROR', 'Installer not found: $installerPath');
      return;
    }

    final installerSize = installerFile.lengthSync();
    log('INFO', 'Installer found. Size: $installerSize bytes.');

    // Real Inno installers are megabytes, never < 100 KB.
    if (installerSize < 100 * 1024) {
      log('ERROR',
          'Installer file is too small ($installerSize bytes) — probably a truncated download or an HTML error page.');
      return;
    }

    // ------------------------------------------------------------------
    // 2. Validate install directory exists
    // ------------------------------------------------------------------
    final testappFile = File(testappExePath);
    final testappDirectory = testappFile.parent;

    if (!testappDirectory.existsSync()) {
      log('ERROR', 'TestApp directory does not exist: $installDir');
      return;
    }
    log('INFO', 'TestApp directory validated.');

    // ------------------------------------------------------------------
    // 3. Take PRE-install snapshot (so we can prove replacement later)
    // ------------------------------------------------------------------
    before = snapshotExe(testappExePath);
    log('INFO', 'Pre-install  snapshot: $before');

    if (!before.exists) {
      log('ERROR',
          'TestApp.exe does not exist at $testappExePath before install. Aborting — we would not be updating anything.');
      return;
    }

    // ------------------------------------------------------------------
    // 4. Wait for TestApp.exe to fully close (with all handles released)
    // ------------------------------------------------------------------
    final exeName = testappExePath.split(RegExp(r'[\\/]')).last;
    log('INFO', 'Waiting for process image "$exeName" to exit.');

    if (!waitForProcessClose(exeName)) {
      log('ERROR', 'TestApp did not close in time. Aborting update.');
      return;
    }

    // ------------------------------------------------------------------
    // 5. Run installer with /DIR="<installDir>" — this is the FIX.
    //    Forces the installer to write into the same folder the running
    //    TestApp.exe lives in, regardless of DefaultDirName.
    // ------------------------------------------------------------------
    installerExitCode = runInstaller(installerPath, installDir);
    final interpretation = interpretInnoExitCode(installerExitCode);
    log('INFO', 'Installer result: ${interpretation.description}');

    if (!interpretation.success) {
      log('ERROR',
          'Installer did NOT succeed (exit code $installerExitCode). Not verifying, not relaunching.');
      return;
    }

    // ------------------------------------------------------------------
    // 6. Let the filesystem settle — Windows sometimes lags on the
    //    freshly written exe visible to VersionInfo queries.
    // ------------------------------------------------------------------
    log('INFO', 'Waiting for installation to settle...');
    sleep(const Duration(seconds: 3));

    // ------------------------------------------------------------------
    // 7. Take POST-install snapshot and verify replacement really
    //    happened at the ORIGINAL path.
    // ------------------------------------------------------------------
    after = snapshotExe(testappExePath);
    log('INFO', 'Post-install snapshot: $after');

    final replaced = verifyReplacement(
      testappExePath: testappExePath,
      before: before,
      after: after,
      expectedVersion: expectedVersion,
    );

    if (!replaced) {
      log('ERROR',
          'Verification failed — the exe at $testappExePath is NOT the expected $expectedVersion. Update FAILED. NOT relaunching.');
      return;
    }

    // ------------------------------------------------------------------
    // 8. Relaunch — from the SAME exact path we were asked to update.
    // ------------------------------------------------------------------
    if (!startTestApp(testappExePath)) {
      log('ERROR', 'Failed to relaunch TestApp.');
      return;
    }
    launchedPath = testappExePath;

    success = true;
    log('INFO', 'Update completed successfully.');

    sleep(const Duration(seconds: 2));

    cleanupInstaller(installerPath);
  } catch (e, st) {
    log('ERROR', 'Unexpected updater error: $e');
    log('ERROR', '$st');
  } finally {
    writeLogSummary(
      installerPath: installerPath,
      testappExePath: testappExePath,
      installDir: installDir,
      expectedVersion: expectedVersion,
      installerExitCode: installerExitCode,
      before: before,
      after: after,
      launchedPath: launchedPath,
      success: success,
    );
    releaseLock();
  }

  log('INFO', 'Updater.exe exiting with code ${success ? 0 : 1}.');
  exit(success ? 0 : 1);
}