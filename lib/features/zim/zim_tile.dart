import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/shared_providers.dart';
import 'knowledge_sources.dart';
import 'zim_source.dart';

class ZimTile extends ConsumerStatefulWidget {
  const ZimTile({super.key});
  @override
  ConsumerState<ZimTile> createState() => _ZimTileState();
}

class _ZimTileState extends ConsumerState<ZimTile> {
  List<KnowledgeSource> _sources = [];
  final _availability = <String, bool>{};
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      _sources = await KnowledgeSources.load();
      for (final s in _sources) {
        try {
          await KnowledgeSources.inspect(s.uri, s.name);
          _availability[s.uri] = true;
        } catch (_) {
          _availability[s.uri] = false;
        }
      }
    } catch (_) {
      _error = 'فهرست منابع خوانده نشد؛ دوباره تلاش کنید.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      _error =
          'منبع در دسترس نیست یا خواندن تصادفی پشتیبانی نمی‌شود. هیچ کپی ساخته نشد؛ فایل محلی را دوباره انتخاب کنید.';
    }
    // Also publish partial successful additions if another file was rejected.
    container.invalidate(zimWikipediaProvider);
    if (mounted) await _reload();
  }

  Future<void> _add() => _run(() async {
    if (!Platform.isAndroid) throw UnsupportedError('Android SAF required');
    final chosen =
        await AndroidZimSource.channel.invokeListMethod<dynamic>('pick') ?? [];
    for (final item in chosen) {
      final m = Map<String, dynamic>.from(item as Map);
      final uri = m['uri'] as String;
      if (_sources.any((s) => s.uri == uri)) continue;
      try {
        final source = await KnowledgeSources.inspect(uri, m['name'] as String);
        await KnowledgeSources.save([..._sources, source]);
        _sources = [..._sources, source];
      } catch (_) {
        await AndroidZimSource.channel.invokeMethod<void>('forget', uri);
        rethrow;
      }
    }
  });
  Future<void> _toggle(KnowledgeSource source, bool enabled) => _run(() async {
    await KnowledgeSources.save([
      for (final s in _sources)
        s.uri == source.uri ? s.withEnabled(enabled) : s,
    ]);
  });
  Future<void> _detach(KnowledgeSource source) => _run(() async {
    await KnowledgeSources.save(
      _sources.where((s) => s.uri != source.uri).toList(),
    );
    // References only: no deleteDocument and no File.delete.
    if (source.uri.startsWith('content:')) {
      try {
        await AndroidZimSource.channel.invokeMethod<void>('forget', source.uri);
      } catch (_) {}
    }
  });
  @override
  Widget build(BuildContext context) => Column(
    key: const Key('zim-wikipedia'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        title: const Text('منابع دانش'),
        subtitle: const Text('خواندن مستقیم؛ جداسازی فقط از فهرست برنامه'),
        trailing: TextButton(
          key: const Key('zim-action'),
          onPressed: _busy ? null : _add,
          child: const Text('افزودن دانشنامه'),
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
      for (final s in _sources)
        ListTile(
          title: Text(s.name),
          subtitle: Text(
            '${s.language} · ${s.date} · ${(s.size / 1048576).toStringAsFixed(1)} MB\n${s.subject}\n${_availability[s.uri] == true ? 'در دسترس' : 'در دسترس نیست؛ فایل را دوباره انتخاب کنید'}',
          ),
          leading: Switch(
            value: s.enabled,
            onChanged: _busy ? null : (v) => _toggle(s, v),
          ),
          trailing: TextButton(
            onPressed: _busy ? null : () => _detach(s),
            child: const Text('جداسازی'),
          ),
        ),
    ],
  );
}
