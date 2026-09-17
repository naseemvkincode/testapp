import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'config.dart';

class UpdateInfo {
  final String latestVersion;
  final String installerFileId;
  final String releaseNotes;
  final int fileSize;

  UpdateInfo({
    required this.latestVersion,
    required this.installerFileId,
    required this.releaseNotes,
    required this.fileSize,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      latestVersion: json['latestVersion'] as String,
      installerFileId: json['installerFileId'] as String,
      releaseNotes: json['releaseNotes'] as String? ?? '',
      fileSize: json['fileSize'] as int? ?? 0,
    );
  }
}

class UpdateService {
  static bool isNewerVersion(String latest, String current) {
    final latestParts = latest.split('.').map(int.parse).toList();
    final currentParts = current.split('.').map(int.parse).toList();

    for (var i = 0; i < 3; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  static Future<UpdateInfo?> checkForUpdate(String currentVersion) async {
    try {
      final response = await http
          .get(Uri.parse(UpdateConfig.metadataUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final info = UpdateInfo.fromJson(json);

        if (isNewerVersion(info.latestVersion, currentVersion)) {
          return info;
        }
        return null;
      }
    } catch (_) {}
    return null;
  }

  static Future<String> _resolveGoogleDriveUrl(String fileId) async {
    final initialUrl =
        'https://drive.google.com/uc?export=download&id=$fileId';

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(initialUrl));
      final response = await client.send(request);

      final contentType = response.headers['content-type'] ?? '';

      if (contentType.contains('text/html')) {
        final bodyBytes = await response.stream.toBytes();
        final body = utf8.decode(bodyBytes, allowMalformed: true);

        String? confirm;
        final regex = RegExp(r'confirm=([0-9A-Za-z_-]+)');
        final match = regex.firstMatch(body);
        if (match != null) {
          confirm = match.group(1);
        }

        if (confirm != null) {
          return '$initialUrl&confirm=$confirm';
        }
        return '$initialUrl&confirm=t';
      }

      return initialUrl;
    } catch (_) {
      return initialUrl;
    } finally {
      client.close();
    }
  }

  static Future<String?> downloadInstaller(
    UpdateInfo info,
    void Function(double progress)? onProgress,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final updateDir = Directory(
        '${dir.path}${Platform.pathSeparator}${UpdateConfig.tempDownloadFolder}',
      );

      if (!updateDir.existsSync()) {
        updateDir.createSync(recursive: true);
      }

      final fileName = 'TestApp-Setup-${info.latestVersion}.exe';
      final file =
          File('${updateDir.path}${Platform.pathSeparator}$fileName');

      final resolvedUrl = await _resolveGoogleDriveUrl(info.installerFileId);

      final client = http.Client();
      final request = http.Request('GET', Uri.parse(resolvedUrl));
      final response = await client.send(request).timeout(
        const Duration(minutes: 10),
      );

      if (response.statusCode == 200) {
        final contentType = response.headers['content-type'] ?? '';
        if (contentType.contains('text/html')) {
          client.close();
          return null;
        }

        final contentLength = response.contentLength;
        var received = 0;

        final sink = file.openWrite();
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength != null && contentLength > 0 && onProgress != null) {
            onProgress(received / contentLength);
          } else if (info.fileSize > 0 && onProgress != null) {
            onProgress(received / info.fileSize);
          }
        }
        await sink.close();
        client.close();

        final downloadedSize = file.lengthSync();
        if (downloadedSize < 1000) {
          return null;
        }

        return file.path;
      }

      client.close();
    } catch (_) {}
    return null;
  }
}
