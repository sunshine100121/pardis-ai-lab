import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/tools/domain/tool_spec.dart';
import 'package:ondevice_llm/features/zim/zim_content_batches.dart';
import 'package:ondevice_llm/features/zim/zim_content_index.dart';
import 'package:ondevice_llm/features/zim/zim_index_citations.dart';
import 'package:ondevice_llm/features/zim/zim_index_step.dart';
import 'package:ondevice_llm/features/zim/zim_query_translation.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';
import 'package:ondevice_llm/inference/engine/llama_engine.dart';

import 'support/persian_zim_fixture.dart';

class FakeLocalQueryEngine extends LlamaEngine {
  final List<String> chunks;
  int calls = 0;
  bool stopped = false;
  InferenceSettings? received;
  FakeLocalQueryEngine(this.chunks);
  @override
  Stream<String> generate({
    required List<Map<String, Object>> messages,
    required String fallbackTemplate,
    required InferenceSettings settings,
    String assistantPrefix = '',
    List<ToolSpec> tools = const [],
    String toolChoice = 'auto',
  }) async* {
    calls++;
    received = settings;
    for (final chunk in chunks) {
      yield chunk;
    }
  }

  @override
  void cancel() {
    stopped = true;
  }
}

class HangingLocalQueryEngine extends FakeLocalQueryEngine {
  HangingLocalQueryEngine() : super(const []);
  @override
  Stream<String> generate({
    required List<Map<String, Object>> messages,
    required String fallbackTemplate,
    required InferenceSettings settings,
    String assistantPrefix = '',
    List<ToolSpec> tools = const [],
    String toolChoice = 'auto',
  }) => Stream<String>.fromFuture(Completer<String>().future);
}

void main() {
  const medical =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const fingerprint =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  test('local translated Persian query retrieves only the allowed English source', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db);
    final source = persianZim(
      englishGarden: true,
      archive: 'Gardening fixture',
    );
    final wiki = ZimWikipedia(
      'garden.zim',
      openSource: (_) async => source.fresh(),
    );
    final actualName = await wiki.name();
    final actualId = await wiki.archiveIdentity();
    final actualDate = await wiki.archiveMetadata('Date');
    final actualLanguage = await wiki.archiveMetadata('Language');
    await wiki.close();
    expect(actualName, 'Gardening fixture');
    expect(actualLanguage, 'eng');
    final garden = FolderLibrary.sourceId('garden.zim');
    final gardenFingerprint = ZimContentIndex.fingerprint(
      archiveId: actualId,
      size: source.size,
      modified: 1,
    );
    final job = ZimIndexStep(index);
    var cursor = 0, total = 1;
    while (cursor < total) {
      final result = await job.run(
        uri: 'garden.zim',
        size: source.size,
        modified: 1,
        allowed: () => true,
        sourceUnchanged: () async => true,
        hasStorageHeadroom: () async => true,
        limit: 2,
        openSource: (_) async => source.fresh(),
      );
      cursor = result.cursor;
      total = result.total;
    }
    index.commit(
      sourceId: medical,
      fingerprint: fingerprint,
      expectedCursor: 0,
      batch: const ZimContentBatch(
        [
          (
            entry: 0,
            title: 'Clinical',
            text: 'Walnut allergy is a medical condition.',
          ),
        ],
        1,
        1,
        0,
        false,
      ),
      allowed: () => true,
    );
    final engine = FakeLocalQueryEngine([
      '<think>private reasoning</think>walnut ',
      'tree watering',
    ]);
    final query = await ZimQueryTranslation.englishTerms(
      'آبیاری درخت گردو',
      engine: engine,
      settings: const InferenceSettings(),
      fallbackTemplate: '',
      cancelled: () => false,
    );
    expect(query, 'walnut tree watering');
    expect(engine.received?.thinkingModeEnabled, isFalse);
    expect(engine.received?.remoteEnabled, isFalse);
    final hits = index.search(query!, {garden: gardenFingerprint});
    expect(hits.single.sourceId, garden);
    expect(hits.single.title, 'Plant care');
    expect(hits.single.text, contains('walnut'));
    final citations = ZimIndexCitations(index).search(query!, {
      garden: (
        fingerprint: gardenFingerprint,
        archiveId: actualId,
        name: actualName,
        date: actualDate,
        language: actualLanguage,
      ),
    });
    expect(citations.single.source, 'Gardening fixture');
    expect(citations.single.title, 'Plant care — Gardening fixture');
    expect(
      citations.single.url,
      'zim://01000000000000000000000000000000/Plant_care?entry=0&source=$garden',
    );
    expect(citations.single.pageText, contains('walnut'));
  });

  test('citation preserves a match late in a long article', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db);
    const id =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final body = '${List.filled(42000, 'x').join()} walnut watering evidence';
    index.commit(
      sourceId: id,
      fingerprint: fingerprint,
      expectedCursor: 0,
      batch: ZimContentBatch(
        [(entry: 0, title: 'Long article', text: body)],
        1,
        1,
        0,
        false,
      ),
      allowed: () => true,
    );
    final result = ZimIndexCitations(index).search('walnut watering', {
      id: (
        fingerprint: fingerprint,
        archiveId: '01000000000000000000000000000000',
        name: 'Fixture',
        date: null,
        language: 'eng',
      ),
    });
    expect(result.single.pageText, contains('walnut watering evidence'));
  });

  test(
    'English bypasses generation and incomplete thinking is rejected',
    () async {
      final engine = FakeLocalQueryEngine(['<think>unfinished']);
      expect(
        await ZimQueryTranslation.englishTerms(
          'walnut watering',
          engine: engine,
          settings: const InferenceSettings(),
          fallbackTemplate: '',
          cancelled: () => false,
        ),
        'walnut watering',
      );
      expect(engine.calls, 0);
      expect(
        await ZimQueryTranslation.englishTerms(
          'آبیاری گردو',
          engine: engine,
          settings: const InferenceSettings(),
          fallbackTemplate: '',
          cancelled: () => false,
        ),
        isNull,
      );
    },
  );
  test('idle translation cancels the local engine', () async {
    final engine = HangingLocalQueryEngine();
    final result = await ZimQueryTranslation.englishTerms(
      'آبیاری گردو',
      engine: engine,
      settings: const InferenceSettings(),
      fallbackTemplate: '',
      cancelled: () => false,
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, isNull);
    expect(engine.stopped, isTrue);
  });
}
