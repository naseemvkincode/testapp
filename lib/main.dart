import 'dart:io';

import 'package:flutter/material.dart';

import 'update_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TestApp());
}

class TestApp extends StatelessWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TestApp',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const TestAppHomePage(),
    );
  }
}

class TestAppHomePage extends StatefulWidget {
  const TestAppHomePage({super.key});

  @override
  State<TestAppHomePage> createState() => _TestAppHomePageState();
}

class _TestAppHomePageState extends State<TestAppHomePage> {
  static const String currentVersion = '1.0.0';

  String status = 'Ready';
  bool isUpdating = false;
  bool isCheckingUpdate = false;

  String get applicationPath => Platform.resolvedExecutable;

  String get updaterPath =>
      '${File(applicationPath).parent.path}\\Updater.exe';

  Future<void> checkForUpdate() async {
    if (isCheckingUpdate || isUpdating) return;

    setState(() {
      isCheckingUpdate = true;
      status = 'Checking for updates...';
    });

    try {
      final info = await UpdateService.checkForUpdate(currentVersion);

      if (!mounted) return;

      if (info == null) {
        setState(() {
          isCheckingUpdate = false;
          status = 'App is up to date';
        });
        return;
      }

      setState(() {
        isCheckingUpdate = false;
        status = 'Update available: v${info.latestVersion}';
      });

      _showUpdateDialog(info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isCheckingUpdate = false;
        status = 'Update check failed';
      });
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _UpdateDialog(
        info: info,
        currentVersion: currentVersion,
        onConfirm: () => _startDownload(info),
      ),
    );
  }

  Future<void> _startDownload(UpdateInfo info) async {
    Navigator.of(context).pop();

    setState(() {
      isUpdating = true;
      status = 'Downloading update...';
    });

    try {
      final installerPath = await UpdateService.downloadInstaller(
        info,
        (progress) {
          if (mounted) {
            setState(() {
              status =
                  'Downloading: ${(progress * 100).toStringAsFixed(0)}%';
            });
          }
        },
      );

      if (!mounted) return;

      if (installerPath == null) {
        setState(() {
          isUpdating = false;
          status = 'Download failed';
        });
        return;
      }

      setState(() {
        status = 'Starting updater...';
      });

      final updater = File(updaterPath);
      if (!updater.existsSync()) {
        setState(() {
          isUpdating = false;
          status = 'Updater.exe not found';
        });
        return;
      }

      await Process.start(
        updater.path,
        [installerPath, applicationPath],
        mode: ProcessStartMode.detached,
        workingDirectory: File(updater.path).parent.path,
      );

      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isUpdating = false;
        status = 'Update failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TestApp'),
        centerTitle: true,
      ),
      body: Center(
        child: SizedBox(
          width: 500,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.system_update,
                    size: 70,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'TestApp',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Current Version',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    currentVersion,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: (isCheckingUpdate || isUpdating)
                          ? null
                          : checkForUpdate,
                      icon: isCheckingUpdate
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download),
                      label: Text(
                        isCheckingUpdate
                            ? 'Checking...'
                            : 'Check for Updates',
                        style: const TextStyle(fontSize: 17),
                      ),
                    ),
                  ),
                  const SizedBox(height: 25),
                  Text(
                    'Status: $status',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _statusColor(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor() {
    if (status.contains('up to date')) return Colors.green;
    if (status.contains('Update available')) return Colors.orange;
    if (status.contains('failed') || status.contains('not found')) {
      return Colors.red;
    }
    if (status.contains('Downloading') || status.contains('Checking')) {
      return Colors.blue;
    }
    return Colors.black87;
  }
}

class _UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  final String currentVersion;
  final VoidCallback onConfirm;

  const _UpdateDialog({
    required this.info,
    required this.currentVersion,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.system_update, size: 48),
      title: const Text('Update Available'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Current: '),
              Text(currentVersion,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Text(' → '),
              Text(info.latestVersion,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  )),
            ],
          ),
          if (info.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Release Notes:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(info.releaseNotes),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: onConfirm,
          icon: const Icon(Icons.download),
          label: const Text('Install Update'),
        ),
      ],
    );
  }
}
