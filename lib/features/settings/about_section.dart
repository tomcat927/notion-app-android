import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network_proxy.dart';

class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _packageInfo = packageInfo);
  }

  Future<void> _openRepository() async {
    final uri = Uri.parse('https://github.com/tomcat927/notion-app-android');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开仓库地址')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = _packageInfo == null
        ? '读取中...'
        : '${_packageInfo!.version} (${_packageInfo!.buildNumber})';

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('当前版本'),
            subtitle: Text(version),
          ),
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: const Text('系统代理'),
            subtitle: Text(NetworkProxy.description),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('GitHub 仓库'),
            subtitle: const Text('tomcat927/notion-app-android'),
            trailing: const Icon(Icons.open_in_new),
            onTap: _openRepository,
          ),
        ],
      ),
    );
  }
}
