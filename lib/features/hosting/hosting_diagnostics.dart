import 'package:shared_preferences/shared_preferences.dart';

/// Bounded, content-free lifecycle timeline for field diagnosis.
abstract final class HostingDiagnostics {
  static const _key = 'pala_host_diag_v1';
  static final Stopwatch _clock = Stopwatch()..start();

  static Future<void> record(String event) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_key) ?? <String>[];
    rows.add('${_clock.elapsedMilliseconds}ms $event');
    if (rows.length > 300) rows.removeRange(0, rows.length - 300);
    await prefs.setStringList(_key, rows);
  }

  static Future<String> read() async {
    final rows = (await SharedPreferences.getInstance()).getStringList(_key) ?? const <String>[];
    return rows.join('\n');
  }
}
