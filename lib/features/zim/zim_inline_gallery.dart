import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/external_links.dart';
import '../chat/domain/conversation_workspace.dart';
import '../chat/presentation/providers/chat_provider.dart';
import '../knowledge/folder_library.dart';
import '../settings/presentation/providers/effective_settings_provider.dart';
import 'zim_image_selection.dart';

/// Only ZIM citations with an explicitly matching archive identity
/// may offer offline thumbnails. The underlying read validates SAF and scope.
bool canPreviewLocalImageSource(Map<String, dynamic> source) {
  final url = source['url'];
  final archiveId = source['archiveId'];
  if (url is! String || archiveId is! String || archiveId.isEmpty) {
    return false;
  }
  final parsed = Uri.tryParse(url);
  return parsed != null &&
      parsed.scheme == 'zim' &&
      parsed.host == archiveId;
}

/// Bound automatic previews when search returns many sources. Others remain
/// reachable through their source details, without hidden network I/O.
List<Map<String, dynamic>> localSearchPreviewSources(
  List<Map<String, dynamic>> sources, {
  int maxPreviews = 4,
}) {
  if (maxPreviews <= 0) return const [];
  return sources.where(canPreviewLocalImageSource).take(maxPreviews).toList();
}

/// Verified image result attached to the exact local citation that supplied it.
class ZimGalleryMatch {
  const ZimGalleryMatch(this.citation, this.gallery);

  final Map<String, dynamic> citation;
  final ZimLocalGallery gallery;
}

/// Try several already cited local articles without touching the network.
/// A text-only first citation must not conceal pictures in the next one.
/// Every read still goes through the same SAF, revision and project checks.
Future<ZimGalleryMatch?> findFirstLocalGallery(
  List<Map<String, dynamic>> sources,
  Future<ZimLocalGallery?> Function(Map<String, dynamic>) read, {
  int maxSources = 4,
}) async {
  if (maxSources <= 0) return null;
  final seen = <String>{};
  var checked = 0;
  ZimGalleryMatch? textOnly;
  for (final source in sources) {
    final url = source['url'];
    final archive = source['archiveId'];
    if (!canPreviewLocalImageSource(source) ||
        !seen.add('$archive|$url')) {
      continue;
    }
    if (checked++ >= maxSources) break;
    try {
      final gallery = await read(source);
      if (gallery == null) continue;
      final result = ZimGalleryMatch(source, gallery);
      if (gallery.images.isNotEmpty) return result;
      textOnly ??= result;
    } catch (_) {
      // An inaccessible citation cannot suppress another approved source.
    }
  }
  return textOnly;
}

/// Gallery of real images from approved offline citations, not AI art.
class ZimInlineGallery extends ConsumerStatefulWidget {
  const ZimInlineGallery({
    super.key,
    required this.sources,
    required this.question,
    this.previewOnly = false,
  });

  final List<Map<String, dynamic>> sources;
  final String question;
  /// Compact single-image thumbnail for the already visible source list.
  final bool previewOnly;

  @override
  ConsumerState<ZimInlineGallery> createState() => _ZimInlineGalleryState();
}

class _ZimInlineGalleryState extends ConsumerState<ZimInlineGallery> {
  Future<ZimGalleryMatch?>? _gallery;
  bool _expanded = false;

  bool get _hasZimCitation => widget.sources.any(canPreviewLocalImageSource);

  @override
  void initState() {
    super.initState();
    _gallery = _read();
  }

  @override
  void didUpdateWidget(covariant ZimInlineGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.question != widget.question ||
        oldWidget.sources != widget.sources ||
        oldWidget.previewOnly != widget.previewOnly) {
      _expanded = false;
      _gallery = _read();
    }
  }

  Future<ZimGalleryMatch?> _read() async {
    if (!_hasZimCitation) return null;
    await ref.read(conversationWorkspaceProvider.notifier).ready;
    final workspace = ref.read(conversationWorkspaceProvider);
    if (!workspace.loaded || !workspace.readable) return null;
    final chatId = ref.read(chatProvider).chatId;
    final projectId = chatId == null
        ? ref.read(newChatProjectProvider)
        : workspace.memberships[chatId];

    bool allowed(String uri) {
      final current = ref.read(conversationWorkspaceProvider);
      final activeChat = ref.read(chatProvider).chatId;
      if (!current.loaded || !current.readable || activeChat != chatId) {
        return false;
      }
      final selectedProject = activeChat == null
          ? ref.read(newChatProjectProvider)
          : current.memberships[activeChat];
      if (selectedProject != projectId) return false;
      if (projectId == null) return true;
      final id = FolderLibrary.sourceId(uri);
      return current.projects.any(
        (p) => p.id == projectId && p.sourceIds.contains(id),
      );
    }

    return findFirstLocalGallery(widget.sources, (citation) async {
      return ref
          .read(folderLibraryProvider)
          .articleGallery(
            citation['url'] as String,
            citation['archiveId'] as String,
            citation['archiveDate'] as String?,
            question: widget.question,
            maxImages: widget.previewOnly ? 1 : (_expanded ? 6 : 2),
            allowSource: allowed,
          );
    });
  }

  Future<void> _offerInternet() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('جست‌وجوی عکس در اینترنت'),
        content: const Text(
          'تصویر مناسبی در منبع آفلاین پیدا نشد. '
          'در صورت ادامه، عبارت پرسش به موتور جست‌وجوی اینترنتی '
          'ارسال می‌شود. هیچ عکسی خودکار دانلود نمی‌شود.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ادامه'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    final url = Uri.https('www.google.com', '/search', {
      'tbm': 'isch',
      'q': widget.question,
    });
    await openExternalLink(url.toString());
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasZimCitation || _gallery == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<ZimGalleryMatch?>(
      future: _gallery,
      builder: (context, snapshot) {
        final selected = snapshot.data;
        if (selected == null) return const SizedBox.shrink();
        final gallery = selected.gallery;
        final sourceName =
            (selected.citation['title'] as String? ?? 'دانشنامه آفلاین').trim();
        final hasPictures = gallery.images.isNotEmpty;
        if (widget.previewOnly) {
          if (!hasPictures) return const SizedBox.shrink();
          final picture = gallery.images.first;
          return Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 16, 10),
            child: Semantics(
              label: 'تصویر از منبع آفلاین: $sourceName',
              child: InkWell(
                key: const Key('zim-search-thumbnail'),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => Dialog(
                    child: InteractiveViewer(
                      child: Image.memory(picture.bytes),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        picture.bytes,
                        width: 88,
                        height: 76,
                        cacheWidth: 200,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox(
                          width: 88,
                          height: 76,
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        picture.caption.trim().isEmpty
                            ? 'عکس مقاله · منبع آفلاین'
                            : 'عکس مقاله · منبع آفلاین\n${picture.caption}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasPictures
                    ? '${gallery.images.length} تصویر از منبع محلی «$sourceName» '
                          '(از ${gallery.referencedCount} ارجاع تصویری مقاله)'
                    : 'در منابع محلی بررسی‌شده تصویر قابل‌نمایشی پیدا نشد.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (hasPictures) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final photo in gallery.images)
                      Semantics(
                        label: photo.caption.isNotEmpty
                            ? photo.caption
                            : 'تصویر دانشنامه آفلاین',
                        child: InkWell(
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => Dialog(
                              child: InteractiveViewer(
                                child: Image.memory(photo.bytes),
                              ),
                            ),
                          ),
                          child: SizedBox(
                            width: 156,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: SizedBox(
                                    width: 156,
                                    height: 142,
                                    child: Image.memory(
                                      photo.bytes,
                                      cacheWidth: 360,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Center(
                                        child: Icon(Icons.broken_image),
                                      ),
                                    ),
                                  ),
                                ),
                                if (photo.caption.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      photo.caption,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (!_expanded && gallery.referencedCount > 2)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _expanded = true;
                        _gallery = _read();
                      });
                    },
                    child: const Text('نمایش بقیه عکس‌ها'),
                  ),
              ] else
                TextButton(
                  onPressed: _offerInternet,
                  child: const Text('جست‌وجوی تصاویر در اینترنت'),
                ),
            ],
          ),
        );
      },
    );
  }
}
