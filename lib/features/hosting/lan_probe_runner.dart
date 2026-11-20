import 'dart:async';
import 'dart:io';

/// M15: an on-demand LAN probe using the EXISTING authenticated
/// model connection. It stores no prompts, tokens, responses or addresses.
/// A successful ping is not proof of screen-off inference.
class LanProbeSummary {
  final int attempts, successes;
  final double? medianMs;
  final int? worstMs;
  final bool stopped;
  const LanProbeSummary({
    required this.attempts,
    required this.successes,
    required this.medianMs,
    required this.worstMs,
    this.stopped = false,
  });
  int get failures => attempts - successes;
  String get persian => 'ارتباط محلی: ' + successes.toString() +
      ' از ' + attempts.toString() + ' پاسخ موفق؛ ' +
      'میانه تأخیر: ' + (medianMs?.round().toString() ?? 'نامعلوم') + ' ms؛ ' +
      'بیشینه تأخیر: ' + (worstMs?.toString() ?? 'نامعلوم') + ' ms. ' +
      (stopped ? 'آزمون متوقف شد. ' : '') +
      'این فقط آزمون اتصال است؛ کارکرد Qwen با صفحه خاموش نیاز به آزمایش واقعی دارد.';
}

class LanProbeRunner {
  bool _stopped = false;
  void cancel() => _stopped = true;

  /// Restrict to local or paired .local hosts, not internet APIs.
  static bool isLocal(Uri? endpoint) {
    if (endpoint == null ||
        !{'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.userInfo.isNotEmpty) return false;
    final host = endpoint.host.toLowerCase();
    if (host.endsWith('.local') && host.length > 6) return true;
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  static LanProbeSummary summarize(
    List<int> successfulMs, {
    required int attempts,
    bool stopped = false,
  }) {
    final sorted = successfulMs.toList()..sort();
    double? median;
    if (sorted.isNotEmpty) {
      final n = sorted.length;
      median = n.isOdd
          ? sorted[n ~/ 2].toDouble()
          : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
    }
    return LanProbeSummary(
      attempts: attempts,
      successes: sorted.length,
      medianMs: median,
      worstMs: sorted.isEmpty ? null : sorted.last,
      stopped: stopped,
    );
  }

  /// The callback uses the existing authenticated /models probe.
  /// The loop is bounded and can be stopped between individual requests.
  Future<LanProbeSummary> run(
    Future<void> Function() existingProbe, {
    int samples = 5,
    Duration spacing = const Duration(milliseconds: 700),
  }) async {
    if (samples < 1 || samples > 10) {
      throw ArgumentError.value(samples, 'samples', 'Use 1..10 checks');
    }
    _stopped = false;
    final durations = <int>[];
    var attempts = 0;
    for (var i = 0; i < samples && !_stopped; i++) {
      final timer = Stopwatch()..start();
      attempts++;
      try {
        await existingProbe();
        timer.stop();
        if (!_stopped) durations.add(timer.elapsedMilliseconds);
      } catch (_) {
        timer.stop();
        // Denied/unreachable is a failure, without printing a secret URL.
      }
      if (i != samples - 1 && !_stopped && spacing > Duration.zero) {
        await Future<void>.delayed(spacing);
      }
    }
    return summarize(durations, attempts: attempts, stopped: _stopped);
  }
}
