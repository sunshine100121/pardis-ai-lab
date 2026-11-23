# Checkpoint یکپارچه PALA — مأموریت‌های ۰۱ تا ۰۶
تاریخ: ۲۳ نوامبر ۲۰۲۶ | پروژه: خانه هوشمند پردیس

## هدف
یکپارچه‌سازی اصلاحات مأموریت‌های ۱ تا ۵ و قابلیت جدید ویدئو/زیرنویس فارسی (مأموریت ۶)، آماده‌سازی تنها یک APK ارتقایی، بدون حذف اطلاعات یا نصب روی تبلت.

## شاخه و منشأ
- شاخه انتشار آزمایشی: `pala/integrated-m01-m06-tablet-2026-11-23`
- شاخه ویدئو: `pala/m06-zim-video-fa-captions-2026-11-23`
- مبنای مأموریت‌های ۱ تا ۵: `pala/m04-multilingual-source-routing-2026-11-22` و `docs/PALA_TABLET_ACCEPTANCE_CHECKLIST_M01_M05_2026-11-23_FA.md`.
- رابطه commitها در GitHub با مقایسه ancestor بررسی شد: M04 در تاریخچه M06 و M06 در تاریخچه شاخه تجمیع قرار دارد.
- نسخه کد: `0.3.4+7`، شناسه بسته `ir.pardis.ai.pala.f1diag2`، ARM64.
- مرجع کد دارای ۱۳۳ آزمون موفق: `54e6fc5c0fd00bdb18a0e853f5d171ff78e66b8a`.

## تغییرات
- رفع خطای نحوی ایجادشده هنگام ادغام در `zim_archive.dart` و `folder_library.dart` با بازسازی فایل‌های سالم مبنا و افزودن فقط توابع ویدئو.
- افزودن `video_player 2.14.1` و پنج بسته وابسته؛ سایر پکیج‌ها/هش‌های قفل‌شده حفظ شدند. تغییر نسخه SDK در lock با `pubspec.yaml` هم‌راستا شد.
- حفظ کنترل محافظتی `scripts/check_offline_baseline.py`؛ فقط استثنای دقیق و قابل‌مقایسه برای پنج بسته رسانه‌ای و نسخه SDK ایجاد شد. مدل، ذخیره‌سازی، native bridge و مجوزهای کنترل دست‌نخورده‌اند.
- کش زیرنویس با شناسه منبع و نسخه فایل ZIM مرتبط می‌شود؛ پردازش ویدئو نیازمند انتخاب کاربر و ASR/Qwen محلی است؛ ادعای هم‌ترازی دقیق کلمات وجود ندارد.
- فایل موقت ویدئو پس از خروج از پخش حذف می‌شود؛ فایل اصلی ZIM کپی یا ویرایش نمی‌شود.

## شواهد CI
- اجرای اولیه `45231784017`: توقف در formatter به علت خرابی ساختاری فایل ZIM.
- اجرای دوم `45232170526`: اصلاح خطا؛ توقف در کنترل قدیمی قفل وابستگی.
- اجرای سوم `45232696465`: **تحلیل کامل Flutter PASS، کنترل محافظتی PASS، ۱۳۳ آزمون PASS**؛ کامپایل Android Host به علت محدودیت HTTP 429 Maven متوقف شد؛ APK ساخته نشد.
- اجرای `45233881644`: مسیر محدود به تأیید همان commit آزمون‌شده، کامپایل بومی، امضای موجود و یک ساخت APK. در آخرین مشاهده: تطابق کد PASS، Android Host PASS، preflight کلید امضای مالک PASS، مرحله ساخت APK **IN_PROGRESS**؛ در زمان ثبت سند هنوز نتیجه نهایی امضا/Artifact و دستگاه موجود نیست.
- لینک: https://github.com/sunshine100121/pardis-ai-lab/actions/runs/45233881644

## ممنوعیت‌ها و گیت نصب
- هنوز هیچ نصب، Uninstall، Clear Data/Cache، تغییر فایل مدل Qwen، حذف فایل ZIM، تغییر Home Assistant یا اعمال فرمان کنترلی رخ نداده است.
- موفقیت CI حتی در صورت تولید APK، به معنی آزمایش واقعی Galaxy Tab S10 Ultra نیست.
- پیش از نصب باید نسخه و امضای برنامه موجود، بکاپ قابل‌بازیابی، فضای آزاد، حفظ مدل و دانشنامه و روش بازگشت رو به جلو با `versionCode` بالاتر بررسی شوند.
- APK فقط در صورت موفقیت مرحله verification و وجود فایل با SHA256 و امضای مالک قابل معرفی به مالک است؛ نصب فقط پس از اجازه و کنترل واقعی مالک.
- آزمون‌های دستگاه طبق `docs/PALA_TABLET_ACCEPTANCE_CHECKLIST_M01_M05_2026-11-23_FA.md` و `docs/PALA_M06_ZIM_VIDEO_PERSIAN_CAPTIONS_CHECKPOINT_2026-11-23_FA.md` انجام شوند.

## وضعیت نهایی هنگام ثبت
SOURCE_INTEGRATED=YES
DART_ANALYZE=PASS
INTEGRATED_TESTS=133_PASS
ANDROID_HOST=PASS (retry)
OWNER_SIGNER_PREFLIGHT=PASS
SIGNED_APK=IN_PROGRESS
TABLET_BACKUP_AND_ROLLBACK=NOT_VERIFIED
TABLET_INSTALL_AND_REAL_ACCEPTANCE=NOT_DONE
