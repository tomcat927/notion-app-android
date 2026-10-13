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
                updateInfo.displayVersion,
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
  await runUpdateDownload(context, updateInfo);
}

/// 下载并安装更新。
///
/// 下载由系统 DownloadManager 承载，切后台/进程被冻结都不中断。前台进度弹窗
/// 提供「后台下载」按钮，返回键同样转入后台并给出提示，避免返回后无声无息。
Future<void> runUpdateDownload(
  BuildContext context,
  UpdateInfo updateInfo,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<double>(0);
  var dialogOpen = true;

  void dismissDialog() {
    if (!dialogOpen) return;
    dialogOpen = false;
    navigator.pop();
  }

  void moveToBackground() {
    if (!dialogOpen) return;
    dismissDialog();
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('已转入后台下载，可在通知栏查看进度'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) moveToBackground();
        },
        child: AlertDialog(
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
                  const SizedBox(height: 8),
                  Text(
                    '可切到后台下载，完成后通知栏提醒安装',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: moveToBackground,
              child: const Text('后台下载'),
            ),
          ],
        ),
      );
    },
  );

  try {
    final file = await UpdateService.downloadAndVerify(updateInfo, (value) {
      progress.value = value.clamp(0.0, 1.0);
    });
    dismissDialog();
    await UpdateService.showDownloadCompleteNotification();
    await UpdateService.installApk(file);
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('已启动系统安装器')),
    );
  } catch (_) {
    dismissDialog();
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('更新失败')),
    );
  } finally {
    progress.dispose();
  }
}
