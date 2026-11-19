import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/external_links.dart';
import '../chat/domain/conversation_workspace.dart';
import '../chat/presentation/providers/chat_provider.dart';
import '../knowledge/folder_library.dart';
import '../settings/presentation/providers/effective_settings_provider.dart';
import 'zim_image_selection.dart';

/// Gallery of real images from the same approved offline citation, not AI art.
class ZimInlineGallery extends ConsumerStatefulWidget {
  const ZimInlineGallery({
    super.key,
    required this.sources,
    required this.question,
  });

  final List<Map<String, dynamic>> sources;
  final String question;

  @override
  ConsumerState<ZimInlineGallery> createState() => _ZimInlineGalleryState();
}

class _ZimInlineGalleryState extends ConsumerState<ZimInlineGallery> {
  Future<ZimLocalGallery?>? _gallery;
  bool _expanded = false;

  Map<String, dynamic>? get _citation {
    for (final source in widget.sources) {
      if ((source['url'] as String? ?? '').startsWith('zim://') &&
          source['archiveId'] is String) {
        return source;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _gallery = _read();
  }

  @override
  void didUpdateWidget(covariant ZimInlineGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.question != widget.question ||
        oldWidget.sources != widget.sources) {
      _expanded = false;
      _gallery = _read();
    }
  }

  Future<ZimLocalGallery?> _read() async {
    final citation = _citation;
    if (citation == null) return null;
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

    try {
      return await ref.read(folderLibraryProvider).articleGallery(
        citation['url'] as String,
        citation['archiveId'] as String,
        citation['archiveDate'] as String?,
        question: widget.question,
        maxImages: _expanded ? 6 : 2,
        allowSource: allowed,
      );
    } catch (_) {
      return null;
    }
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
    if (_citation == null || _gallery == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<ZimLocalGallery?>(
      future: _gallery,
      builder: (context, snapshot) {
        final gallery = snapshot.data;
        if (gallery == null) return const SizedBox.shrink();
        final hasPictures = gallery.images.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasPictures
                    ? '${gallery.referencedCount} تصویر در مقاله آفلاین معرفی شده؛ '
                      '${gallery.images.length} تصویر نمایش داده می‌شود'
                    : 'تصویر قابل‌نمایشی در این منبع آفلاین پیدا نشد.',
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
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 156,
                              height: 142,
                              child: Image.memory(
                                photo.bytes,
                                cacheWidth: 360,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Center(child: Icon(Icons.broken_image)),
                              ),
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
