import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/network/web_search/search_models.dart';
import 'zim_archive.dart';
import 'zim_source.dart';
import 'zim_wikipedia.dart';

class KnowledgeSource {
  final String uri, name, language, date, subject, archiveId;
  final int size;
  final bool enabled;
  const KnowledgeSource({
    required this.uri,
    required this.name,
    required this.language,
    required this.date,
    required this.subject,
    required this.archiveId,
    required this.size,
    this.enabled = true,
  });
  Map<String, Object> toJson() => {
    'uri': uri,
    'name': name,
    'language': language,
    'date': date,
    'subject': subject,
    'archiveId': archiveId,
    'size': size,
    'enabled': enabled,
  };
  factory KnowledgeSource.fromJson(Map<String, dynamic> m) => KnowledgeSource(
    uri: m['uri'] as String,
    name: m['name'] as String,
    language: m['language'] as String,
    date: m['date'] as String,
    subject: m['subject'] as String,
    archiveId: m['archiveId'] as String,
    size: m['size'] as int,
    enabled: m['enabled'] as bool,
  );
  KnowledgeSource withEnabled(bool value) =>
      KnowledgeSource.fromJson({...toJson(), 'enabled': value});
}

/// Stores metadata and references only. Source bytes never enter app storage.
abstract final class KnowledgeSources {
  static const key = 'pala.knowledge.sources.v1';
  static Future<bool> configured() async => (await SharedPreferences.getInstance()).containsKey(key);
  static Future<List<KnowledgeSource>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    return [
      for (final m in jsonDecode(raw) as List)
        KnowledgeSource.fromJson(m as Map<String, dynamic>),
    ];
  }

  static Future<void> save(List<KnowledgeSource> sources) async {
    final ok = await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode([for (final s in sources) s.toJson()]),
    );
    if (!ok) throw StateError('ذخیره فهرست منابع انجام نشد');
  }

  static Future<KnowledgeSource> inspect(String uri, String fallback) async {
    final zim = await ZimArchive.open(uri);
    try {
      final source = await ZimSource.open(uri);
      late int size;
      try {
        size = await source.length();
      } finally {
        await source.close();
      }
      return KnowledgeSource(
        uri: uri,
        name: await zim.metadata('Title') ?? fallback,
        language: await zim.metadata('Language') ?? '—',
        date: await zim.metadata('Date') ?? '—',
        subject:
            await zim.metadata('Tags') ??
            await zim.metadata('Description') ??
            '—',
        archiveId: zim.identity,
        size: size,
      );
    } finally {
      await zim.close();
    }
  }
}

/// Compatibility facade over the existing title reader. Each source is opened
/// only for its lookup and closed afterwards; caches cannot multiply with the
/// number of mounted encyclopedias. One failed source never hides the others.
class ZimLibrary extends ZimWikipedia {
  final List<KnowledgeSource> sources;
  ZimLibrary(this.sources) : super('');
  Future<List<SearchResult>> lookupAll(String query) async {
    final results = <SearchResult>[];
    for (final source in sources.where((s) => s.enabled)) {
      final wiki = ZimWikipedia(source.uri);
      try {
        final found = await wiki.lookup(query);
        if (found != null) results.add(found);
      } catch (_) {
        /* The source list exposes availability separately. */
      } finally {
        await wiki.close();
      }
      if (results.length == 3) break;
    }
    return results;
  }

  @override
  Future<SearchResult?> lookup(String query) async {
    final all = await lookupAll(query);
    return all.isEmpty ? null : all.first;
  }

  Future<SearchResult?> articleFrom(
    String id,
    String? date,
    String title,
  ) async {
    for (final s in sources.where((s) => s.enabled && s.archiveId == id)) {
      final wiki = ZimWikipedia(s.uri);
      try {
        if (await wiki.archiveIdentity() == id &&
            await wiki.archiveMetadata('Date') == date)
          return await wiki.article(title);
      } catch (_) {
      } finally {
        await wiki.close();
      }
    }
    return null;
  }

  @override
  Future<void> close() async {}
}
