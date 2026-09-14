import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class CacheCleanupReport {
  const CacheCleanupReport({
    required this.deletedBytes,
    required this.deletedFiles,
    required this.webViewCacheCleared,
  });

  final int deletedBytes;
  final int deletedFiles;
  final bool webViewCacheCleared;

  String get readableDeletedSize => CacheCleanupService.formatBytes(deletedBytes);
}

class CacheCleanupService {
  static const String _pendingUpdateCleanupKey = 'pending_update_cache_cleanup';
  static const MethodChannel _channel = MethodChannel(
    'com.notion.app/cache_cleanup',
  );

  static Future<void> markUpdatePackageForCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingUpdateCleanupKey, true);
  }

  static Future<CacheCleanupReport> cleanupStartupCaches() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingUpdateCleanup =
        prefs.getBool(_pendingUpdateCleanupKey) ?? false;

    var stats = const _DeleteStats();
    stats += await _cleanupUpdatePackages(deleteAll: pendingUpdateCleanup);
    stats += await _cleanupWebViewUploadTemps(
      olderThan: const Duration(days: 1),
    );

    if (pendingUpdateCleanup) {
      await prefs.remove(_pendingUpdateCleanupKey);
    }

    if (stats.bytes > 0 || stats.files > 0) {
      unawaited(
        AppLogger.log(
          'Cache',
          '启动清理完成: files=${stats.files} size=${formatBytes(stats.bytes)}',
        ),
      );
    }

    return CacheCleanupReport(
      deletedBytes: stats.bytes,
      deletedFiles: stats.files,
      webViewCacheCleared: false,
    );
  }

  static Future<CacheCleanupReport> cleanupSafeCaches() async {
    var stats = const _DeleteStats();
    stats += await _cleanupUpdatePackages(deleteAll: true);
    stats += await _cleanupWebViewUploadTemps();
    final webViewCacheCleared = await _clearWebViewCache();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingUpdateCleanupKey);

    unawaited(
      AppLogger.log(
        'Cache',
        '手动清理完成: files=${stats.files} size=${formatBytes(stats.bytes)} '
        'webViewCacheCleared=$webViewCacheCleared',
      ),
    );

    return CacheCleanupReport(
      deletedBytes: stats.bytes,
      deletedFiles: stats.files,
      webViewCacheCleared: webViewCacheCleared,
    );
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(2)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  static Future<_DeleteStats> _cleanupUpdatePackages({
    required bool deleteAll,
  }) async {
    var stats = const _DeleteStats();
    final tempDir = await getTemporaryDirectory();
    stats += await _deleteDirectory(
      Directory(path.join(tempDir.path, 'apk_updates')),
      root: tempDir,
      deleteAll: deleteAll,
      olderThan: const Duration(days: 1),
    );

    final externalCacheDirs = await getExternalCacheDirectories();
    for (final dir in externalCacheDirs ?? const <Directory>[]) {
      stats += await _deleteDirectory(
        Directory(path.join(dir.path, 'apk_updates')),
        root: dir,
        deleteAll: deleteAll,
        olderThan: const Duration(days: 1),
      );
    }
    return stats;
  }

  static Future<_DeleteStats> _cleanupWebViewUploadTemps({
    Duration? olderThan,
  }) async {
    var stats = const _DeleteStats();
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) return stats;

    await for (final entity in tempDir.list(followLinks: false)) {
      final name = path.basename(entity.path);
      if (!name.startsWith('webview_upload_')) continue;
      stats += await _deleteEntityIfSafe(
        entity,
        root: tempDir,
        olderThan: olderThan,
      );
    }
    return stats;
  }

  static Future<_DeleteStats> _deleteDirectory(
    Directory directory, {
    required Directory root,
    required bool deleteAll,
    required Duration olderThan,
  }) async {
    if (!await directory.exists()) return const _DeleteStats();
    if (deleteAll) {
      return _deleteEntityIfSafe(directory, root: root);
    }

    var stats = const _DeleteStats();
    await for (final entity in directory.list(followLinks: false)) {
      stats += await _deleteEntityIfSafe(
        entity,
        root: root,
        olderThan: olderThan,
      );
    }
    return stats;
  }

  static Future<_DeleteStats> _deleteEntityIfSafe(
    FileSystemEntity entity, {
    required Directory root,
    Duration? olderThan,
  }) async {
    try {
      final rootPath = path.normalize(root.absolute.path);
      final entityPath = path.normalize(entity.absolute.path);
      if (entityPath == rootPath || !path.isWithin(rootPath, entityPath)) {
        return const _DeleteStats();
      }

      if (olderThan != null) {
        final stat = await entity.stat();
        final age = DateTime.now().difference(stat.modified);
        if (age < olderThan) return const _DeleteStats();
      }

      final size = await _entitySize(entity);
      await entity.delete(recursive: true);
      return _DeleteStats(bytes: size, files: 1);
    } catch (error) {
      unawaited(
        AppLogger.log('Cache', '清理缓存文件失败: ${entity.path} error=$error'),
      );
      return const _DeleteStats();
    }
  }

  static Future<int> _entitySize(FileSystemEntity entity) async {
    if (entity is File) {
      return entity.length();
    }
    if (entity is! Directory || !await entity.exists()) return 0;

    var size = 0;
    await for (final child in entity.list(recursive: true, followLinks: false)) {
      if (child is File) {
        try {
          size += await child.length();
        } catch (_) {
          // Best-effort size accounting.
        }
      }
    }
    return size;
  }

  static Future<bool> _clearWebViewCache() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('clearWebViewCache') == true;
    } catch (error) {
      unawaited(AppLogger.log('Cache', '清理 WebView 缓存失败: $error'));
      return false;
    }
  }
}

class _DeleteStats {
  const _DeleteStats({this.bytes = 0, this.files = 0});

  final int bytes;
  final int files;

  _DeleteStats operator +(_DeleteStats other) {
    return _DeleteStats(
      bytes: bytes + other.bytes,
      files: files + other.files,
    );
  }
}
