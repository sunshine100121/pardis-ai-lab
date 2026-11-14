import '../../data/network/web_search/search_models.dart';

/// Application-owned retrieval facts; never model-written citations or prose.
class KnowledgeReadReport {
  final List<SearchResult> sources;
  final List<Map<String, dynamic>> checks;
  const KnowledgeReadReport(this.sources, this.checks);

  Map<String, dynamic> toJson({required bool requiredEncyclopedia, required bool supplied}) => {
    'version': 1, 'requiredEncyclopedia': requiredEncyclopedia,
    'supplied': supplied, 'checks': checks,
  };

  static String stageLabel(String stage) => const {
    'open':'بازکردن آرشیو و فهرست عنوان', 'title':'جست‌وجوی عنوان',
    'content':'خواندن مقاله', 'metadata':'خواندن مشخصات دانشنامه',
    'extract':'استخراج متن', 'complete':'متن مقاله آماده شد',
    'text_unusable':'متن مقاله قابل استفاده نبود', 'access':'دسترسی پوشه',
  }[stage] ?? 'بررسی منبع';

  static String checkLabel(Map<String, dynamic> check) {
    final reason = switch(check['code']) {
      'found' => 'مقاله بازیابی شد: ${check['article']}',
      'not_found' => 'عنوان مطابق پیدا نشد؛ این جست‌وجوی عنوان است، نه متن کامل دانشنامه',
      'text_unusable' => 'عنوان پیدا شد اما متن کافی و قابل استفاده استخراج نشد',
      'timeout' => 'مهلت خواندن در مرحله «${stageLabel('${check['stage']}')}» تمام شد',
      'format' => 'ساختار، فشرده‌سازی یا محدودهٔ ایمنی خواننده با این بخش سازگار نیست',
      'changed' => 'فایل جابه‌جا یا تغییر کرده؛ بازخوانی منابع لازم است',
      'limit' => 'سقف هشت دانشنامهٔ فعال پر شده است',
      _ => 'دسترسی یا خواندن منبع ناموفق بود؛ مجوز و خواندن تصادفی را بررسی کنید',
    };
    return '${check['file'] ?? 'پوشه دانش'}: $reason';
  }

  static String summary(Map<String,dynamic> report) {
    if(report['delivery']=='context_limit') {
      return 'وضعیت منبع — مقاله بازیابی شد اما متن آن در ظرفیت ورودی جا نشد و به مدل داده نشد؛ پاسخ مستند به این مقاله تأیید نشده است.';
    }
    if (report['supplied'] == true) {
      return 'وضعیت منبع — متن واقعی دانشنامه به مدل داده شد؛ این به‌تنهایی درستی پاسخ مدل را تضمین نمی‌کند.';
    }
    return report['requiredEncyclopedia'] == true
      ? 'وضعیت منبع — مقالهٔ قابل‌استناد به مدل داده نشد؛ پاسخ مستند تولید نشد.'
      : 'وضعیت منبع — شاهد دانشنامه‌ای به مدل داده نشد؛ پاسخ احتمالی مدل از این دانشنامه تأیید نشده است.';
  }
}
