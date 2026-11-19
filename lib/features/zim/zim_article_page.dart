import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/providers/shared_providers.dart';
import '../../data/network/web_search/search_models.dart';
import '../../core/design/app_design.dart';
import '../knowledge/folder_library.dart';
import '../chat/domain/conversation_workspace.dart';
import '../chat/presentation/providers/chat_provider.dart';
import '../settings/presentation/providers/effective_settings_provider.dart';
import 'zim_inline_gallery.dart';

/// Local article links stay inside the imported archive. The saved excerpt
/// remains available if that archive has since been replaced or removed.
class ZimArticlePage extends ConsumerWidget {
  final String url, title, excerpt;
  final String? archiveDate, archiveId;
  const ZimArticlePage({
    super.key,
    required this.url,
    required this.title,
    required this.excerpt,
    this.archiveDate,
    this.archiveId,
  });
  Future<SearchResult?> _article(WidgetRef ref) async {
    await ref.read(conversationWorkspaceProvider.notifier).ready;
    final chatId = ref.read(chatProvider).chatId;
    final workspace = ref.read(conversationWorkspaceProvider);
    if (!workspace.loaded || !workspace.readable) return null;
    final projectId = chatId == null
        ? ref.read(newChatProjectProvider)
        : workspace.memberships[chatId];
    bool inScope(String uri) {
      final current = ref.read(conversationWorkspaceProvider);
      if (!current.loaded ||
          !current.readable ||
          ref.read(chatProvider).chatId != chatId)
        return false;
      final activeProject = chatId == null
          ? ref.read(newChatProjectProvider)
          : current.memberships[chatId];
      if (activeProject != projectId) return false;
      if (projectId == null) return true;
      final id = FolderLibrary.sourceId(uri);
      return current.projects.any(
        (p) => p.id == projectId && p.sourceIds.contains(id),
      );
    }

    if (archiveId != null) {
      try {
        String? openedUri;
        final direct = await ref
            .read(folderLibraryProvider)
            .article(
              url,
              archiveId!,
              archiveDate,
              allowSource: (uri) {
                final allowed = inScope(uri);
                if (allowed) openedUri = uri;
                return allowed;
              },
            );
        if (direct != null && openedUri != null && inScope(openedUri!))
          return direct;
      } catch (_) {
        /* Retain the saved excerpt when folder access is absent. */
      }
    }
    // The legacy imported archive has no project source identity. Never open
    // it on behalf of a scoped project or after the active chat has changed.
    if (projectId != null || !inScope('')) return null;
    final wiki = await ref.read(zimWikipediaProvider.future);
    if (wiki == null || archiveId == null || !inScope('')) return null;
    if (await wiki.archiveIdentity() != archiveId || !inScope('')) return null;
    final date = await wiki.archiveMetadata('Date');
    if (date != archiveDate || !inScope('')) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'zim') return null;
    // An indexed folder citation identifies an exact folder source; it must
    // not fall back to a different legacy archive with a coincident UUID.
    if (parsed.queryParameters.containsKey('source')) return null;
    final entryText = parsed.queryParameters['entry'];
    final entry = entryText == null ? null : int.tryParse(entryText);
    if (entryText != null &&
        (entry == null ||
            entry < 0 ||
            parsed.host != archiveId ||
            parsed.pathSegments.length != 1))
      return null;
    final name = entry == null
        ? Uri.decodeComponent(url.substring(6)).replaceAll('_', ' ')
        : parsed.pathSegments.single.replaceAll('_', ' ');
    final result = entry == null
        ? await wiki.article(name)
        : await wiki.articleAt(entry, expectedTitle: name);
    return inScope('') ? result : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<SearchResult?>(
      future: _article(ref),
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(AppDesign.lg),
          children: [
            Text(
              context.l10n.sourceArchiveSnapshot(
                archiveDate ?? '—',
                s.data?.archiveLanguage ?? '—',
              ),
            ),
            Text(context.l10n.sourceOfflineLimitation),
            if (s.data == null) Text(context.l10n.sourceArchiveUnavailable),
            const SizedBox(height: AppDesign.lg),
            SelectableText(s.data?.pageText ?? excerpt),
            if (s.data != null && archiveId != null)
              ZimInlineGallery(
                sources: [
                  {
                    'url': url,
                    'archiveId': archiveId,
                    'archiveDate': archiveDate,
                  },
                ],
                question: title,
              ),
          ],
        );
      },
    ),
  );
}
