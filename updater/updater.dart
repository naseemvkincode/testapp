import 'dart:io';
import 'dart:convert';

const int updateTimeout = 300;
const int pollInterval = 1;
late File logFile;
late File lockFile;

void log(String level, String message) {
  final timestamp = DateTime.now().toString().substring(0, 19);
  final line = '$timestamp [$level] $message';
  print(line);
  try {
    logFile.writeAsStringSync('$line\n', mode: FileMode.append);
  } catch (_) {}
}

void acquireLock() {
  if (lockFile.existsSync()) {
    try {
      final lockPid = int.parse(lockFile.readAsStringSync().trim());
      if (isProcessRunning(lockPid)) {
        log('ERROR', 'Another Updater.exe is running (PID $lockPid). Exiting.');
        exit(1);
      }
      log('WARNING', 'Stale lock (PID $lockPid not running). Removing.');
      lockFile.deleteSync();
    } catch (_) {
      log('WARNING', 'Corrupt lock file. Removing.');
      lockFile.deleteSync();
    }
  }
  lockFile.writeAsStringSync('${pid}');
  log('INFO', 'Lock acquired (PID $pid).');
}

void releaseLock() {
  try {
    lockFile.deleteSync();
    log('INFO', 'Lock released.');
  } catch (_) {}
}

bool isProcessRunning(int pid) {
  try {
    final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return result.stdout.toString().contains('$pid');
  } catch (_) {
    return false;
  }
}

bool waitForProcessClose(String exeName, {int timeout = updateTimeout}) {
  log('INFO', 'Waiting for $exeName to close (timeout=${timeout}s)...');
  final start = DateTime.now();

  while (DateTime.now().difference(start).inSeconds < timeout) {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'IMAGENAME eq $exeName'],
    );
    final output = result.stdout.toString().toLowerCase();
    if (!output.contains(exeName.toLowerCase())) {
      log('INFO', '$exeName has closed.');
      return true;
    }
    sleep(Duration(seconds: pollInterval));
  }

  log('ERROR', 'Timed out waiting for $exeName to close.');
  return false;
}

bool runInstaller(String installerPath) {
  log('INFO', 'Starting installer: $installerPath');
  try {
    final result = Process.runSync(
      installerPath,
      ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
    );
    log('INFO', 'Installer finished. Exit code: ${result.exitCode}');

    if (result.exitCode == 0) {
      log('INFO', 'Installer finished successfully.');
      return true;
    } else {
      log('WARNING', 'Installer exit code: ${result.exitCode} (may be acceptable).');
      return true;
    }
  } catch (e) {
    log('ERROR', 'Failed to start installer: $e');
    return false;
  }
}

bool verifyUpdatedExe(String testappExePath) {
  final file = File(testappExePath);
  if (file.existsSync()) {
    final size = file.lengthSync();
    log('INFO', 'Verified TestApp.exe exists (size: $size bytes).');
    return true;
  }
  log('ERROR', 'TestApp.exe not found at: $testappExePath');
  return false;
}

bool startTestApp(String testappExePath) {
  log('INFO', 'Starting TestApp.exe: $testappExePath');
  try {
    Process.runSync('cmd', [
      '/c',
      'start',
      '',
      testappExePath,
    ]);
    log('INFO', 'TestApp.exe started successfully.');
    return true;
  } catch (e) {
    log('ERROR', 'Failed to start TestApp.exe: $e');
    return false;
  }
}

void cleanupInstaller(String installerPath) {
  try {
    final file = File(installerPath);
    if (file.existsSync()) {
      file.deleteSync();
      log('INFO', 'Cleaned up installer: $installerPath');
    }
  } catch (e) {
    log('WARNING', 'Could not clean up installer: $e');
  }
}

void writeLogSummary(String installerPath, String testappExePath, bool success) {
  final timestamp = DateTime.now().toString().substring(0, 19);
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
  log('INFO', summary);
}

void main(List<String> args) {
  final logDir = Directory('${Platform.environment['APPDATA']}\\TestApp');
  if (!logDir.existsSync()) {
    logDir.createSync(recursive: true);
  }

  logFile = File('${logDir.path}\\update.log');
  lockFile = File('${logDir.path}\\updater.lock');

  log('INFO', 'Updater.exe started.');

  if (args.length != 2) {
    log('ERROR', 'Usage: Updater.exe <installer_path> <testapp_exe_path>');
    exit(1);
  }

  final installerPath = args[0];
  final testappExePath = args[1];
  log('INFO', 'Installer path: $installerPath');
  log('INFO', 'TestApp.exe path: $testappExePath');

  acquireLock();

  var success = false;
  try {
    if (!File(installerPath).existsSync()) {
      log('ERROR', 'Installer not found: $installerPath');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }
    log('INFO', 'Installer validated.');

    if (!Directory(Directory(testappExePath).parent.path).existsSync()) {
      log('ERROR', 'TestApp.exe directory not found: $testappExePath');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }
    log('INFO', 'TestApp.exe path validated.');

    final exeName = testappExePath.split(Platform.pathSeparator).last;
    if (!waitForProcessClose(exeName)) {
      log('ERROR', 'TestApp.exe did not close in time.');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }

    if (!runInstaller(installerPath)) {
      log('ERROR', 'Installer failed.');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }

    sleep(Duration(seconds: 2));
    if (!verifyUpdatedExe(testappExePath)) {
      log('ERROR', 'Updated TestApp.exe not found.');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }

    if (!startTestApp(testappExePath)) {
      log('ERROR', 'Failed to start TestApp.exe after update.');
      writeLogSummary(installerPath, testappExePath, false);
      return;
    }

    success = true;
    writeLogSummary(installerPath, testappExePath, true);
    log('INFO', 'Update completed successfully.');

    cleanupInstaller(installerPath);
  } catch (e) {
    log('ERROR', 'Unexpected error: $e');
    writeLogSummary(installerPath, testappExePath, false);
  } finally {
    releaseLock();
  }

  exit(success ? 0 : 1);
}
