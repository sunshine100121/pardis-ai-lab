import 'online_permission_policy.dart';

/// M13: project-safe public query builder, without a subject vocabulary.
/// Questions about any public subject can be searched in Persian, English or
/// other languages; no project notes, instructions, attachments or chat history
/// are ever inputs to this function.
///
/// The current user message is still checked for credentials/private location.
/// When a personal reference cannot be removed safely, the request is denied
/// rather than turning private project context into a public search query.
abstract final class ProjectPublicWebQuery {
  static final _url = RegExp(r'https?://[^\s<>"\)\]]+', caseSensitive: false);
  static final _email = RegExp(
    r'[A-Za-z0-9_.%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  );
  static final _ip = RegExp(
    r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])',
  );
  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static final _privateReference = RegExp(
    r'(?<![\p{L}])(?:آدرس|نشانی|موقعیت|مختصات|کد پستی|پلاک|'
    r'نام واقعی|نام کامل|شماره تلفن|شماره موبایل|کدملی|'
    r'شخصی(?:ت)?|محرمانه|خصوصی|private address|home address)'
    r'(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );
  static final _ownerContext = RegExp(
    r'(?:(?:در|برای|از|به|داخل)\s+)?'
    r'(?:باغ|خانه|ویلا|ملک|پروژه|اتاق)\s+'
    r'(?:(?:شخصی|اختصاصی)\s+)?'
    r'(?:من|ما|خودم|خودمان)(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );
  static final _englishOwnerContext = RegExp(
    r'\b(?:my|our|personal|private)\s+'
    r'(?:home|house|garden|project|villa|room|property)\b',
    caseSensitive: false,
  );
  static final _projectClause = RegExp(
    r'(?:(?:در|داخل|توی)\s+)?پروژه\s+[^،,؛;\n]{1,120}[،,؛;]\s*',
    caseSensitive: false,
    unicode: true,
  );
  static final _searchWords = RegExp(
    r'(?:(?:در|از طریق)\s+)?(?:اینترنت|وب|آنلاین)'
    r'|جست[‌ ]?وجو|جستجو|سرچ|بگرد|بگردید|بگردیم'
    r'|search|browse|look up|find online',
    caseSensitive: false,
    unicode: true,
  );
  static final _instructions = RegExp(
    r'(?<![\p{L}])(?:کن|کنید|بکن|بکنید|لطفا|لطفاً|'
    r'برام|برایم|لطفا|لطفاً|لطفاً)\s*',
    caseSensitive: false,
    unicode: true,
  );
  static final _filler = {
    'در', 'از', 'به', 'برای', 'را', 'و', 'با', 'من',
    'ما', 'این', 'آن', 'درباره', 'مورد', 'یک', 'چند',
    'آیا', 'چه', 'هست', 'است', 'کن', 'کنید', 'لطفا',
    'درمورد', 'اطلاعات', 'please', 'the', 'and',
    'in', 'on', 'for', 'my', 'our', 'about',
  };

  static String normalize(String input) => input
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _sensitive(String input) =>
      OnlinePermissionPolicy.privateContent(input) ||
      _email.hasMatch(input) ||
      _ip.hasMatch(input) ||
      _privateReference.hasMatch(input);

  /// Returns a safe, useful search query or null. No fixed subject list:
  /// specialist terms, software names, media, models and years survive.
  static String? fromMessage(
    String message, {
    String projectName = '',
  }) {
    if (message.trim().isEmpty ||
        message.length > 550 ||
        _url.hasMatch(message) ||
        _sensitive(message)) {
      return null;
    }
    var q = normalize(message);
    if (projectName.trim().isNotEmpty) {
      // A project's private title is never part of an outbound search.
      q = q.replaceAll(
        RegExp(RegExp.escape(normalize(projectName)), caseSensitive: false),
        ' ',
      );
    }
    q = q.replaceAll(_projectClause, ' ');
    q = q.replaceAll(_ownerContext, ' ');
    q = q.replaceAll(_englishOwnerContext, ' ');
    q = q.replaceAll(_searchWords, ' ');
    q = q.replaceAll(_instructions, ' ');
    q = q.replaceAll(RegExp(r'[\n\r\t،,؛;:!؟?"«»]+'), ' ');
    q = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.length < 5 || q.length > 240 || _sensitive(q)) return null;
    final meaningfulWords = [
      for (final m in _word.allMatches(q.toLowerCase()))
        if (!_filler.contains(m.group(0)!)) m.group(0)!,
    ];
    // "Search online" / "look up my project" cannot become a query.
    if (meaningfulWords.length < 2) return null;
    return q;
  }

  /// Public links pasted by the owner may be opened directly in project
  /// chats. The existing WebPageReader then validates every DNS address and
  /// redirect, preventing access to HA/LAN, localhost and private hosts.
  static bool publicUrlsFromMessage(String message, List<Uri> urls) {
    if (urls.isEmpty || urls.length > 3 ||
        message.length > 1000 || _sensitive(message)) return false;
    for (final url in urls) {
      if (url.scheme != 'https' ||
          url.host.isEmpty ||
          !url.host.contains('.') ||
          url.userInfo.isNotEmpty ||
          url.port != 443 ||
          _ip.hasMatch(url.host) ||
          url.host.endsWith('.local') ||
          url.host.endsWith('.lan') ||
          url.host.endsWith('.internal') ||
          url.host.endsWith('.home') ||
          url.host.endsWith('.localhost') ||
          url.host == 'localhost' ||
          OnlinePermissionPolicy.privateContent(url.toString()) ||
          !message.contains(url.toString())) {
        return false;
      }
    }
    return true;
  }
}
