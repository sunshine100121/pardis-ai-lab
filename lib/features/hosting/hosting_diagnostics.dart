import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bounded, content-free lifecycle timeline for field diagnosis.
abstract final class HostingDiagnostics {
  static const _key = 'pala_host_diag_v1';
  static const _channel = MethodChannel('pala/hosting');
  static final Stopwatch _clock = Stopwatch()..start();
  static final String _runId =
      '${pid.toRadixString(36)}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  static Future<void> record(String event) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('diagnosticEvent', event);
        return;
      } catch (_) {
        // Keep a local trace if the retained Android engine channel is absent.
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final rows = prefs.getStringList(_key) ?? <String>[];
      rows.add('dart-$_runId ${_clock.elapsedMilliseconds}ms $event');
      if (rows.length > 300) rows.removeRange(0, rows.length - 300);
      await prefs.setStringList(_key, rows);
    } catch (_) {
      // Standalone server tests have no platform binding; diagnostics must
      // never alter request behavior when persistent storage is unavailable.
    }
  }

  static Future<String> read() async {
    final rows = (await SharedPreferences.getInstance()).getStringList(_key) ?? const <String>[];
    return rows.join('\n');
  }
}
