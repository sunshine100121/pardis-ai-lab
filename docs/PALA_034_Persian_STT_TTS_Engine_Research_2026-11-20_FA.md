# PALA 0.3.4 — تحقیق موتورهای گفتار فارسی و گسترش موتورهای آفلاین

**تاریخ:** ۲۰ نوامبر ۲۰۲۶. **شاخه:** `pala/integrated-034-2026-11-17`.

## دامنه تحقیق و احتیاط
- «پرمصرف‌ترین موتور در همه اپلیکیشن‌های ایران» را نمی‌توان از صفحات معرفی خدمات یا تعداد ستاره GitHub استنتاج کرد. آمار باز و حسابرسی‌شده سهم استفاده در اپ‌های ایرانی یافت نشده است؛ نتیجه این سند **ارزیابی کاربرد و امکان‌پذیری فنی** است، نه رتبه‌بندی سهم بازار.
- معیارهای اجرایی: فارسی واقعی؛ آفلاین کامل؛ بدون اشتراک/API؛ Android ARM64 روی Tab S10 Ultra با RAM 12 GB؛ استقلال STT و TTS؛ انتخاب/حذف توسط مالک؛ عدم بارگیری اجباری؛ عدم دست‌زدن به Qwen GGUF/ZIM و داده‌های PALA.
- STT آفلاین شناخته‌شده: Vosk (مدل‌های کوچک و بزرگ)، خانواده ایرانی Shenava/Rizeh/Koochik ONNX بر sherpa-onnx. Whisper فارسی پیش‌تر روی تبلت نتیجه ضعیف داشته و Android Offline STT روی تبلت فارسی را پشتیبانی نکرده است؛ هیچ‌کدام جایگزین خودکار نشوند.
- TTS: Piper/VITS فارسی (fa_IR-gyro-medium، fa_IR-amir-medium، fa_IR-ganji-medium، ...)، موتور سیستم Android HayaiTTS، AvaCore و eSpeak در صورت نصب؛ بعضی سیستم‌ها از eSpeak NG داخلی استفاده می‌کنند، بعضی صدای عصبی با sherpa-onnx.
- فارس‌آوا، نویسا و سایر APIهای تشخیص گفتار و تولید صدای فارسیِ ابری ممکن است در محصولات ایرانی استفاده شوند، اما بدون اینترنت مستقل نیستند. این مأموریت هیچ سرویس خارجی را فعال نمی‌کند.

## منابع اولیه و قابل ردیابی
- مدل اصلی Shenava Rizeh (NeMo FastConformer CTC، ONNX و tokens، 16 kHz): https://huggingface.co/Reza2kn/Shenava-Rizeh-v1.0-sherpa-onnx
- Shenava Koochik: https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0-sherpa-onnx
- فهرست Piper فارسی در sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/piper/generate.py
- اجرای Piper با Sherpa در یک نمونه فارسی: https://huggingface.co/spaces/karim23657/Persian-TTS-sherpa/blob/main/app_utils.py
- HayaiTTS به عنوان موتور Android TTS با رابط سیستمی و مدل‌های مختلف: https://github.com/HayaiApp/HayaiTTS
- AvaCore: https://github.com/PlayFoundryHQ/AvaCore
- کتابخانه Android Persian TTS: https://github.com/am3n/PersianTTS
- API واقعی این پروژه: sherpa_onnx 1.13.8 در pubspec و `flutter/sherpa_onnx/lib/src/offline_recognizer_config.dart`، `tts_config.dart`، `offline_recognizer.dart`، `tts.dart` در https://github.com/k2-fsa/sherpa-onnx

## پیاده‌سازی این شاخه
۱. **Vosk** حفظ و پشتیبانی مدل‌های متعدد ادامه یافته است. مسیر موجود Android TTS از قبل به طور پویا موتور نصب‌شده مانند HayaiTTS/AvaCore را شناسایی می‌کند؛ اما **نصب بودن هیچ‌یک روی تبلت از GitHub قابل اثبات نیست**.
۲. **Shenava / NeMo-CTC** به عنوان آداپتور واقعی `sherpa-ctc` روی sherpa_onnx موجود: کاربر ZIP/TAR.BZ2 سازگار را وارد می‌کند؛ در پوشه اختصاصی ذخیره می‌شود؛ محتوای صوتی از میکروفون 16 kHz به recognizer در worker isolate می‌رود، نتیجه نهایی غیرخالی به Qwen می‌رسد. متن خروجی ممکن است برای نشانه‌گذاری/اعداد نیازمند postprocessing باشد؛ کیفیت باید آزمایش شود.
۳. **Piper / VITS** به عنوان آداپتور واقعی `tts:piper` روی sherpa_onnx موجود: بسته مدل با `tokens.txt` و `espeak-ng-data/phontab` بررسی می‌شود؛ مدل در worker جداگانه PCM تولید می‌کند و از VoiceAudioChannel پخش می‌شود. صدای فعال از TTS مستقل از انتخاب STT است.
۴. بسته‌ها فقط با اقدام مالک وارد می‌شوند، با حد حجم و مقابله با مسیرهای ناامن؛ فایل اصلی مدل‌ها و اطلاعات قبلی حذف یا جابه‌جا نمی‌شود. SHA256 برای شناسه محتوا محاسبه می‌شود **ولی بدون هش مورد اعتمادِ ناشر اصالت دانلود را اثبات نمی‌کند**. برای انتشار عمومی باید مجوز هر مدل و داده آموزشی آن جداگانه بازبینی شود.
۵. مدل‌هایی با فرمت دیگر، از جمله Shenava RNNT (encoder/decoder/joiner)، Pocket Farsi، موتور TTS مستقل و غیر Android با پروتکل متفاوت، **به آداپتور جدا نیاز دارند**. صرف نام‌بردن از موتور به معنی پشتیبانی نیست.

## معیارهای آزمون
- CI: سازگاری فایل تنظیمات محافظت‌شده، قالب‌بندی Dart، Flutter analyze، آزمون پکیج ZIP امن و مدل، آزمون config واقعی sherpa، رگرسیون‌های برنامه و کامپایل Android بدون APK.
- **آزمون عملی Galaxy Tab S10 Ultra همچنان الزامی:** دانلود مدل فقط با اقدام مالک، بسته کامل و مستند، اینترنت قطع، گفتار محاوره‌ای فارسی و انتقال متن به Qwen، صدای Piper/Android TTS، مصرف RAM و پایداری UI. وجود فایل ONNX و قبولی CI به معنی صحت تشخیص یا طبیعی بودن صدای خروجی روی دستگاه نیست.
- برنامه اصلی 0.3.3+6، شاخه main، امضا، داده‌های کاربر، Qwen/ZIM و سامانه HA/PVM دست‌نخورده‌اند.
