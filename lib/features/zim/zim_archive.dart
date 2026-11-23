import 'dart:convert';
import 'dart:io';

import 'zim_source.dart';

import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'zstd.dart';
import '../../core/utils/priority_work_queue.dart';

/// One directory entry of a ZIM file: an article, a redirect or metadata.
class ZimEntry {
  final int index;
  final String namespace, url, title, mime;

  /// For a redirect, the entry it points to; else null.
  final int? redirect;
  final int cluster, blob;

  const ZimEntry({
    required this.index,
    required this.namespace,
    required this.url,
    required this.title,
    required this.mime,
    this.redirect,
    this.cluster = 0,
    this.blob = 0,
  });

  bool get isArticle => redirect == null && mime.startsWith('text/html');
}

/// A Kiwix ZIM file (openzim.org/wiki/ZIM_file_format) read in place:
/// offline Wikipedia the tester downloaded or imported. Only the header and
/// MIME list are loaded; entries and clusters are read on demand, and the
/// last few decompressed clusters are kept. Clusters are zstd (current
/// files), xz (older files) or stored.
class ZimArchive {
  static const _magic = 72173914;
  static const maxClusterBytes = 64 * 1024 * 1024;
  static const maxCachedClusterBytes = 64 * 1024 * 1024;

  final ZimSource _file;
  final String identity;
  final int clusterByteLimit, cacheByteLimit;
  int get cachedClusterBytes =>
      _clusters.values.fold(0, (sum, item) => sum + item.$1.length);
  final int entryCount, clusterCount, mainPage;
  final int _urlPtrPos, _clusterPtrPos, _checksumPos;
  int _titlePtrPos;
  late int _titleCount = entryCount;
  final _queue = PriorityWorkQueue();
  Future<void>? _closed;
  final List<String> _mimes;
  final _clusters = <int, (Uint8List, bool)>{};

  ZimArchive._(
    this._file, {
    required this.identity,
    required this.clusterByteLimit,
    required this.cacheByteLimit,
    required this.entryCount,
    required this.clusterCount,
    required this.mainPage,
    required int urlPtrPos,
    required int titlePtrPos,
    required int clusterPtrPos,
    required int checksumPos,
    required List<String> mimes,
  }) : _urlPtrPos = urlPtrPos, // ignore: prefer_initializing_formals
       _titlePtrPos = titlePtrPos, // ignore: prefer_initializing_formals
       _clusterPtrPos = clusterPtrPos, // ignore: prefer_initializing_formals
       _checksumPos = checksumPos, // ignore: prefer_initializing_formals
       _mimes = mimes; // ignore: prefer_initializing_formals

  static Future<ZimArchive> open(
    String path, {
    int clusterByteLimit = maxClusterBytes,
    int cacheByteLimit = maxCachedClusterBytes,
    Future<ZimSource> Function(String)? openSource,
  }) async {
    if (clusterByteLimit < 1 ||
        clusterByteLimit > maxClusterBytes ||
        cacheByteLimit < 0 ||
        cacheByteLimit > maxCachedClusterBytes) {
      throw ArgumentError('Invalid ZIM byte limits');
    }
    final file = await (openSource ?? ZimSource.open)(path);
    try {
      final header = await _readAt(file, 0, 80);
      if (header.length != 80) {
        throw const FormatException('ZIM: truncated header');
      }
      final h = ByteData.sublistView(header);
      if (h.getUint32(0, Endian.little) != _magic) {
        throw const FormatException('Not a ZIM file');
      }
      int u64(int at) => h.getUint64(at, Endian.little);
      final major = h.getUint16(4, Endian.little);
      if (major != 5 && major != 6) {
        throw FormatException('ZIM: unsupported format version $major');
      }
      final length = await file.length();
      final count = h.getUint32(24, Endian.little);
      final clusters = h.getUint32(28, Endian.little);
      final checksum = u64(72);
      if (checksum < 80 || checksum > length - 16) {
        throw const FormatException('ZIM: truncated content or checksum');
      }
      void table(int pos, int bytes) {
        if (pos < 80 || bytes < 0 || pos + bytes > checksum) {
          throw const FormatException('ZIM: table outside archive');
        }
      }

      table(u64(32), count * 8);
      table(u64(48), clusters * 8);
      // v6.3 writers use UINT64_MAX as well as zero for the removed table.
      final oldTitle = u64(40);
      final hasOldTitle = oldTitle != 0 && oldTitle != -1;
      if (hasOldTitle) table(oldTitle, count * 4);
      final mimePos = u64(56);
      final mimeBytes = await _readAt(file, mimePos, 4096);
      final mimes = <String>[];
      var start = 0;
      for (var i = 0; i < mimeBytes.length; i++) {
        if (mimeBytes[i] != 0) continue;
        if (i == start) break;
        mimes.add(utf8.decode(mimeBytes.sublist(start, i)));
        start = i + 1;
      }
      final archive = ZimArchive._(
        file,
        clusterByteLimit: clusterByteLimit,
        cacheByteLimit: cacheByteLimit,
        identity: header
            .sublist(8, 24)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        entryCount: h.getUint32(24, Endian.little),
        clusterCount: h.getUint32(28, Endian.little),
        urlPtrPos: u64(32),
        titlePtrPos: hasOldTitle ? oldTitle : 0,
        clusterPtrPos: u64(48),
        mainPage: h.getUint32(64, Endian.little),
        checksumPos: u64(72),
        mimes: mimes,
      );
      await archive._loadTitleListing();
      return archive;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed != null) {
      return Future.error(StateError('ZIM archive is closed'));
    }
    return _queue.submit(action);
  }

  /// Finishes accepted operations before closing the shared file cursor.
  Future<void> close() => _closed ??= _queue.submit(() async {
    _clusters.clear();
    await _file.close();
  });

  int get titleCount => _titleCount;

  Future<void> _loadTitleListing() async {
    final listing = await _findPath('X', 'listing/titleOrdered/v1');
    if (listing != null && listing.redirect == null) {
      final start = await _u64At(_clusterPtrPos + 8 * listing.cluster);
      final info = await _readAt(_file, start, 1);
      if (info.isEmpty) throw const FormatException('ZIM: cut title listing');
      if ((info[0] & 15) <= 1) {
        final (offset, length) = (await _storedBlobRange(listing))!;
        if (length % 4 != 0 || length ~/ 4 > entryCount) {
          throw const FormatException('ZIM: invalid title listing length');
        }
        _titlePtrPos = offset;
        _titleCount = length ~/ 4;
        return;
      }
    }
    if (_titlePtrPos == 0) {
      throw const FormatException('ZIM: missing title ordered listing');
    }
  }

  static Future<Uint8List> _readAt(ZimSource f, int pos, int n) =>
      f.readAt(pos, n);

  Future<int> _u64At(int pos) async {
    final bytes = await _readAt(_file, pos, 8);
    if (bytes.length != 8) throw const FormatException('ZIM: cut pointer');
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  /// The entry at [index] in URL order.
  Future<ZimEntry> entry(int index) => _run(() => _entry(index));

  Future<ZimEntry> _entry(int index) async {
    if (index < 0 || index >= entryCount) {
      throw RangeError.range(index, 0, entryCount - 1, 'entry index');
    }
    final pos = await _u64At(_urlPtrPos + 8 * index);
    if (pos < 80 || pos >= _checksumPos) {
      throw const FormatException('ZIM: invalid entry offset');
    }
    var bytes = await _readAt(_file, pos, 512);
    while (true) {
      final parsed = _parseEntry(index, bytes);
      if (parsed != null) return parsed;
      if (bytes.length < 512 || bytes.length >= 65536) {
        throw const FormatException('ZIM: cut or oversized entry');
      }
      bytes = await _readAt(_file, pos, bytes.length * 4);
    }
  }

  ZimEntry? _parseEntry(int index, Uint8List b) {
    if (b.length < 12) return null;
    final d = ByteData.sublistView(b);
    final mime = d.getUint16(0, Endian.little);
    final paramLen = b[2];
    final ns = String.fromCharCode(b[3]);
    final redirect = mime == 0xffff;
    final p = redirect ? 12 : 16;
    if (b.length < p) return null;
    final urlEnd = b.indexOf(0, p);
    if (urlEnd < 0) return null;
    final titleEnd = b.indexOf(0, urlEnd + 1);
    if (titleEnd < 0 || titleEnd + paramLen > b.length) return null;
    final url = utf8.decode(b.sublist(p, urlEnd), allowMalformed: true);
    final title = titleEnd == urlEnd + 1
        ? url
        : utf8.decode(b.sublist(urlEnd + 1, titleEnd), allowMalformed: true);
    return ZimEntry(
      index: index,
      namespace: ns,
      url: url,
      title: title,
      mime: redirect || mime >= _mimes.length ? '' : _mimes[mime],
      redirect: redirect ? d.getUint32(8, Endian.little) : null,
      cluster: redirect ? 0 : d.getUint32(8, Endian.little),
      blob: redirect ? 0 : d.getUint32(12, Endian.little),
    );
  }

  /// The entry at [i] in title order.
  Future<ZimEntry> entryByTitleIndex(int i) =>
      _run(() => _entryByTitleIndex(i));
  Future<ZimEntry> _entryByTitleIndex(int i) async {
    if (i < 0 || i >= _titleCount) {
      throw RangeError.range(i, 0, _titleCount - 1, 'title index');
    }
    final idx = ByteData.sublistView(
      await _readAt(_file, _titlePtrPos + 4 * i, 4),
    ).getUint32(0, Endian.little);
    return _entry(idx);
  }

  /// The entry titled exactly [title] in [namespaces] (the first that has
  /// one), by binary search over the title list; redirects are followed.
  Future<ZimEntry?> findByTitle(
    String title, {
    List<String> namespaces = const ['C', 'A'],
  }) => _run(() => _findByTitle(title, namespaces));

  Future<ZimEntry?> _findByTitle(String title, List<String> namespaces) async {
    for (final ns in namespaces) {
      final want = utf8.encode('$ns$title');
      var lo = 0, hi = _titleCount - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final e = await _entryByTitleIndex(mid);
        final c = _compare(utf8.encode('${e.namespace}${e.title}'), want);
        if (c == 0) return _resolve(e);
        if (c < 0) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
    }
    return null;
  }

  static int _compare(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// [e], or the entry its redirects end at (at most five hops).
  Future<ZimEntry?> resolve(ZimEntry e) => _run(() => _resolve(e));
  Future<ZimEntry?> _resolve(ZimEntry e) async {
    var at = e;
    for (var hop = 0; hop < 5 && at.redirect != null; hop++) {
      if (at.redirect! >= entryCount) {
        throw const FormatException('ZIM: invalid redirect');
      }
      at = await _entry(at.redirect!);
    }
    return at.redirect == null ? at : null;
  }

  /// The bytes of a content entry.
  Future<Uint8List> content(ZimEntry e) => _run(() => _content(e));
  Future<Uint8List> _content(ZimEntry e) async {
    if (e.redirect != null) throw ArgumentError('A redirect has no content');
    final stored = await _storedBlobRange(e);
    if (stored != null) {
      final (offset, length) = stored;
      if (length > clusterByteLimit) {
        throw const FormatException('ZIM: blob exceeds safety limit');
      }
      final bytes = await _readAt(_file, offset, length);
      if (bytes.length != length) throw const FormatException('ZIM: cut blob');
      return bytes;
    }
    final (data, extended) = await _cluster(e.cluster);
    final size = extended ? 8 : 4;
    final d = ByteData.sublistView(data);
    if (data.length < size * 2) {
      throw const FormatException('ZIM: truncated blob table');
    }
    int off(int i) => extended
        ? d.getUint64(i * size, Endian.little)
        : d.getUint32(i * size, Endian.little);
    final blobs = off(0) ~/ size - 1;
    if (blobs < 0 ||
        (blobs + 1) * size > data.length ||
        e.blob < 0 ||
        e.blob >= blobs) {
      throw const FormatException('ZIM: no such blob');
    }
    if (off(e.blob) < (blobs + 1) * size ||
        off(e.blob) > off(e.blob + 1) ||
        off(e.blob + 1) > data.length) {
      throw const FormatException('ZIM: invalid blob offset');
    }
    return Uint8List.sublistView(data, off(e.blob), off(e.blob + 1));
  }

  /// Stored clusters may contain huge unrelated index blobs. Read only the
  /// requested blob's offsets, as libzim's direct title accessor does.
  Future<(int, int)?> _storedBlobRange(ZimEntry e) async {
    if (e.cluster < 0 || e.cluster >= clusterCount) {
      throw const FormatException('ZIM: no such cluster');
    }
    final start = await _u64At(_clusterPtrPos + 8 * e.cluster);
    final end = e.cluster + 1 < clusterCount
        ? await _u64At(_clusterPtrPos + 8 * (e.cluster + 1))
        : _checksumPos;
    if (start < 80 || end <= start || end > _checksumPos) {
      throw const FormatException('ZIM: invalid cluster range');
    }
    final info = await _readAt(_file, start, 1);
    if (info.length != 1) throw const FormatException('ZIM: cut cluster');
    if ((info[0] & 15) > 1) return null;
    final size = info[0] & 16 != 0 ? 8 : 4;
    Future<int> offset(int i) async {
      final at = start + 1 + i * size;
      if (at + size > end) throw const FormatException('ZIM: cut blob offsets');
      final bytes = await _readAt(_file, at, size);
      if (bytes.length != size)
        throw const FormatException('ZIM: cut blob offsets');
      final data = ByteData.sublistView(bytes);
      return size == 8
          ? data.getUint64(0, Endian.little)
          : data.getUint32(0, Endian.little);
    }

    final first = await offset(0);
    if (first < 2 * size ||
        first % size != 0 ||
        first > end - start - 1 ||
        e.blob < 0 ||
        e.blob >= first ~/ size - 1) {
      throw const FormatException('ZIM: invalid blob table');
    }
    final lo = await offset(e.blob), hi = await offset(e.blob + 1);
    if (lo < first || hi < lo || hi > end - start - 1) {
      throw const FormatException('ZIM: invalid blob offset');
    }
    return (start + 1 + lo, hi - lo);
  }

  /// A cluster's blob area, decompressed; the last four are cached.
  Future<(Uint8List, bool)> _cluster(int i) async {
    final hit = _clusters.remove(i);
    if (hit != null) return _clusters[i] = hit;
    if (i < 0 || i >= clusterCount) {
      throw const FormatException('ZIM: no such cluster');
    }
    final start = await _u64At(_clusterPtrPos + 8 * i);
    final end = i + 1 < clusterCount
        ? await _u64At(_clusterPtrPos + 8 * (i + 1))
        : _checksumPos;
    if (start < 80 ||
        end <= start ||
        end > _checksumPos ||
        end - start > 64 * 1024 * 1024) {
      throw const FormatException('ZIM: invalid or oversized cluster');
    }
    final raw = await _readAt(_file, start, end - start);
    if (raw.length != end - start) {
      throw const FormatException('ZIM: cut cluster');
    }
    final info = raw[0];
    final body = Uint8List.sublistView(raw, 1);
    final kind = info & 0x0f;
    // A cluster is a few MB of text: decompressed off the UI isolate.
    final limit = clusterByteLimit;
    final data = switch (kind) {
      0 || 1 => body,
      4 => await Isolate.run(() {
        final output = _BoundedClusterOutput(limit);
        XZDecoder(maxPreallocateSize: 0).decodeStream(
          InputMemoryStream(body),
          output,
          verify: true,
          throwOnError: true,
        );
        return output.getBytes();
      }),
      5 => await Isolate.run(() => Zstd.decode(body, maxOutputBytes: limit)),
      _ => throw FormatException('ZIM: compression $kind'),
    };
    if (data.length > limit) {
      throw const FormatException('ZIM: expanded cluster exceeds safety limit');
    }
    final result = (data, info & 0x10 != 0);
    _clusters[i] = result;
    while (cachedClusterBytes > cacheByteLimit) {
      _clusters.remove(_clusters.keys.first);
    }
    return result;
  }

  /// A metadata value ("Title", "Language", "Date"), or null.
  Future<ZimEntry?> _findPath(String ns, String name) async {
    var lo = 0, hi = entryCount - 1;
    final want = utf8.encode('$ns$name');
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final e = await _entry(mid);
      final c = _compare(utf8.encode('${e.namespace}${e.url}'), want);
      if (c == 0) return e;
      if (c < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// Read a bounded image in the same ZIM archive as [article].
  /// No external URLs, copies of the archive or executable image formats.
  Future<Uint8List?> imageBytes(
    ZimEntry article,
    String reference, {
    int maxImageBytes = 2 * 1024 * 1024,
  }) => _run(() async {
    if (!article.isArticle ||
        reference.isEmpty ||
        reference.length > 2048 ||
        reference.startsWith('//') ||
        maxImageBytes < 1 ||
        maxImageBytes > 2 * 1024 * 1024) {
      return null;
    }
    final relative = Uri.tryParse(reference);
    if (relative == null ||
        relative.hasScheme ||
        relative.hasAuthority ||
        relative.hasFragment) {
      return null;
    }
    final base = Uri(path: '/' + article.namespace + '/' + article.url);
    final path = base
        .resolveUri(relative)
        .pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (path.length < 2) return null;
    final ns = path.first;
    if (ns != 'I' && ns != 'C' && ns != 'A') return null;
    // Older ZIMs store pictures in I/. In newer archives the same
    // resource may be stored under C/I/ after the namespace migration.
    var entry = await _findPath(ns, path.skip(1).join('/'));
    if (entry == null && ns == 'I') {
      entry = await _findPath('C', path.join('/'));
    }
    if (entry == null) return null;
    final resolved = await _resolve(entry);
    if (resolved == null) return null;
    final mime = resolved.mime.toLowerCase();
    if (!const {
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    }.contains(mime)) {
      return null;
    }
    final bytes = await _content(resolved);
    if (bytes.isEmpty || bytes.length > maxImageBytes) return null;
    return Uint8List.fromList(bytes);
  });


  /// Resolve a linked asset in this ZIM, never accepting a remote URL.
  Future<ZimEntry?> _localMediaAsset(
    ZimEntry article, String reference, Set<String> mimes,
  ) async {
    if (!article.isArticle || reference.isEmpty || reference.length > 2048 ||
        reference.startsWith('//')) return null;
    final relative = Uri.tryParse(reference);
    if (relative == null || relative.hasScheme || relative.hasAuthority ||
        relative.hasFragment || relative.hasQuery) return null;
    final path = Uri(path: '/${article.namespace}/${article.url}')
        .resolveUri(relative).pathSegments
        .where((s) => s.isNotEmpty).toList();
    if (path.length < 2 || !const {'I', 'C', 'A'}.contains(path.first)) {
      return null;
    }
    final ns = path.first;
    var asset = await _findPath(ns, path.skip(1).join('/'));
    if (asset == null && ns == 'I') {
      asset = await _findPath('C', path.join('/'));
    }
    if (asset == null) return null;
    final resolved = await _resolve(asset);
    if (resolved == null || !mimes.contains(resolved.mime.toLowerCase())) {
      return null;
    }
    return resolved;
  }

  /// Read-only extraction into scratch, 256-KiB chunks for stored blobs.
  /// The original ZIM is never written to or duplicated.
  Future<bool> extractLocalVideo(
    ZimEntry article, String reference, File scratch, {
    int maxVideoBytes = 256 * 1024 * 1024,
    bool Function()? cancelled,
  }) => _run(() async {
    if (maxVideoBytes <= 0 || maxVideoBytes > 256 * 1024 * 1024 ||
        !RegExp(r'\.(mp4|m4v|webm|ogv)$', caseSensitive: false)
            .hasMatch(reference)) return false;
    final media = await _localMediaAsset(article, reference, const {
      'video/mp4', 'video/webm', 'video/ogg', 'video/x-m4v',
    });
    if (media == null || cancelled?.call() == true) return false;
    final stored = await _storedBlobRange(media);
    final length = stored?.$2;
    if (length != null && (length < 1 || length > maxVideoBytes)) return false;
    var success = false;
    try {
      await scratch.parent.create(recursive: true);
      final output = await scratch.open(mode: FileMode.write);
      try {
        if (stored != null) {
          var offset = 0;
          while (offset < stored.$2) {
            if (cancelled?.call() == true) return false;
            final n = (stored.$2 - offset).clamp(0, 256 * 1024);
            final bytes = await _readAt(_file, stored.$1 + offset, n);
            if (bytes.length != n) {
              throw const FormatException('ZIM: truncated video');
            }
            await output.writeFrom(bytes);
            offset += n;
          }
        } else {
          // Current decompressor's existing 64-MiB limit still applies.
          final bytes = await _content(media);
          if (bytes.isEmpty || bytes.length > maxVideoBytes) return false;
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      success = cancelled?.call() != true;
      return success;
    } catch (_) {
      return false;
    } finally {
      if (!success && await scratch.exists()) await scratch.delete();
    }
  });

  /// Optional local SRT/VTT; do not load a large subtitle into memory.
  Future<String?> localSubtitle(
    ZimEntry article, String reference,
  ) => _run(() async {
    if (!RegExp(r'\.(srt|vtt)$', caseSensitive: false).hasMatch(reference)) {
      return null;
    }
    final media = await _localMediaAsset(article, reference, const {
      'text/vtt', 'text/plain', 'application/x-subrip',
      'application/octet-stream',
    });
    if (media == null) return null;
    final range = await _storedBlobRange(media);
    if (range != null && range.$2 > 1024 * 1024) return null;
    final bytes = await _content(media);
    return bytes.length > 1024 * 1024 ? null :
        utf8.decode(bytes, allowMalformed: true);
  });

  /// Presence only: using this embedded Xapian index requires a compatible
  /// search implementation; this reader does not treat it as searchable.
  Future<bool> hasEmbeddedFullTextIndex() => _run(
    () async =>
        await _findPath('X', 'fulltext/xapian') != null ||
        await _findPath('Z', '/fulltextIndex/xapian') != null,
  );

  Future<String?> metadata(String name) => _run(() async {
    final e = await _findPath('M', name);
    if (e == null) return null;
    final resolved = await _resolve(e);
    return resolved == null
        ? null
        : utf8.decode(await _content(resolved), allowMalformed: true);
  });
}

class _BoundedClusterOutput extends OutputMemoryStream {
  final int limit;
  _BoundedClusterOutput(this.limit);
  void _check(int count) {
    if (count < 0 || count > limit - length) {
      throw const FormatException('ZIM: expanded cluster exceeds safety limit');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
