import 'package:flutter/material.dart';

import '../../core/update_service.dart';

Future<void> showUpdatePrompt(
  BuildContext context,
  UpdateInfo updateInfo,
) async {
  final shouldInstall = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final releaseNotes = updateInfo.releaseNotes?.trim();

      return AlertDialog(
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                updateInfo.tagName,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                releaseNotes?.isNotEmpty == true
                    ? releaseNotes!
                    : '更新包优先通过 GitHub 代理下载',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('下载并安装'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      );
    },
  );

  if (shouldInstall != true || !context.mounted) return;
  await _downloadAndInstallUpdate(context, updateInfo);
}

Future<void> _downloadAndInstallUpdate(
  BuildContext context,
  UpdateInfo updateInfo,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<double>(0);
  var dialogOpen = true;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) {
      return AlertDialog(
        title: const Text('正在更新'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 12),
                Text('${(value * 100).toStringAsFixed(0)}%'),
              ],
            );
          },
        ),
      );
    },
  );

  try {
    final file = await UpdateService.downloadAndVerify(updateInfo, (value) {
      progress.value = value.clamp(0.0, 1.0);
    });
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
    await UpdateService.installApk(file);
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('已启动系统安装器')),
    );
  } catch (_) {
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('更新失败')),
    );
  } finally {
    progress.dispose();
  }
}
