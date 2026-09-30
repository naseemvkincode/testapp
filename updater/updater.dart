import 'dart:io';

const int updateTimeout = 300;
const int pollInterval = 1;

late File logFile;
late File lockFile;

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

void acquireLock() {
  if (lockFile.existsSync()) {
    try {
      final lockPid = int.parse(
        lockFile.readAsStringSync().trim(),
      );

      if (isProcessRunning(lockPid)) {
        log(
          'ERROR',
          'Another Updater.exe is running (PID $lockPid). Exiting.',
        );
        exit(1);
      }

      log(
        'WARNING',
        'Stale lock found. Removing.',
      );

      lockFile.deleteSync();
    } catch (_) {
      log(
        'WARNING',
        'Corrupt lock file. Removing.',
      );

      try {
        lockFile.deleteSync();
      } catch (_) {}
    }
  }

  lockFile.writeAsStringSync('$pid');

  log(
    'INFO',
    'Lock acquired (PID $pid).',
  );
}

void releaseLock() {
  try {
    if (lockFile.existsSync()) {
      lockFile.deleteSync();
    }

    log(
      'INFO',
      'Lock released.',
    );
  } catch (_) {}
}

bool isProcessRunning(int processId) {
  try {
    final result = Process.runSync(
      'tasklist',
      [
        '/FI',
        'PID eq $processId',
        '/NH',
      ],
    );

    return result.stdout
        .toString()
        .contains('$processId');
  } catch (_) {
    return false;
  }
}

bool waitForProcessClose(
  String exeName, {
  int timeout = updateTimeout,
}) {
  log(
    'INFO',
    'Waiting for $exeName to close...',
  );

  final start = DateTime.now();

  while (
      DateTime.now().difference(start).inSeconds <
          timeout) {
    try {
      final result = Process.runSync(
        'tasklist',
        [
          '/FI',
          'IMAGENAME eq $exeName',
          '/NH',
        ],
      );

      final output =
          result.stdout.toString().toLowerCase();

      if (!output.contains(exeName.toLowerCase())) {
        log(
          'INFO',
          '$exeName has closed.',
        );

        return true;
      }
    } catch (e) {
      log(
        'WARNING',
        'Could not check process: $e',
      );
    }

    sleep(
      const Duration(
        seconds: pollInterval,
      ),
    );
  }

  log(
    'ERROR',
    'Timed out waiting for $exeName to close.',
  );

  return false;
}

/// Runs the Inno Setup installer with Windows administrator elevation.
///
/// IMPORTANT:
/// TestApp is installed under Program Files, so the installer
/// needs administrator permission to replace the existing files.
bool runInstaller(String installerPath) {
  log(
    'INFO',
    'Starting installer with administrator elevation.',
  );

  log(
    'INFO',
    'Installer: $installerPath',
  );

  try {
    final result = Process.runSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '''
\$process = Start-Process `
  -FilePath "$installerPath" `
  -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/SP-" `
  -Verb RunAs `
  -Wait `
  -PassThru

exit \$process.ExitCode
''',
      ],
    );

    log(
      'INFO',
      'Installer process finished.',
    );

    log(
      'INFO',
      'PowerShell exit code: ${result.exitCode}',
    );

    if (result.stdout.toString().isNotEmpty) {
      log(
        'INFO',
        'PowerShell output: ${result.stdout}',
      );
    }

    if (result.stderr.toString().isNotEmpty) {
      log(
        'WARNING',
        'PowerShell error: ${result.stderr}',
      );
    }

    if (result.exitCode == 0) {
      log(
        'INFO',
        'Installer completed successfully.',
      );

      return true;
    }

    log(
      'ERROR',
      'Installer failed with exit code ${result.exitCode}.',
    );

    return false;
  } catch (e) {
    log(
      'ERROR',
      'Failed to start installer: $e',
    );

    return false;
  }
}

bool verifyUpdatedExe(String testappExePath) {
  final file = File(testappExePath);

  if (!file.existsSync()) {
    log(
      'ERROR',
      'TestApp.exe not found: $testappExePath',
    );

    return false;
  }

  final size = file.lengthSync();

  log(
    'INFO',
    'TestApp.exe exists after installation.',
  );

  log(
    'INFO',
    'TestApp.exe size: $size bytes.',
  );

  return size > 0;
}

bool startTestApp(String testappExePath) {
  log(
    'INFO',
    'Starting TestApp.exe: $testappExePath',
  );

  try {
    Process.start(
      testappExePath,
      [],
      mode: ProcessStartMode.detached,
      workingDirectory:
          File(testappExePath).parent.path,
    );

    log(
      'INFO',
      'TestApp.exe restart requested.',
    );

    return true;
  } catch (e) {
    log(
      'ERROR',
      'Failed to start TestApp.exe: $e',
    );

    return false;
  }
}

void cleanupInstaller(String installerPath) {
  try {
    final file = File(installerPath);

    if (file.existsSync()) {
      file.deleteSync();

      log(
        'INFO',
        'Installer cleaned up.',
      );
    }
  } catch (e) {
    log(
      'WARNING',
      'Could not clean up installer: $e',
    );
  }
}

void writeLogSummary(
  String installerPath,
  String testappExePath,
  bool success,
) {
  final timestamp =
      DateTime.now().toString().substring(0, 19);

  final status = success ? 'SUCCESS' : 'FAILED';

  final summary = '''
==================================================
Update Summary
==================================================
Timestamp:  $timestamp
Status:     $status
Installer:  $installerPath
Target:     $testappExePath
==================================================
''';

  log(
    'INFO',
    summary,
  );
}

void main(List<String> args) {
  final appData =
      Platform.environment['APPDATA'];

  if (appData == null || appData.isEmpty) {
    print('APPDATA environment variable not found.');
    exit(1);
  }

  final logDir = Directory(
    '$appData\\TestApp',
  );

  if (!logDir.existsSync()) {
    logDir.createSync(
      recursive: true,
    );
  }

  logFile = File(
    '${logDir.path}\\update.log',
  );

  lockFile = File(
    '${logDir.path}\\updater.lock',
  );

  log(
    'INFO',
    '==========================================',
  );

  log(
    'INFO',
    'Updater.exe started.',
  );

  log(
    'INFO',
    'Arguments count: ${args.length}',
  );

  if (args.length != 2) {
    log(
      'ERROR',
      'Usage: Updater.exe <installer_path> <testapp_exe_path>',
    );

    exit(1);
  }

  final installerPath = args[0];
  final testappExePath = args[1];

  log(
    'INFO',
    'Installer path: $installerPath',
  );

  log(
    'INFO',
    'TestApp path: $testappExePath',
  );

  acquireLock();

  var success = false;

  try {
    // --------------------------------------------------
    // 1. Check installer
    // --------------------------------------------------

    final installerFile = File(installerPath);

    if (!installerFile.existsSync()) {
      log(
        'ERROR',
        'Installer not found: $installerPath',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    final installerSize =
        installerFile.lengthSync();

    log(
      'INFO',
      'Installer found.',
    );

    log(
      'INFO',
      'Installer size: $installerSize bytes.',
    );

    if (installerSize < 1000) {
      log(
        'ERROR',
        'Installer file is too small.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    // --------------------------------------------------
    // 2. Check TestApp directory
    // --------------------------------------------------

    final testappFile =
        File(testappExePath);

    final testappDirectory =
        testappFile.parent;

    if (!testappDirectory.existsSync()) {
      log(
        'ERROR',
        'TestApp directory does not exist.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    log(
      'INFO',
      'TestApp directory validated.',
    );

    // --------------------------------------------------
    // 3. Close TestApp
    // --------------------------------------------------

    final exeName =
        testappFile.uri.pathSegments.last;

    if (!waitForProcessClose(exeName)) {
      log(
        'ERROR',
        'TestApp did not close.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    // --------------------------------------------------
    // 4. Run installer as Administrator
    // --------------------------------------------------

    final installerSuccess =
        runInstaller(installerPath);

    if (!installerSuccess) {
      log(
        'ERROR',
        'Installer execution failed.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    // --------------------------------------------------
    // 5. Give Windows/Inno Setup time to finish
    // --------------------------------------------------

    log(
      'INFO',
      'Waiting for installation to settle...',
    );

    sleep(
      const Duration(seconds: 3),
    );

    // --------------------------------------------------
    // 6. Verify TestApp.exe
    // --------------------------------------------------

    if (!verifyUpdatedExe(testappExePath)) {
      log(
        'ERROR',
        'TestApp.exe verification failed.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    // --------------------------------------------------
    // 7. Restart TestApp
    // --------------------------------------------------

    if (!startTestApp(testappExePath)) {
      log(
        'ERROR',
        'Failed to restart TestApp.',
      );

      writeLogSummary(
        installerPath,
        testappExePath,
        false,
      );

      return;
    }

    success = true;

    writeLogSummary(
      installerPath,
      testappExePath,
      true,
    );

    log(
      'INFO',
      'Update completed successfully.',
    );

    // Give the new app a moment to start.
    sleep(
      const Duration(seconds: 2),
    );

    // Cleanup downloaded installer.
    cleanupInstaller(installerPath);
  } catch (e) {
    log(
      'ERROR',
      'Unexpected updater error: $e',
    );

    writeLogSummary(
      installerPath,
      testappExePath,
      false,
    );
  } finally {
    releaseLock();
  }

  log(
    'INFO',
    'Updater.exe exiting.',
  );

  exit(success ? 0 : 1);
}