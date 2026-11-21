import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/hosting/lan_probe_runner.dart';

void main() {
  test('M15 LAN probes stay strictly within private networks', () {
    for (final url in [
      'http://192.168.1.50:9000/v1',
      'http://10.7.0.2:8080/v1',
      'https://172.16.0.11:9000',
      'http://tablet.local:9000',
    ]) {
      expect(LanProbeRunner.isLocal(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'https://example.com/v1',
      'http://8.8.8.8/v1',
      'https://user:password@192.168.1.3',
      'ftp://192.168.1.3',
      'http://127.0.0.1:9000',
    ]) {
      expect(LanProbeRunner.isLocal(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('same formula for median, worst and partial failure', () {
    final run = LanProbeRunner.summarize([64, 52, 99, 41], attempts: 5);
    expect(run.successes, 4);
    expect(run.failures, 1);
    expect(run.medianMs, 58);
    expect(run.worstMs, 99);
    expect(run.persian, contains('4 از 5'));
  });

  test('a failed probe never becomes a fabricated latency value', () async {
    var calls = 0;
    final runner = LanProbeRunner();
    final summary = await runner.run(
      () async {
        calls++;
        throw StateError('fake private failure token must not be printed');
      },
      samples: 3,
      spacing: Duration.zero,
    );
    expect(calls, 3);
    expect(summary.attempts, 3);
    expect(summary.successes, 0);
    expect(summary.medianMs, isNull);
    expect(summary.worstMs, isNull);
    expect(summary.persian, contains('نامعلوم'));
    expect(summary.persian, isNot(contains('private failure token')));
  });

  test(
    'stop prevents any further request and does not export a token',
    () async {
      final firstStarted = Completer<void>();
      final gate = Completer<void>();
      var calls = 0;
      final runner = LanProbeRunner();
      final pending = runner.run(
        () async {
          calls++;
          if (!firstStarted.isCompleted) firstStarted.complete();
          await gate.future;
        },
        samples: 5,
        spacing: Duration.zero,
      );
      await firstStarted.future;
      runner.cancel();
      gate.complete();
      final summary = await pending;
      expect(summary.stopped, isTrue);
      expect(summary.attempts, 1);
      expect(summary.successes, 0);
      expect(calls, 1);
    },
  );
}
