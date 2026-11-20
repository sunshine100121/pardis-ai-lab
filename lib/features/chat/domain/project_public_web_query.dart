import 'online_permission_policy.dart';

/// M13 extension: a deliberately conservative public-only query builder.
/// It never reads project instructions, notes, chat history, attachments or
/// Home Assistant state. Only words in a fixed public-topic vocabulary may
/// become part of an external request. Unknown names are not transmitted.
///
/// A false negative is intentional: users can rephrase a general topic
/// rather than silently send personal facts or identifiers to the internet.
abstract final class ProjectPublicWebQuery {
  static final _words = RegExp(r'[\p{L}]+', unicode: true);
  static final _identifiers = RegExp(
    r'https?://|www\.|@|(?:\d{1,3}\.){3}\d{1,3}|'
    r'(?:\b[A-Fa-f0-9]{24,}\b)',
    caseSensitive: false,
  );

  static const _topics = <String>{
    'روش', 'کنترل', 'مقابله', 'پیشگیری', 'درمان', 'تحقیقات', 'پژوهش',
    'علمی', 'آفات', 'آفت', 'بیماری', 'بیماریهای', 'برگ',
    'درخت', 'درختان', 'انار', 'انجیر', 'گردو', 'بادام', 'سیب', 'گلابی',
    'انگور', 'زیتون', 'پسته', 'گل', 'رز', 'ریحان', 'رزماری',
    'کنه', 'شته', 'قارچ', 'سفیدک', 'آبیاری', 'قطره', 'رطوبت',
    'خاک', 'کود', 'کوددهی', 'هرس', 'باغبانی', 'کشاورزی', 'گیاه',
    'گیاهان', 'آب', 'باران', 'بارندگی', 'هواشناسی', 'اقلیم',
    'یخبندان', 'خشکسالی', 'گرما', 'سرما',
    'یوگا', 'مدیتیشن', 'تنفس', 'مراقبه', 'فلسفه', 'سلامت',
    'تغذیه', 'گیاهخواری',
    'هوشمند', 'اتوماسیون', 'سنسور', 'حسگر', 'انرژی', 'برق',
    'باتری', 'خورشیدی', 'اینورتر', 'زیگبی', 'متر', 'وات',
    'نرم', 'افزار', 'نسخه', 'اپلیکیشن', 'اندروید', 'تبلت',
    'فلاتر', 'flutter', 'python', 'qwen', 'home', 'assistant',
    'zigbee', 'matter', 'mqtt', 'bluetooth', 'wifi',
    'قیمت', 'بازار', 'اخبار', 'اقتصاد', 'فناوری', 'هوش',
    'مصنوعی', 'ایران', 'جهان',
  };

  static const _qualifiers = <String>{
    'جدیدترین', 'آخرین', 'امروز', 'فردا', 'بهترین',
    'تازه', 'راهنمای', 'راهنما', 'معتبر', 'مقایسه',
    'latest', 'recent', 'best', 'guide', 'research',
  };

  static String? fromMessage(String message) {
    if (message.trim().isEmpty ||
        message.length > 500 ||
        OnlinePermissionPolicy.privateContent(message) ||
        _identifiers.hasMatch(message)) {
      return null;
    }
    final normalized = message
        .toLowerCase()
        .replaceAll('ي', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll('\u200c', ' ');
    final chosen = <String>[];
    var publicTopicCount = 0;
    for (final match in _words.allMatches(normalized)) {
      final word = match.group(0)!;
      if (!_topics.contains(word) && !_qualifiers.contains(word)) continue;
      if (chosen.contains(word)) continue;
      chosen.add(word);
      if (_topics.contains(word)) publicTopicCount++;
    }
    // At least two independent public topic terms are needed. A bare
    // "search about my garden" or unknown proper noun is not a search grant.
    if (publicTopicCount < 2) return null;
    return chosen.take(12).join(' ');
  }
}
