import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.tagName,
    required this.versionCode,
    required this.downloadUrl,
    required this.fallbackDownloadUrl,
    required this.checksumUrl,
    required this.fallbackChecksumUrl,
    required this.releaseUrl,
    this.releaseNotes,
  });

  final String tagName;
  final int versionCode;
  final String downloadUrl;
  final String fallbackDownloadUrl;
  final String checksumUrl;
  final String fallbackChecksumUrl;
  final String releaseUrl;
  final String? releaseNotes;
}

class UpdateService {
  static const String autoUpdatePreferenceKey = 'auto_check_update';
  static const String _owner = 'tomcat927';
  static const String _repository = 'notion-app-android';
  static const String _proxyPrefix = 'https://gh-proxy.com/';
  static const String _manifestUrl =
      '$_proxyPrefixhttps://github.com/$_owner/$_repository/releases/latest/download/latest.json';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repository/releases/latest';
  static const MethodChannel _installChannel = MethodChannel(
    'com.notion.app/updater',
  );

  static Future<UpdateInfo?> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    final info = await _checkFromManifest() ?? await _checkFromGitHubApi();
    if (info == null) return null;

    await AppLogger.log(
      'Update',
      'current=$currentVersionCode latest=${info.versionCode}',
    );
    return info.versionCode > currentVersionCode ? info : null;
  }

  static Future<UpdateInfo?> _checkFromManifest() async {
    try {
      final response = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      final versionCode = int.tryParse(data['version_code']?.toString() ?? '');
      final apkUrl = data['apk']?.toString() ?? '';
      final fallbackApkUrl = data['github_apk']?.toString() ?? '';
      final checksumUrl = data['apk_sha256']?.toString() ?? '';
      final fallbackChecksumUrl = data['github_apk_sha256']?.toString() ?? '';
      if (versionCode == null ||
          apkUrl.isEmpty ||
          fallbackApkUrl.isEmpty ||
          checksumUrl.isEmpty ||
          fallbackChecksumUrl.isEmpty) {
        return null;
      }

      return UpdateInfo(
        tagName: data['tag_name']?.toString() ?? '',
        versionCode: versionCode,
        downloadUrl: apkUrl,
        fallbackDownloadUrl: fallbackApkUrl,
        checksumUrl: checksumUrl,
        fallbackChecksumUrl: fallbackChecksumUrl,
        releaseUrl: data['release_url']?.toString() ?? '',
        releaseNotes: data['release_notes']?.toString(),
      );
    } catch (error) {
      await AppLogger.log('Update', 'manifest check failed: $error');
      return null;
    }
  }

  static Future<UpdateInfo?> _checkFromGitHubApi() async {
    final response = await http
        .get(
          Uri.parse(_apiUrl),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'notion-app-android',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('GitHub API HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final tagName = data['tag_name']?.toString() ?? '';
    final versionCode = int.tryParse(
      RegExp(r'-(\d+)$').firstMatch(tagName)?.group(1) ?? '',
    );
    final assets = List<Map<String, dynamic>>.from(data['assets'] ?? []);
    final apk = assets.firstWhere(
      (asset) => (asset['name']?.toString() ?? '').endsWith('.apk'),
    );
    final checksum = assets.firstWhere(
      (asset) => (asset['name']?.toString() ?? '').endsWith('.apk.sha256'),
    );
    final directUrl = apk['browser_download_url']?.toString() ?? '';
    final directChecksumUrl =
        checksum['browser_download_url']?.toString() ?? '';
    if (versionCode == null || directUrl.isEmpty || directChecksumUrl.isEmpty) {
      return null;
    }

    return UpdateInfo(
      tagName: tagName,
      versionCode: versionCode,
      downloadUrl: '$_proxyPrefix$directUrl',
      fallbackDownloadUrl: directUrl,
      checksumUrl: '$_proxyPrefix$directChecksumUrl',
      fallbackChecksumUrl: directChecksumUrl,
      releaseUrl: data['html_url']?.toString() ?? '',
      releaseNotes: data['body']?.toString(),
    );
  }

  static Future<File> downloadAndVerify(
    UpdateInfo info,
    void Function(double progress) onProgress,
  ) async {
    final baseDir = await getTemporaryDirectory();
    final updateDir = Directory(path.join(baseDir.path, 'apk_updates'));
    await updateDir.create(recursive: true);
    final file = File(path.join(updateDir.path, 'notion-app-update.apk'));
    if (await file.exists()) await file.delete();

    try {
      await _download(
        [info.downloadUrl, info.fallbackDownloadUrl],
        file,
        onProgress,
      );
      final expectedChecksum = await _readChecksum([
        info.checksumUrl,
        info.fallbackChecksumUrl,
      ]);
      if (expectedChecksum == null) {
        throw Exception('无法获取 SHA-256 校验值');
      }

      final actualChecksum = (await _sha256(file)).toLowerCase();
      if (actualChecksum != expectedChecksum.toLowerCase()) {
        throw Exception('SHA-256 校验失败');
      }
      return file;
    } catch (error) {
      if (await file.exists()) await file.delete();
      await AppLogger.log('Update', 'download/verify failed: $error');
      rethrow;
    }
  }

  static Future<void> installApk(File file) async {
    await _installChannel.invokeMethod<bool>('installUpdate', {
      'path': file.path,
    });
  }

  static Future<void> _download(
    List<String> urls,
    File file,
    void Function(double progress) onProgress,
  ) async {
    Object? lastError;
    for (final url in urls) {
      try {
        final client = http.Client();
        final request = http.Request('GET', Uri.parse(url));
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final totalBytes = response.contentLength ?? 0;
        var receivedBytes = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in response.stream) {
            receivedBytes += chunk.length;
            sink.add(chunk);
            onProgress(totalBytes > 0 ? receivedBytes / totalBytes : 0);
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          await sink.close();
          rethrow;
        } finally {
          client.close();
        }

        if (totalBytes > 0 && await file.length() != totalBytes) {
          throw Exception('下载不完整');
        }
        return;
      } catch (error) {
        lastError = error;
        if (await file.exists()) await file.delete();
        await AppLogger.log('Update', 'download failed: $error');
      }
    }
    throw Exception(lastError);
  }

  static Future<String?> _readChecksum(List<String> urls) async {
    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) continue;

        final value = utf8
            .decode(response.bodyBytes)
            .trim()
            .split(RegExp(r'\s+'))
            .first;
        if (value.length == 64) return value;
      } catch (_) {
        // Try the next mirror; a final missing checksum is handled by caller.
      }
    }
    return null;
  }

  static Future<String> _sha256(File file) async {
    return sha256.convert(await file.readAsBytes()).toString();
  }
}
