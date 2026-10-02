import 'dart:async';

import 'app_logger.dart';

/// 探测 UI isolate 事件循环是否被长任务阻塞。
///
/// Timer 在 isolate 卡住期间不会触发；恢复后按实际迟到时长补发一次记录，
/// 用于回答"卡了多久、卡在哪个时间段"。正常情况下完全不产生日志。
class UiWatchdog {
  static const Duration _interval = Duration(seconds: 2);
  static const Duration _reportThreshold = Duration(seconds: 2);

  Timer? _timer;
  DateTime _expectedAt = DateTime.now();

  void start() {
    _expectedAt = DateTime.now().add(_interval);
    _timer ??= Timer.periodic(_interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final now = DateTime.now();
    final late = now.difference(_expectedAt);
    if (late > _reportThreshold) {
      unawaited(
        AppLogger.log('Watchdog', 'UI 事件循环卡顿: ${late.inMilliseconds}ms'),
      );
    }
    _expectedAt = now.add(_interval);
  }
}
