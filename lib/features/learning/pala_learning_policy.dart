/// M19: deterministic, local-only matching of an OWNER-confirmed correction.
/// This is not fine-tuning and never asserts the correction is universal truth.
abstract final class PalaLearningPolicy {
  static const minSimilarity = 0.82;

  static final _forbidden = RegExp(
    r'https?://|www\.|(?:password|passphrase|api.key|bearer|token|secret|'
    r'credit.card|bank.account|medical|diagnos|prescript|suicid|'
    r'location|address|gps|ssh|sudo|rm\s+-rf|'
    r'رمز|پسورد|گذرواژه|توکن|کلید\s*خصوصی|شماره\s*حساب|کارت\s*بانکی|'
    r'آدرس\s*خانه|نشانی|کد\s*ملی|نسخه\s*پزشکی|دارو|خودکشی|'
    r'اتصال\s*برق|ولتاژ|اینورتر|باتری|درب\s*پارکینگ|قفل|'
    r'روشن\s*کن|خاموش\s*کن|باز\s*کن|حذف\s*کن|'
    r'قیمت|نرخ\s*ارز|بورس|اخبار|آب\s*و\s*هوا|'
    r'امروز|فردا|دیروز|الان|اکنون|فعلی|سنسور|حسگر|'
    r'مخزن\s*آب|home\s*assistant|entity_id)',
    caseSensitive: false,
    unicode: true,
  );
  static final _instruction = RegExp(
    r'(?:ignore\s+previous|system\s+prompt|developer\s+message|'
    r'بخش\s*سیستم|دستور\s*قبلی\s*را\s*نادیده|پرامپت\s*سیستم|'
    r'دسترسی\s*نامحدود|بدون\s*تأیید|اجرا\s*کن)',
    caseSensitive: false,
    unicode: true,
  );

  static String normalize(String input) => input
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('ۀ', 'ه')
      .replaceAll('\u200c', ' ')
      .replaceAll(RegExp(r'[\u064b-\u065f\u0670]'), '')
      .replaceAll(RegExp(r'[^a-z0-9آ-ی\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static const _stop = <String>{
    'چیست',
    'چیه',
    'است',
    'هست',
    'هستن',
    'بود',
    'شد',
    'میشه',
    'می',
    'شود',
    'در',
    'به',
    'از',
    'با',
    'که',
    'را',
    'روی',
    'رویی',
    'یک',
    'این',
    'آن',
    'چه',
    'هم',
    'چند',
    'برای',
    'های',
    'ها',
  };

  static Set<String> terms(String question) {
    final out = <String>{};
    for (var word in normalize(question).split(' ')) {
      if (word.isEmpty || _stop.contains(word)) continue;
      if (word == 'چرا') word = 'علت';
      if (word.endsWith('های') && word.length > 5) {
        word = word.substring(0, word.length - 3);
      } else if (word.endsWith('ها') && word.length > 4) {
        word = word.substring(0, word.length - 2);
      }
      if (!_stop.contains(word) && word.length > 1) out.add(word);
    }
    return out;
  }

  static double similarity(String first, String second) {
    if (normalize(first) == normalize(second)) return 1;
    final a = terms(first), b = terms(second);
    if (a.length < 3 || b.length < 3) return 0;
    final common = a.intersection(b).length;
    if (common < 3) return 0;
    return common / a.union(b).length;
  }

  static bool safe({required String question, required String correction}) {
    final q = question.trim(), c = correction.trim();
    if (q.length < 12 ||
        q.length > 240 ||
        c.length < 10 ||
        c.length > 450 ||
        terms(q).length < 3)
      return false;
    if (_forbidden.hasMatch(q) ||
        _forbidden.hasMatch(c) ||
        _instruction.hasMatch(q) ||
        _instruction.hasMatch(c))
      return false;
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(q + c)) {
      return false;
    }
    return true;
  }

  static bool eligibleQuestion(String question) =>
      question.length >= 12 &&
      question.length <= 240 &&
      terms(question).length >= 3 &&
      !_forbidden.hasMatch(question) &&
      !_instruction.hasMatch(question);
}
