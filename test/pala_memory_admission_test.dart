import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/core/utils/memory_admission.dart';

void main() {
  test('heavy allocations wait for one another', () async {
    final gate = MemoryAdmission();
    final first = Completer<void>();
    final entered = <String>[];
    final a = gate.run(() async {
      entered.add('first');
      await first.future;
      entered.add('first finished');
    });
    final b = gate.run(() async {
      entered.add('second');
    });
    await Future<void>.delayed(Duration.zero);
    expect(entered, ['first']);
    first.complete();
    await Future.wait([a, b]);
    expect(entered, ['first', 'first finished', 'second']);
  });

  test('failed load cannot block a later valid load', () async {
    final gate = MemoryAdmission();
    final failed = gate.run<int>(() async {
      throw StateError('load failed');
    });
    final recovered = gate.run(() async => 42);
    await expectLater(failed, throwsStateError);
    expect(await recovered, 42);
    // Queue must work after the previous error and recovery.
    expect(await gate.run(() async => 7), 7);
  });

  test(
    'immediate allocation returns its result and releases the queue',
    () async {
      final gate = MemoryAdmission();
      expect(await gate.run(() async => 'done'), 'done');
      expect(await gate.run(() async => 'again'), 'again');
    },
  );
}
