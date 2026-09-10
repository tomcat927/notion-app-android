import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/update_service.dart';

class UpdateSection extends StatefulWidget {
  const UpdateSection({super.key});

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  bool _autoUpdate = true;
  bool _directUpdate = true;
  bool _settingsLoaded = false;
  bool _checking = false;
  UpdateInfo? _updateInfo;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final autoUpdate =
        prefs.getBool(UpdateService.autoUpdatePreferenceKey) ?? true;
    final directUpdate =
        prefs.getBool(UpdateService.directUpdatePreferenceKey) ?? true;
    if (!mounted) return;
    setState(() {
      _autoUpdate = autoUpdate;
      _directUpdate = directUpdate;
      _settingsLoaded = true;
    });
  }

  Future<void> _setAutoUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(UpdateService.autoUpdatePreferenceKey, value);
    if (!mounted) return;
    setState(() {
      _autoUpdate = value;
      _message = null;
    });
  }

  Future<void> _setDirectUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(UpdateService.directUpdatePreferenceKey, value);
    if (!mounted) return;
    setState(() {
      _directUpdate = value;
      _message = null;
    });
  }

  Future<void> _checkForUpdate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = null;
    });

    try {
      final updateInfo = await UpdateService.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _updateInfo = updateInfo;
        _message = updateInfo == null ? '当前已是最新版本' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '检查更新失败');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final updateInfo = _updateInfo;
    if (updateInfo == null) return;

    final progress = ValueNotifier<double>(0);
    var dialogOpen = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
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

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          if (_settingsLoaded) ...[
            SwitchListTile(
              title: const Text('自动检查更新'),
              value: _autoUpdate,
              onChanged: _setAutoUpdate,
            ),
            SwitchListTile(
              title: const Text('更新直连'),
              subtitle: const Text('开启后热更新绕过系统代理直接下载'),
              value: _directUpdate,
              onChanged: _setDirectUpdate,
            ),
          ],
          if (_updateInfo != null) ...[
            ListTile(
              leading: const Icon(Icons.system_update),
              title: Text('新版本 ${_updateInfo!.tagName}'),
              subtitle: Text(
                _updateInfo!.releaseNotes?.trim().isNotEmpty == true
                    ? _updateInfo!.releaseNotes!.trim()
                    : '更新包优先通过 GitHub 代理下载',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('下载并安装'),
                  onPressed: _downloadAndInstall,
                ),
              ),
            ),
          ] else
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              subtitle: Text(_message ?? '更新包优先通过 GitHub 代理下载'),
              trailing: _checking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _checkForUpdate,
            ),
        ],
      ),
    );
  }
}
