import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/zim/zim_index_storage.dart';

void main() {
  test('storage guard fails closed and rechecks available space', () async {
    final dir = await Directory.systemTemp.createTemp('pala-index-space-');
    addTearDown(() => dir.delete(recursive: true));
    int? available = 399;
    final guard = ZimIndexStorage(directory: dir, maxDatabaseBytes: 100,
      reserveBytes: 200, availableBytes: () async => available);
    expect(await guard.hasHeadroom(), isFalse);
    available = 400;
    expect(await guard.hasHeadroom(), isTrue);
    available = null;
    expect(await guard.hasHeadroom(), isFalse);
    expect(guard.indexPath, startsWith(dir.path));
  });
}
