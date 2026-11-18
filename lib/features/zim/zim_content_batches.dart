import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'zim_archive.dart';
import 'zim_source.dart';

/// One bounded, resumable read for an eventual persistent content index.
/// The cursor is an archive directory position, not a byte offset.
class ZimContentBatch {
  final List<({int entry, String title, String text})> articles;
  final int next, total, skipped;
  final bool cancelled;
  const ZimContentBatch(
    this.articles,
    this.next,
    this.total,
    this.skipped,
    this.cancelled,
  );
  bool get complete => next >= total;
}

/// Reads only a user-authorized archive in bounded batches. This class does
/// not write an index or persist a cursor; its caller must commit both together.
class ZimContentBatches {
  static const maxEntriesPerBatch = 32;
  static const maxArticleBytes = 1024 * 1024;
  static const maxBatchTextBytes = 2 * 1024 * 1024;
  final ZimArchive archive;
  final bool Function() allowed;
  ZimContentBatches._(this.archive, this.allowed);

  static Future<ZimContentBatches> open(
    String uri, {
    required bool Function() allowed,
    Future<ZimSource> Function(String)? openSource,
  }) async {
    if (!allowed()) throw StateError('منبع خارج از محدوده پروژه است');
    final archive = await ZimArchive.open(
      uri,
      openSource: (path) {
        if (!allowed()) throw StateError('محدوده منابع تغییر کرد');
        return (openSource ?? ZimSource.open)(path);
      },
      clusterByteLimit: 16 * 1024 * 1024,
      cacheByteLimit: 8 * 1024 * 1024,
    );
    if (!allowed()) {
      await archive.close();
      throw StateError('محدوده منابع تغییر کرد');
    }
    return ZimContentBatches._(archive, allowed);
  }

  Future<ZimContentBatch> read({
    required int cursor,
    int limit = 16,
    bool Function()? cancelled,
  }) async {
    if (cursor < 0 ||
        cursor > archive.entryCount ||
        limit < 1 ||
        limit > maxEntriesPerBatch) {
      throw ArgumentError('Invalid content batch range');
    }
    void checkScope() {
      if (!allowed()) throw StateError('محدوده منابع تغییر کرد');
    }

    final articles = <({int entry, String title, String text})>[];
    var index = cursor, visited = 0, bytes = 0, skipped = 0;
    while (index < archive.entryCount && visited < limit) {
      checkScope();
      if (cancelled?.call() == true) {
        return ZimContentBatch(
          articles,
          index,
          archive.entryCount,
          skipped,
          true,
        );
      }
      final entry = await archive.entry(index);
      checkScope();
      if (entry.isArticle &&
          (entry.namespace == 'C' || entry.namespace == 'A')) {
        try {
          final raw = await archive.content(entry);
          checkScope();
          if (cancelled?.call() == true) {
            return ZimContentBatch(
              articles,
              index,
              archive.entryCount,
              skipped,
              true,
            );
          }
          if (raw.length > maxArticleBytes) {
            skipped++;
          } else {
            final text = _bodyText(utf8.decode(raw, allowMalformed: true));
            final size = utf8.encode(text).length;
            if (size > maxBatchTextBytes) {
              skipped++;
            } else if (bytes + size > maxBatchTextBytes) {
              break; // Resume at this article in the next batch.
            } else if (text.isNotEmpty) {
              articles.add((
                entry: entry.index,
                title: entry.title,
                text: text,
              ));
              bytes += size;
            }
          }
        } on FormatException {
          skipped++;
        }
      }
      index++;
      visited++;
    }
    checkScope();
    return ZimContentBatch(articles, index, archive.entryCount, skipped, false);
  }

  static String _bodyText(String markup) {
    final document = html.parse(markup);
    final root = document.body ?? document.documentElement;
    if (root == null) return '';
    final text = StringBuffer();
    final pending = <dom.Node>[root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is dom.Text) {
        text.write(' ');
        text.write(node.data);
      } else if (node is dom.Element &&
          !const {'script', 'style', 'noscript', 'svg', 'template'}.contains(node.localName)) {
        pending.addAll(node.nodes.reversed);
      }
    }
    return text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> close() => archive.close();
}
