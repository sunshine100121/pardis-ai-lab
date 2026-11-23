import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/providers/shared_providers.dart';
import '../chat/domain/conversation_workspace.dart';
import '../chat/presentation/providers/chat_provider.dart';
import '../knowledge/folder_library.dart';
import '../models/presentation/providers/model_manager_provider.dart';
import '../settings/presentation/providers/effective_settings_provider.dart';
import '../settings/presentation/providers/settings_provider.dart';
import '../voice/voice_service.dart';
import 'zim_local_video.dart';
import 'zim_subtitles.dart';
import 'zim_video_runtime.dart';
import 'zim_video_selection.dart';

/// A local video list on the cited article, not on an arbitrary webpage.
class ZimInlineVideos extends ConsumerStatefulWidget {
  const ZimInlineVideos({
    super.key, required this.url, required this.archiveId, this.archiveDate,
  });
  final String url, archiveId;
  final String? archiveDate;

  @override
  ConsumerState<ZimInlineVideos> createState() => _ZimInlineVideosState();
}

class _ZimInlineVideosState extends ConsumerState<ZimInlineVideos> {
  Future<List<ZimVideoCandidate>?>? _items;
  String? _chatId, _projectId, _error;
  bool _opening = false;

  bool _allowed(String uri) {
    if (!mounted) return false;
    final workspace = ref.read(conversationWorkspaceProvider);
    final chat = ref.read(chatProvider).chatId;
    if (!workspace.loaded || !workspace.readable || chat != _chatId) {
      return false;
    }
    final project = chat == null ? ref.read(newChatProjectProvider)
        : workspace.memberships[chat];
    if (project != _projectId) return false;
    if (project == null) return true;
    return workspace.projects.any((p) =>
        p.id == project &&
        p.sourceIds.contains(FolderLibrary.sourceId(uri)));
  }

  Future<List<ZimVideoCandidate>?> _read() async {
    await ref.read(conversationWorkspaceProvider.notifier).ready;
    if (!mounted) return null;
    final workspace = ref.read(conversationWorkspaceProvider);
    if (!workspace.loaded || !workspace.readable) return null;
    _chatId = ref.read(chatProvider).chatId;
    _projectId = _chatId == null ? ref.read(newChatProjectProvider)
        : workspace.memberships[_chatId];
    return ref.read(folderLibraryProvider).articleVideos(
      widget.url, widget.archiveId, widget.archiveDate, allowSource: _allowed,
    );
  }

  @override
  void initState() {
    super.initState();
    _items = _read();
  }

  @override
  void didUpdateWidget(covariant ZimInlineVideos old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.archiveId != widget.archiveId ||
        old.archiveDate != widget.archiveDate) _items = _read();
  }

  Future<void> _open(ZimVideoCandidate candidate) async {
    if (_opening) return;
    setState(() { _opening = true; _error = null; });
    ZimPlayableVideo? video;
    bool handedOff = false;
    try {
      video = await ref.read(folderLibraryProvider).openArticleVideo(
        widget.url, widget.archiveId, widget.archiveDate,
        candidate.reference, allowSource: _allowed,
        cancelled: () => !mounted,
      );
      if (video == null) throw StateError(
        'فیلم قابل دسترسی نیست یا حجم/قالب آن در نسخه فعلی پشتیبانی نمی‌شود.');
      if (!mounted) return;
      handedOff = true;
      final identity = '${widget.archiveId}|${widget.archiveDate}|'
          '${widget.url}|${candidate.reference}';
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => _ZimMovieScreen(
          video: video!, title: candidate.caption,
          identity: '$identity|${video.revision}',
        ),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (!handedOff && video != null && await video.file.exists()) {
        await video.file.delete();
      }
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ZimVideoCandidate>?>(
    future: _items,
    builder: (context, snapshot) {
      final items = snapshot.data;
      if (items == null || items.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 16),
        Text('فیلم‌های موجود در دانشنامه',
            style: Theme.of(context).textTheme.titleMedium),
        for (final item in items)
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(item.caption),
            subtitle: Text(item.subtitleReference == null
                ? 'زیرنویس آماده ندارد' : 'زیرنویس محلی موجود است'),
            enabled: !_opening,
            onTap: () => _open(item),
          ),
        if (_opening) const LinearProgressIndicator(),
        if (_error != null)
          Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
      ]);
    },
  );
}

/// The player owns its scratch copy, which is deleted after native disposal.
class _ZimMovieScreen extends ConsumerStatefulWidget {
  const _ZimMovieScreen({
    required this.video, required this.title, required this.identity,
  });
  final ZimPlayableVideo video;
  final String title, identity;
  @override
  ConsumerState<_ZimMovieScreen> createState() => _ZimMovieScreenState();
}

class _ZimMovieScreenState extends ConsumerState<_ZimMovieScreen> {
  late final VideoPlayerController _player;
  late final Future<void> _ready;
  late List<ZimSubtitleCue> _cues;
  bool _busy = false, _cancel = false, _translated = false, _fullText = false;
  String? _error;
  int _parts = 0, _lastTick = -1;

  @override
  void initState() {
    super.initState();
    _cues = widget.video.cues;
    _player = VideoPlayerController.file(widget.video.file);
    _player.addListener(_tick);
    _ready = _player.initialize();
    unawaited(_loadCache());
  }

  void _tick() {
    final tick = _player.value.position.inMilliseconds ~/ 300;
    if (mounted && tick != _lastTick) {
      _lastTick = tick;
      setState(() {});
    }
  }

  Future<File> _captionFile() async {
    final hash = sha256.convert(utf8.encode(widget.identity));
    final home = await getApplicationSupportDirectory();
    return File(p.join(home.path, 'pala-zim-captions', '$hash.srt'));
  }

  Future<void> _loadCache() async {
    try {
      final file = await _captionFile();
      if (!await file.exists() ||
          await file.length() > ZimSubtitles.maxCaptionCharacters) return;
      final captions = ZimSubtitles.parse(await file.readAsString());
      if (mounted && captions.isNotEmpty) {
        setState(() { _cues = captions; _translated = true; });
      }
    } catch (_) { /* A cache miss never blocks playback. */ }
  }

  bool get _persian => _translated ||
      widget.video.subtitleLanguage?.toLowerCase().startsWith('fa') == true;

  Future<void> _convert() async {
    if (_busy) return;
    final model = ref.read(modelManagerProvider).loadedModel;
    if (model == null) {
      setState(() => _error = 'ابتدا مدل Qwen آفلاین را بارگذاری کنید.');
      return;
    }
    await _player.pause();
    setState(() { _busy = true; _cancel = false; _parts = 0; _error = null; });
    try {
      final engine = ref.read(llamaEngineProvider);
      final settings = ref.read(settingsProvider);
      final captions = _cues.isEmpty
          ? await ZimVideoRuntime.transcribeVideo(
              widget.video.file, ref.read(sherpaVoiceProvider),
              engine, model.family, settings,
              cancelled: () => _cancel || !mounted,
              progress: (i) { if (mounted) setState(() => _parts = i); },
            )
          : await ZimVideoRuntime.translateCaptions(
              _cues, engine, model.family, settings,
              cancelled: () => _cancel || !mounted,
              progress: (i, _) { if (mounted) setState(() => _parts = i); },
            );
      if (!mounted) return;
      if (_cancel) {
        setState(() => _error = 'تبدیل متوقف شد؛ متن ناقص ذخیره نشد.');
      } else if (captions.isEmpty) {
        setState(() => _error = 'گفتار معتبری تشخیص داده نشد.');
      } else {
        final file = await _captionFile();
        await file.parent.create(recursive: true);
        await file.writeAsString(ZimSubtitles.srt(captions), flush: true);
        if (mounted) setState(() {
          _cues = captions;
          _translated = true;
          _fullText = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cancel = true;
    _player.removeListener(_tick);
    unawaited(_player.dispose().whenComplete(() async {
      if (await widget.video.file.exists()) await widget.video.file.delete();
    }));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _player.value;
    final current = ZimSubtitles.at(_cues, value.position);
    final maxMillis = value.duration.inMilliseconds <= 0
        ? 1 : value.duration.inMilliseconds;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          FutureBuilder<void>(
            future: _ready,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError || !value.isInitialized) {
                return const Text('پخش این قالب روی دستگاه امکان‌پذیر نیست.');
              }
              return AspectRatio(
                aspectRatio: value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                child: Stack(children: [
                  Positioned.fill(child: VideoPlayer(_player)),
                  if (current != null) Positioned(
                    bottom: 6, left: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: Colors.black87,
                      child: Text(current,
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                ]),
              );
            },
          ),
          if (value.isInitialized) Row(children: [
            IconButton(
              onPressed: () => value.isPlaying
                  ? _player.pause() : _player.play(),
              icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(child: Slider(
              min: 0,
              max: maxMillis.toDouble(),
              value: value.position.inMilliseconds.clamp(0, maxMillis)
                  .toDouble(),
              onChanged: (x) =>
                  _player.seekTo(Duration(milliseconds: x.round())),
            )),
            Text(ZimSubtitles.clock(value.position)),
          ]),
          const SizedBox(height: 12),
          Text(_translated
              ? 'زیرنویس فارسی ماشینی (نیازمند بازبینی)'
              : _cues.isEmpty
                  ? 'این فیلم زیرنویس آماده ندارد.'
                  : 'زیرنویس موجود در آرشیو نمایش داده می‌شود.'),
          if (_busy) ...[
            const LinearProgressIndicator(),
            Text('پردازش آفلاین · بخش $_parts'),
            TextButton(onPressed: () => setState(() => _cancel = true),
                child: const Text('توقف پردازش')),
          ] else if (!_persian) ...[
            FilledButton.icon(
              onPressed: _convert,
              icon: const Icon(Icons.translate),
              label: Text(_cues.isEmpty
                  ? 'تبدیل گفتار فیلم به زیرنویس فارسی'
                  : 'ترجمه زیرنویس به فارسی'),
            ),
            const Text('برای فیلم بدون زیرنویس، موتور گفتار محلی لازم است. '
                'زمان‌ها در بخش‌های تقریبی ۲۰ ثانیه‌ای تنظیم می‌شوند.'),
          ],
          if (_error != null) Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
          if (_cues.isNotEmpty) ...[
            TextButton.icon(
              onPressed: () => setState(() => _fullText = !_fullText),
              icon: const Icon(Icons.article_outlined),
              label: Text(_fullText ? 'بستن متن کامل' : 'متن کامل فیلم'),
            ),
            if (_fullText) ...[
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(
                    text: ZimSubtitles.fullText(_cues))),
                icon: const Icon(Icons.copy),
                label: const Text('کپی متن'),
              ),
              SelectableText(ZimSubtitles.fullText(_cues)),
            ],
          ],
        ]),
      ),
    );
  }
}
