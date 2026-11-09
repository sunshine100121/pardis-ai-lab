import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/zim/knowledge_sources.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';
import 'package:ondevice_llm/features/zim/zim_grounding.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'two original archives persist as references and detach without deleting',
    () async {
      final paths = [
        'test/fixtures/zim/mini.zim',
        'test/fixtures/zim/libzim-modern.zim',
      ];
      final before = [
        for (final path in paths)
          sha256.convert(await File(path).readAsBytes()).toString(),
      ];
      final sources = [
        for (final path in paths)
          await KnowledgeSources.inspect(path, 'fallback'),
      ];
      expect(sources[0].archiveId, isNot(sources[1].archiveId));
      await KnowledgeSources.save(sources);
      final restored = await KnowledgeSources.load();
      expect(restored.map((s) => s.uri), paths);
      final prefs = await SharedPreferences.getInstance();
      expect(
        utf8.encode(prefs.getString(KnowledgeSources.key)!).length,
        lessThan(4096),
      );
      await KnowledgeSources.save([restored[1].withEnabled(false)]);
      expect((await KnowledgeSources.load()).single.enabled, isFalse);
      final after = [
        for (final path in paths)
          sha256.convert(await File(path).readAsBytes()).toString(),
      ];
      expect(after, before);
      await KnowledgeSources.save([]);
      expect(await KnowledgeSources.configured(), isTrue);
      expect(await KnowledgeSources.load(), isEmpty);
    },
  );
  test(
    'same article in distinct archives retains distinct citations; disabled sources excluded',
    () async {
      final dir = await Directory.systemTemp.createTemp('pala-two-zim-');
      addTearDown(() => dir.delete(recursive: true));
      final a = File('test/fixtures/zim/mini.zim');
      final bytes = await a.readAsBytes();
      bytes[8] ^= 1; // Second fixture identity, same article title and content.
      final b = await File('${dir.path}/second.zim').writeAsBytes(bytes);
      final sources = [
        await KnowledgeSources.inspect(a.path, 'A'),
        await KnowledgeSources.inspect(b.path, 'B'),
      ];
      final results = await ZimLibrary(sources).lookupAll('Paris');
      expect(results.length, 2);
      expect(results.map((r) => r.url).toSet().length, 2);
      expect(
        results.every(
          (r) => r.source == 'Wikipedia test' && r.title.startsWith('Paris'),
        ),
        isTrue,
      );
      expect(
        (await ZimLibrary([
          sources.first.withEnabled(false),
          sources.last,
        ]).lookupAll('Paris')).length,
        1,
      );
      final messages = await ZimGrounding.augment([
        {'role': 'user', 'content': 'Paris'},
      ], ZimLibrary(sources));
      expect(messages.first['content'], contains(sources[0].archiveId));
      expect(messages.first['content'], contains(sources[1].archiveId));
      expect(messages.first['content'], contains('Wikipedia test'));
      final empty = await ZimGrounding.augment([
        {'role': 'user', 'content': 'qzxqzx'},
      ], ZimLibrary(sources));
      expect(empty.first['content'], contains('سندی'));
    },
  );
  test(
    'SAF channel reads two real ZIM fixtures in place with short reads and closes handles',
    () async {
      final data = {
        'content://test/a': await File(
          'test/fixtures/zim/mini.zim',
        ).readAsBytes(),
        'content://test/b': await File(
          'test/fixtures/zim/libzim-modern.zim',
        ).readAsBytes(),
      };
      final open = <int, String>{};
      var next = 0;
      var readBytes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidZimSource.channel, (call) async {
            if (call.method == 'open') {
              final uri = call.arguments as String;
              if (!data.containsKey(uri))
                throw PlatformException(code: 'not_seekable');
              open[++next] = uri;
              return {'handle': next, 'size': data[uri]!.length};
            }
            if (call.method == 'close') {
              open.remove(call.arguments);
              return null;
            }
            final m = call.arguments as Map;
            final bytes = data[open[m['handle']]]!;
            final at = m['offset'] as int;
            final count = (m['count'] as int).clamp(0, 97);
            readBytes += count;
            return bytes.sublist(at, (at + count).clamp(0, bytes.length));
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidZimSource.channel, null),
      );
      final sources = [
        for (final uri in data.keys)
          await KnowledgeSources.inspect(uri, 'fixture'),
      ];
      expect(sources.every((s) => s.size == data[s.uri]!.length), isTrue);
      expect(open, isEmpty);
      final results = await ZimLibrary(sources).lookupAll('Paris');
      expect(results, isNotEmpty);
      expect(open, isEmpty);
      expect(readBytes, greaterThan(0));
      await expectLater(
        KnowledgeSources.inspect('content://test/pipe', 'pipe'),
        throwsA(isA<PlatformException>()),
      );
      expect(open, isEmpty);
    },
  );
  test('Persian candidates include Arabic glyph and spacing variants', () {
    expect(ZimWikipedia.normalize('علي كاظمی'), 'علی کاظمی');
    expect(ZimWikipedia.candidates('علي كاظمی'), contains('علی کاظمی'));
  });
}
