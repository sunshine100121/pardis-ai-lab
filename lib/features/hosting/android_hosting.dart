import 'dart:io';
import 'package:flutter/services.dart';

abstract final class AndroidHosting {
  static const channel = MethodChannel('pala/hosting');
  static Future<void> start(Future<void> Function(String reason) stop) async {
    if (!Platform.isAndroid) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stop')
        await stop(call.arguments as String? ?? 'سرور متوقف شد');
    });
    await channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('stop');
  }

  static Future<void> work(bool active) async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('work', active);
  }
}
