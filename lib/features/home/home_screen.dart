import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/notion_auth.dart';
import '../auth/login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _currentTitle = '主页';
  String _currentContent = '# 欢迎使用 Notion App\n\n请选择左侧菜单或底部导航栏开始使用。';
  int _currentNavIndex = 0;

  Future<void> _logout() async {
    await NotionAuth.removeToken();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentTitle),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() {})),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') _logout();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _currentNavIndex,
            onDestinationSelected: (index) {
              setState(() => _currentNavIndex = index);
              switch (index) {
                case 0:
                  _currentTitle = '主页';
                  _currentContent = '# 主页\n\n最近页面和空间概览';
                case 1:
                  _currentTitle = '所有页面';
                  _currentContent = '# 所有页面\n\n你的 Notion 页面列表';
                case 2:
                  _currentTitle = '收藏';
                  _currentContent = '# 收藏\n\n你收藏的页面';
              }
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('主页'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.article_outlined),
                selectedIcon: Icon(Icons.article),
                label: Text('页面'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.favorite_outline),
                selectedIcon: Icon(Icons.favorite),
                label: Text('收藏'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Markdown(
              data: _currentContent,
              padding: const EdgeInsets.all(24),
              selectable: true,
            ),
          ),
        ],
      ),
    );
  }
}
