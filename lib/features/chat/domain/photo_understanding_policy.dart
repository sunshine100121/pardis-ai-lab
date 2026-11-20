import 'dart:io';

import 'package:path/path.dart' as p;
import '../../attachments/domain/attachment.dart';

/// M17: keeps photos on the existing local model and attachment path.
/// No model, image encoder or cloud API is installed by this policy.
abstract final class PhotoUnderstandingPolicy {
  static const maxPhotosPerTurn = 2;
  static const maxPhotoBytes = 8 * 1024 * 1024;
  static const maxCombinedBytes = 12 * 1024 * 1024;
  // An advisory stop condition; the Android value is available RAM rather
  // than app RSS, and is not a reliable prediction of projector peak memory.
  static const minAvailableRamBytes = 1200 * 1024 * 1024;

  static bool isImportedQwen35FourB({
    required String? architecture,
    required int? parameterCount,
  }) {
    final arch = (architecture ?? '').toLowerCase().replaceAll('-', '_');
    return (arch == 'qwen35' || arch == 'qwen3_5') &&
        parameterCount != null &&
        parameterCount >= 3500000000 &&
        parameterCount <= 4800000000;
  }

  /// Check the *loaded runtime*, not mere presence of an mmproj on disk.
  static bool hasActiveVision({
    required bool locallyLoaded,
    required bool engineReportsVision,
    required bool projectorReadyOnDisk,
  }) => locallyLoaded && engineReportsVision && projectorReadyOnDisk;

  static String? refusal({
    required List<Attachment> attachments,
    required bool visionAvailable,
    bool remoteOutsideLan = false,
    int? availableRamBytes,
  }) {
    final photos = attachments.where((a) => a.isImage).toList();
    if (photos.isEmpty) return null;
    if (remoteOutsideLan) {
      return 'برای حفظ حریم خصوصی، عکس در این مرحله فقط به Qwen محلی '
          'یا تبلت جفت‌شده در شبکه داخلی ارسال می‌شود؛ '
          'هیچ تصویر خصوصی به سرور بیرونی فرستاده نشد.';
    }
    if (!visionAvailable) {
      return 'این مدل در وضعیت فعلی تصویر را نمی‌بیند. '
          'برای تحلیل عکس، قابلیت بینایی مدل و فایل سازگار آن باید یک‌بار '
          'فعال و واقعاً بارگذاری شوند. OCR فقط متن داخل عکس را می‌خواند '
          'و جای تشخیص محتوای تصویر را نمی‌گیرد. '
          'فعلاً از روی عکس تشخیص یا نتیجه‌گیری نمی‌کنم.';
    }
    if (photos.length > maxPhotosPerTurn) {
      return 'برای حفظ حافظه و کیفیت تحلیل، حداکثر دو عکس را در هر '
          'پرسش انتخاب کنید؛ فایل‌های قبلی پاک نشده‌اند.';
    }
    final sizes = photos.map((a) => a.sizeBytes).toList();
    if (sizes.any((size) => size < 1 || size > maxPhotoBytes) ||
        sizes.fold<int>(0, (sum, size) => sum + size) > maxCombinedBytes) {
      return 'حجم عکس‌های انتخاب‌شده برای تحلیل محلی زیاد است. '
          'عکس کوچک‌تری انتخاب کنید؛ هیچ فایلی حذف نشده است.';
    }
    if (photos.any((a) => a.mime != 'image/png' ||
        p.extension(a.path).toLowerCase() != '.png')) {
      return 'عکس با قالب موردانتظار آماده نشده است. '
          'آن را دوباره از دوربین یا گالری اضافه کنید.';
    }
    if (availableRamBytes != null &&
        availableRamBytes >= 0 &&
        availableRamBytes < minAvailableRamBytes) {
      return 'حافظه آزاد تبلت برای شروع تحلیل تصویر کم است. '
          'برای جلوگیری از بسته‌شدن برنامه، تحلیل آغاز نشد؛ '
          'پس از آزادشدن حافظه دوباره امتحان کنید.';
    }
    return null;
  }

  /// Small, privacy-safe performance evidence for a REAL on-device turn.
  /// Missing OS data must stay missing, never interpreted as 0 MB.
  static Map<String, Object> numericResourceEvidence({
    required int photoCount,
    required bool visionActive,
    int? ramFreeBeforeBytes,
    int? ramFreeAfterBytes,
  }) => <String, Object>{
    'visionActive': visionActive,
    'visionPhotoCount': photoCount,
    if (ramFreeBeforeBytes != null && ramFreeBeforeBytes > 0)
      'visionRamFreeBeforeMb': ramFreeBeforeBytes / (1024 * 1024),
    if (ramFreeAfterBytes != null && ramFreeAfterBytes > 0)
      'visionRamFreeAfterMb': ramFreeAfterBytes / (1024 * 1024),
  };

  /// Existing AttachmentStore has already normalized owner-selected photos.
  /// Do not let an old/tampered attachment silently reach a native engine.
  static Future<String?> verifyLocalFiles(
    List<Attachment> attachments, {
    required Directory attachmentDirectory,
  }) async {
    final base = await attachmentDirectory.resolveSymbolicLinks();
    for (final a in attachments.where((a) => a.isImage)) {
      try {
        final f = File(a.path);
        if (!await f.exists()) {
          return 'فایل عکس در دسترس نیست؛ آن را دوباره اضافه کنید.';
        }
        final realPath = await f.resolveSymbolicLinks();
        if (p.normalize(p.dirname(realPath)) != p.normalize(base) ||
            await f.length() != a.sizeBytes) {
          return 'فایل عکس با نسخه انتخاب‌شده تطابق ندارد؛ '
              'برای حفاظت از اطلاعات، تحلیل انجام نشد.';
        }
      } catch (_) {
        return 'خواندن عکس تأیید نشد؛ هیچ تحلیلی انجام نشد.';
      }
    }
    return null;
  }

  /// App instruction after the pixels were actually made available.
  /// Image evidence and local reference documents have distinct provenance.
  static const instruction = '''

تحلیل تصویری فارسی، فقط وقتی پیکسل‌های تصویر واقعاً به موتور رسیده‌اند:
۱. ابتدا فقط آنچه با وضوح در تصویر دیده می‌شود توصیف کن؛ میان مشاهده، احتمال و حدس تفاوت بگذار.
۲. پرسش کاربر را به فارسی طبیعی پاسخ بده. نام گونه گیاه، آفت، بیماری، قطعه الکتریکی، عیب یا خطر را با یک تصویرِ ناکافی قطعی اعلام نکن؛ اگر لازم است عکس زاویه دیگر، نشانه‌ها یا داده حسگر درخواست کن.
۳. در تشخیص برگ گیاه، آسیب مکانیکی/نور/آبیاری و بیماری را به‌عنوان احتمال‌های متفاوت در نظر بگیر، نه تشخیص پزشکی یا سم‌پاشی قطعی. برای تجهیزات برقی یا باتری، دستور عملی پرخطر و تعمیر بدون اندازه‌گیری و تأیید ارائه نکن.
۴. OCR ممکن است متن و اعداد را اشتباه بخواند؛ هرگز محتوای OCR را با مشاهده بصری تأییدشده یکی ندان.
۵. اگر دانشنامه تخصصی محلی یا منبع معتبر بازیابی شده است، فقط همان متن را به‌عنوان منبع نظری نقل کن؛ منبع عمومی به‌تنهایی اثبات نمی‌کند عکس همین مشکل را نشان می‌دهد. در نبود منبع، ارجاع ساختگی نده.
۶. اگر تصویر تار، ناقص یا نامفهوم است، صریح بگو «با این تصویر قابل تأیید نیست» و یک گام کم‌خطر پیشنهاد کن.
''';
}
