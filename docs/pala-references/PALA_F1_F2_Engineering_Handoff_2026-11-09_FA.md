# پالا — دستور کار فنی مرحله F1/F2

**تاریخ:** ۹ نوامبر ۲۰۲۶  
**وضعیت:** بررسی و طرح اجرای مهندسی آماده؛ تغییر کد/Build/آزمون روی دستگاه انجام نشده است.  
**هدف:** اثبات دو شرط پذیرش پالا با کمترین ساخت آزمایشی و بدون آسیب به اطلاعات موجود.

## ۱. تصمیم‌های جدید مالک

- تنها دو شرط ادامه خود برنامه پالا: (F1) میزبانی Qwen روی تبلت با نمایشگر واقعاً خاموش و پاسخ به موبایل در LAN؛ (F2) استفاده مستند و آفلاین از فایل بزرگ ویکی‌پدیای فارسی، ترجیحاً بدون کپی.
- شنود دائمی میکروفون تبلت لازم نیست. ورودی صوتی از موبایل/ساعت و مسیر PVM می‌آید.
- TTS فارسی دستگاه مقصد و داشبورد Home Assistant / DeX وظایف مستقل‌اند و نباید باعث پیچیده‌ترشدن توسعه پالا شوند.
- عدم استفاده از API پولی، اینترنت ضروری، تغییر HA/PVM، دست‌کاری توکن‌ها و نصب جایگزین روی نسخه سالم.

## ۲. وضع موجود و یافته‌های تازه

- Fork عمومی `sunshine100121/pardis-ai-lab`، برنامه ۰٫۱٫۰ و ۰٫۲٫۰ ساخته و روی Tab S10 Ultra آزمایش شده‌اند. Qwen3.5 4B Q4_K_M روی دستگاه جواب فارسی می‌دهد.
- در هر دو فایل `.github/workflows/pardis-android.yml` و `.github/workflows/pala-android-fa.yml`، GitHub Actions **کد ثابت مخزن بالادستی** با commit `b848d9920e59b0af7bed6d1d335ece6652987cc1` را checkout می‌کند و فقط سپس تغییرات هویت/فارسی‌سازی را هنگام build اعمال می‌کند؛ تغییرات اصلی PALA هنوز در شاخه سورس اختصاصی تثبیت نشده است.
- `lib/features/hosting/presentation/device_hosting_provider.dart`: مدل و سرور در State/Provider نگهداری می‌شوند؛ در آغاز، `DevicePower.keepScreenOn(true)` و در توقف/Dispose برعکس اجرا می‌شود.
- `android/app/src/main/kotlin/app/ondevicellm/ondevice_llm/MainActivity.kt`: `FLAG_KEEP_SCREEN_ON` را از کانال متد فعال/غیرفعال می‌کند؛ در `onDestroy`، `NativeBridge.release(nativeOwner)` دیده می‌شود. حذف تنها این Flag درمان وابستگی به Activity نیست.
- `lib/features/zim/zim_tile.dart`: ابتدا فایل منتخب را از byte stream به `wikipedia.zim.part` کپی می‌کند؛ بعد آن را اعتبارسنجی و جایگزین می‌کند. Import فایل `wikipedia_fa_all_maxi_2026-10.zim` حدود ۱۳٫۷۸GB دو بار شکست خورده؛ **بدون کد اصلاح‌شده تکرار نشود**.
- `lib/features/zim/zim_archive.dart`: پارسر دارای `RandomAccessFile _file` و `File(path).open()`، `setPosition`, `read` و `length` است؛ حافظه را با خواندن انتخابی و کش محدود مصرف می‌کند. پارسر را از صفر بازنویسی نکنید؛ یک abstraction برای random-access source اضافه کنید.
- دو ZIM کوچک قبلاً آزمایش موفق داشته‌اند؛ مدل/حافظه و فایل بزرگ موجود باید محفوظ بمانند.

## ۳. طراحی محدود F1 — سرور بدون نمایشگر

الف) یک شاخه اختصاصی سورس پالا از **همان commit مبنای ۱٫۲٫۰** ایجاد شود؛ نسخه فعلی/شاخه `main` و Workflowهای موفق حفظ شوند. تغییرات هویت ۰٫۲٫۰ از Workflow به سورس نسخه‌بندی‌شده منتقل شوند (با تثبیت شناسه نصب و بررسی امضای APK قبل از هر نصب جدید).

ب) چرخه عمر `DeviceModelServer` و `ModelPool` و runtime بومی از Activity/UI جدا شود؛ سرویس مناسب اندروید برای درخواست‌های محلی با اعلان شفاف کاربر و قابلیت Stop پیاده شود. سرویس باید پس از رفتن Activity به پس‌زمینه، روشن‌ماندن نمایشگر را *لازم نداشته باشد*. فقط برداشتن `keepScreenOn` کافی نیست. راهبرد service type مطابق Android نسخه دستگاه و مستندات رسمی ثبت شود؛ سرویس `dataSync` را برای میزبانی شبانه‌روزی انتخاب نکنید، چون در Android 15+ برای target 35+ محدودیت مجموع ۶ ساعت در ۲۴ ساعت دارد. `specialUse` نیز نیازمند justification و مجوزها و آزمون عملی است و به‌صورت پیش‌فرض تضمین نمی‌دهد.

ج) اتصال محلی قبلاً کار کرده و احراز هویت/جفت‌سازی نباید ضعیف شود؛ در صورت امکان همان پروتکل و پورت را نگه دارید. میکروفون/شنود دائمی تبلت را اضافه نکنید. از WakeLock دائمی بدون نیاز و ترفندهای دورزدن محدودیت حرارتی/باتری خودداری کنید؛ CPU فقط حین بار محاسباتی لازم بیدار باشد و رفتار شبکه/Doze آزموده شود. شرط توقف باتری کمتر از ۲۰٪ در حالت بدون شارژ و حفاظت thermal همچنان حفظ شود.

د) تست‌ها: سرویس با صفحه روشن → قفل و خاموش‌شدن واقعی صفحه → چند پرسش از S25 روی Wi-Fi داخلی، قطع اینترنت بیرونی، برگشت از پس‌زمینه، پاک‌نشدن مدل، پایش مصرف و دما. آزمون کوتاه، سپس طولانی‌تر (نه ادعای ۲۴ ساعت از یک تست کوتاه). در ناکامی، لاگ خطا و علت و Rollback.

## ۴. طراحی محدود F2 — ZIM حجیم بدون کپی

الف) از Android `ACTION_OPEN_DOCUMENT` با انتخاب آگاهانه فایل ZIM و `takePersistableUriPermission` برای دسترسی خواندنی پایدار استفاده شود. در UI فقط «افزودن دانشنامه»، «فعال/غیرفعال» و «جداسازی» دیده شود؛ URI و جزئیات فنی فقط در بخش پیشرفته باشند. فایل اصلی هرگز حذف/تغییر داده نشود.

ب) `ZimArchive` از `RandomAccessFile` مستقیم به رابط کوچک `readAt(offset,length), length(), close()` متکی شود. دو پیاده‌سازی: فایل معمولی برای تست‌های قدیمی و URI اندروید برای فایل انتخاب‌شده. در لایه Android `ContentResolver.openFileDescriptor`/`openAssetFileDescriptor` بررسی شود و قرائت تصادفی با offset واقعی پشتیبانی گردد. توجه: بعضی document providerها به‌جای فایل seekable، pipe برمی‌گردانند؛ در این حالت خطای روشن نمایش داده شود، نه کپی پنهانی ۱۳GB. نیاز به آزمون واقعی روی DocumentProvider سامسونگ وجود دارد.

ج) ابتدا دو ZIM کوچک با یک یا چند منبع و بازیابی پس از بستن/بازکردن برنامه و Restart آزمایش شوند. سپس فقط پس از PASS و با مجوز مالک، ZIM ۱۳٫۷۸GB موجود به‌صورت **خواندنی** بررسی شود. فایل اصلی در `AI Knowledge` باید دست‌نخورده باقی بماند؛ افزایش غیرعادی حافظه/فضای دیسک FAIL است.

د) جست‌وجوی فعلی عنوانی است؛ در ابتدا برای چند سؤال فارسی، عنوان/مقاله واقعی، استخراج متن، ارجاع و هشدار برای نبود منبع نشان داده شود. توسعه جست‌وجوی معنایی کامل پس از اثبات خواندن آرشیو؛ پاسخ بدون سند نباید به‌عنوان پاسخ مستند عرضه شود.

## ۵. آزمون، نسخه‌بندی و پایان مأموریت

- اولویت نخست F1 و دوم F2 است، اما طراحی سورس و مسیر Build یکپارچه باشد؛ دو نصاب/برنامه موازی جدید و Buildهای بی‌دلیل ایجاد نشوند.
- ابتدا آزمون‌های ایزوله، آزمون‌های پذیرش UI/Android Manifest/Repository، سپس حداکثر **یک** Build آزمایشی فقط پس از PASS و حفظ Rollback. برای آزمایش دستگاه ابتدا صرفاً روی Tab S10 Ultra نصب جداگانه/ارتقای امضاشده امن اجرا شود.
- در Buildها از شناسه ثابت پالا برای نسخه‌های قابل‌ارتقا فقط پس از تأیید امضای پایدار استفاده شود؛ در غیر این صورت نصب کنار نسخه قبلی بدون حذف داده‌ها.
- خروجی هر مرحله: commit و diff، file paths، PASS/FAIL/NOT RUN، شواهد screen-off/LAN و اندازه‌گیری RAM/دما، شواهد ZIM و فضای دیسک، محدودیت‌های باقی‌مانده، دستور Rollback و Checkpoint. بدون شواهد دستگاه، هیچ قابلیت «عملیاتی» اعلام نشود.
- در تمام این عملیات Home Assistant، PVM و فایل GGUF/ZIM فعلی و برنامه اصلی OnDevice LLM دست‌نخورده بمانند. هیچ توکن یا کلمه عبور در متن/commit/گزارش ذخیره نشود.

## ۶. مدارک

- مرجع `Pardis_AI_Lab_Master_Checkpoint_2026-11-07_FA.md`
- مرجع `Pardis_AI_Lab_Prioritized_Roadmap_2026-11-08_FA.md`
- اصلاحیه مصوب ۹ نوامبر درباره دو شرط اصلی PALA و استقلال TTS/داشبورد
- سورس: https://github.com/sunshine100121/pardis-ai-lab
- Flutter/Android upstream base pinned: `b848d9920e59b0af7bed6d1d335ece6652987cc1`
- Android FGS official: https://developer.android.com/develop/background-work/services/fgs/service-types
- Android 15 FGS timeout: https://developer.android.com/develop/background-work/services/fgs/timeout
- Android SAF persistent URIs: https://developer.android.com/training/data-storage/shared/documents-files
- Android ContentResolver and seek limitations: https://developer.android.com/reference/android/content/ContentResolver
