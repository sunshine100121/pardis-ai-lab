import '../knowledge/folder_library.dart';

/// Chooses ONLY owner-enabled local files. The question never grants access
/// to a disabled or project-private source. Generic questions remain broad;
/// specialist questions avoid unrelated large PDFs and ZIM archives.
class ZimMultilingualSourceRoute {
  final Set<String>? sourceIds;
  final bool exclusive;
  final bool missingOrAmbiguous;
  final String? requestedFile;

  const ZimMultilingualSourceRoute({
    required this.sourceIds,
    this.exclusive = false,
    this.missingOrAmbiguous = false,
    this.requestedFile,
  });

  static bool _isZim(String filename) =>
      filename.toLowerCase().endsWith('.zim');
  static bool _isPdf(String filename) =>
      filename.toLowerCase().endsWith('.pdf');

  static ZimMultilingualSourceRoute choose(
    String question,
    Map<String, dynamic> libraryState, {
    Set<String>? projectAllowed,
  }) {
    final all =
        (libraryState['files'] is List
                ? libraryState['files'] as List
                : const <dynamic>[])
            .whereType<Map>()
            .where(
              (row) =>
                  row['enabled'] == true &&
                  row['uri'] is String &&
                  row['name'] is String &&
                  (projectAllowed == null ||
                      projectAllowed.contains(
                        FolderLibrary.sourceId(row['uri'] as String),
                      )),
            )
            .toList();
    String name(Map row) => (row['name'] as String).toLowerCase();
    String id(Map row) => FolderLibrary.sourceId(row['uri'] as String);

    final q = question.toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک');
    final restrictiveWords = RegExp(
      r'\bonly\b|\bexclusively\b|\bdo not use\b|\bdo not search\b|فقط|صرفاً|صرفا|منحصراً|منحصرا',
      caseSensitive: false,
    ).hasMatch(q);
    final mentionsArchive = RegExp(
      r'\.zim\b|\barchive\b|\bencyclopedia\b|\bwikivoyage\b|\bgardening stack exchange\b|دانشنامه|ویکی.?سفر',
      caseSensitive: false,
    ).hasMatch(q);
    // "Only answer briefly" or "only two days" is not a source restriction.
    final only = restrictiveWords && mentionsArchive;
    // Explicit source requests require an unambiguous exact filename or a
    // recognizable named archive. Never guess a source from a general noun.
    final filenames = RegExp(
      r'[a-z0-9_.-]+\.zim\b',
      caseSensitive: false,
    ).allMatches(q).map((m) => m.group(0)!).toSet();
    final specified = <Map>[];
    if (filenames.isNotEmpty) {
      for (final row in all) {
        if (filenames.contains(name(row))) specified.add(row);
      }
    } else if (only &&
        RegExp(
          r'\b(gardening stack exchange|gardening\.stackexchange)\b|دانشنامه.{0,20}باغبانی',
        ).hasMatch(q)) {
      specified.addAll(
        all.where(
          (row) =>
              _isZim(name(row)) &&
              name(row).contains('gardening.stackexchange'),
        ),
      );
    } else if (only &&
        RegExp(r'\b(wikivoyage|ویکی سفر|ویکی‌سفر)\b').hasMatch(q)) {
      specified.addAll(
        all.where(
          (row) => _isZim(name(row)) && name(row).contains('wikivoyage'),
        ),
      );
    } else if (only &&
        RegExp(r'\b(raspberrypi stack exchange|raspberrypi\.stackexchange)\b')
            .hasMatch(q)) {
      specified.addAll(
        all.where(
          (row) =>
              _isZim(name(row)) &&
              name(row).contains('raspberrypi.stackexchange'),
        ),
      );
    }
    if (only) {
      final unique = specified.map(id).toSet();
      return ZimMultilingualSourceRoute(
        sourceIds: unique.length == 1 ? unique : <String>{},
        exclusive: true,
        missingOrAmbiguous: unique.length != 1,
        requestedFile: filenames.isEmpty
            ? null
            : filenames.length == 1
            ? filenames.single
            : null,
      );
    }

    // For nonexclusive requests, a precisely named file is preferred but
    // general knowledge can still be supplied from other allowed sources.
    // A ZIM phrase without ONLY never silently widens permissions.
    final garden = RegExp(
      r'باغ|درخت|بذر|قلمه|گردو|بادام|انجیر|سرمازدگی|یخبندان|هرس|آبیاری|کاشت|soil|fig|almond|walnut|frost|gardening|horticultur|plant|orchard|irrigat',
      caseSensitive: false,
    ).hasMatch(q);
    final travel = RegExp(
      r'سفر|گردشگر|گردشگری|جاذبه|اقامت|اصفهان|شیراز|isfahan|esfahan|shiraz|travel|touris|sightsee|attraction|itinerary|visit',
      caseSensitive: false,
    ).hasMatch(q);
    final ha = RegExp(
      r'home assistant|هوم اسیستنت|هوم‌اسیستنت|خانه هوشمند|zigbee|z2m|raspberry ?pi|دریمی|dreame|سنسور|sensor',
      caseSensitive: false,
    ).hasMatch(q);
    if (!garden && !travel && !ha) {
      // Generic questions should not be silently narrowed; preserve existing
      // source behavior and project isolation.
      return const ZimMultilingualSourceRoute(sourceIds: null);
    }
    final ids = <String>{};
    for (final row in all) {
      final n = name(row);
      final zim = _isZim(n), pdf = _isPdf(n);
      final specialist =
          (garden && n.contains('gardening.stackexchange')) ||
          (travel && n.contains('wikivoyage')) ||
          (ha &&
              (n.contains('raspberrypi.stackexchange') ||
                  n.contains('home_assistant') ||
                  n.contains('home assistant')));
      final broad =
          zim && n.contains('wikipedia_fa_all_') && (garden || travel);
      final relevantPdf =
          pdf &&
          ha &&
          (n.contains('home_assistant') || n.contains('home assistant'));
      if (specialist || broad || relevantPdf) ids.add(id(row));
    }
    // Do not expand a project scope by "discovering" an unrelated archive.
    // If no specialist exists, leave original search behavior intact.
    return ZimMultilingualSourceRoute(sourceIds: ids.isEmpty ? null : ids);
  }
}
