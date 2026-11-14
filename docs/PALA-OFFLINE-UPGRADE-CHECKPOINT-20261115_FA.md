# PALA Offline MVP — ارتقای درجا — ۱۵ نوامبر ۲۰۲۶

## مبنا و مرز تغییر

- مخزن `sunshine100121/pardis-ai-lab`؛ فقط شاخه `pala/offline-mvp-020-2026-11-14`.
- کد MVP تأییدشده `ec6fce50abe56a111ca50d119e31ed18388c6d7f` و Checkpoint قبلی `70ec3085fe188f514f3bfa08a011917f69386e81` حفظ شدند.
- مبنای runtime همان سورس فارسی بازسازی‌شده ۰٫۲٫۰ در `78009a6f2d91ef56942bd929b3f2f289da1d212e` بر upstream `b848d9920e59b0af7bed6d1d335ece6652987cc1` است. کدهای F1 تشخیصی دوباره وارد نشده‌اند.
- Commit پیش‌بررسی امضا: `a0b26740ffec03342a1af79e4bbb5fbe36b24d0a`. Commit بسته‌بندی ارتقا و آزمون حفظ داده: `ca8053209855ae32ea6f7f659c7ac24a49b57653`.
- در این نوبت هیچ منطق runtime برنامه تغییر نکرد؛ تغییرات فقط Workflow، کنترل امضا، شناسه/نسخه بسته و آزمون‌های سازگاری هستند. main و شاخه F1 تغییر نکردند.

## زنجیره اثبات امضا، پیش از افزایش نسخه

مرجع، APK دائمی مالک از اجرای موفق [43314451868](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/43314451868) با Commit `5663b264afb77026014f81b69e04b1d00ab8a098` است که نصب آن پیش‌تر توسط مالک تأیید شده است. نسخه نصب‌شده طبق اعلام مالک ۰٫۳٫۰ / کد ۳ است.

- شناسه مرجع: `ir.pardis.ai.pala.f1diag2`؛ versionName=`0.3.0`، versionCode=`3`.
- Artifact مرجع: `14032081298`، نام `PALA-F1-independent-diagnostic2`.
- SHA256 ZIP مرجع: `facd07ee6cbc7fcf185b8c49f5bc3c5fa82295eab6d6aa0b5212b089ab23ed35`.
- SHA256 APK مرجع: `29001825fd85cb4bf2a7615b8a362fdfd781e6db76c4bbc28cd3d8f10db9942b`؛ اندازه 111529046 بایت.
- SHA256 گواهی مالک: `c8e89c07b45ed7789cf2e5484180a7d423d2a5e2040e1ac2a4192f0f14d1eb52`.
- اجرای فقط امضا [43640605507](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/43640605507): PASS؛ تطبیق Hash آرشیو و APK، package/version با aapt و اعتبار امضا با apksigner. کلید خصوصی موجود در Secrets با امضای یک challenge تصادفی و بررسی آن با گواهی مرجع اثبات شد.
- هیچ کلید جدید یا Debug به‌عنوان کلید دائمی استفاده نشد. اسکریپت `CheckUpgradeSigner.java` کلید را فقط در RAM برای پیش‌بررسی می‌خواند. ساخت، نسخه موقت PKCS12 را فقط در RUNNER_TEMP ایجاد و در پایان حذف می‌کند؛ کلید/رمز وارد مخزن یا Artifact نمی‌شوند. کنترل الزامی production signer مانع fallback به Debug است.
- **گواهی زنده تبلت: NOT VERIFIED**؛ دستگاه در این جلسه متصل نبود و adb موجود نبود. برای این بررسی ابزار سنگین نصب نشد. نتیجه تطبیق درباره APK رسمیِ مرجعِ تأییدشده و APK جدید است؛ ادعای خواندن مستقیم امضای نصب فعلی وجود ندارد.
- فقط پس از PASS پیش‌بررسی، همان applicationId به‌صورت صریح و نسخه `0.3.1+4` تنظیم شد. شناسه تازه ساخته نشد.

## حفظ داده و مدل

مالک تهیه پشتیبان رمزگذاری‌شده برنامه فعلی را تأیید کرده است؛ این پشتیبان شامل وزن GGUF نیست. هیچ Restore یا تغییر پشتیبان در این مأموریت انجام نشده است.

سورس کامل schema و migration پایگاه داده (نسخه ۱۶)، ModelStorage، appDataDirectory، SettingsNotifier/InferenceSettings، RemoteKeyStore، ModelManager، سرویس Backup و pubspec.lock به‌صورت bytewise با سورس نسخه مرجع `5663b264...` مقایسه شده‌اند. کنترل `check_offline_baseline.py` در صورت تفاوت متوقف می‌شود. مسیر Android مدل همچنان getExternalFilesDir()/models و مسیر DB همچنان دایرکتوری خصوصی قبلی است. همان package و گواهی، مسیر ارتقای درجا را فراهم می‌کنند؛ APK وزن GGUF ندارد و نصب معمول ارتقایی نباید واردکردن مجدد مدل بخواهد.

آزمون جدید `offline_upgrade_compatibility_test.dart` یک DB واقعی SQLite v16 با ردیف مدل/چت/پیام ساختگی را می‌بندد و باز می‌کند؛ برابری همه ردیف‌ها، نسخه schema، تنظیمات فارسی و تنظیم ناشناخته، عدم write/delete secure storage، مسیر/Hash/mtime فایل مدل ساختگی و نبود کپی اضافی را بررسی می‌کند. فایل مدل آزمون فقط ۴ KiB ساختگی در پوشه موقت CI است؛ وزن مالک خوانده یا کپی نشده است. آزمون Linux به‌تنهایی حفظ داده Android واقعی را اثبات نمی‌کند؛ قرارداد مسیر Android جداگانه با یکسانی سورس کنترل شده است.

**حفظ DB، تنظیمات، secure storage و GGUF واقعی بعد از نصب روی تبلت: NOT VERIFIED / NOT RUN**؛ هیچ نصب انجام نشده است. هیچ کپی/Import مدل، دست‌کاری AI Knowledge/ZIM، حذف داده یا تغییر HA/PVM انجام نشده است.

## اجرای واحد و خروجی

تنها اجرای ساخت مجاز: [43641336444](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/43641336444) روی `ca80532`، ورودی `build_apk=true` و `signing_check=false`. job ساخت به موفقیت baseline، mvp و signing وابسته است. Pushهای آماده‌سازی با `[skip ci]` از اجرای تکراری جلوگیری کردند؛ خود اجرای دستی تمام دروازه‌ها را اجرا می‌کند.

| بررسی | نتیجه واقعی |
|---|---|
| مبنای فارسی، loader، تنظیمات Native و قرارداد مدل | ۲۴ PASS |
| Flutter Analyze | PASS؛ صفر error/warning، پنج info قبلی (بدون تضعیف تنظیمات Analyze) |
| MVP، PDF واقعی CI، ZIM، گفت‌وگوی محلی، UI و HA mock | ۴۴ PASS با احتساب رگرسیون جدید حفظ داده |
| بازگشایی v16، تنظیمات و فایل مدل ساختگی | PASS، در مجموعه ۴۴تایی |
| قرارداد یکسانی runtime ۰٫۲٫۰ و نبود F1 | PASS |
| قرارداد سورس ذخیره‌سازی/تنظیمات با نسخه نصب‌شده مرجع | PASS |
| کامپایل Release Kotlin/Android پیش از APK | PASS؛ BUILD SUCCESSFUL در ۳m۹s |
| کلید خصوصی مالک و گواهی مرجع، مجدداً در همین اجرا | PASS |
| ساخت و تأیید APK نهایی | PASS؛ تنها یک APK در همان اجرا، امضای v2 معتبر با یک signer مالک |
| Hash فایل دریافت‌شده محلی در برابر گزارش CI | PASS |
| package/version/certificate و وجود کتابخانه arm64 i8mm در خروجی | PASS |
| فایل GGUF یا کلید خصوصی در ZIP داخلی APK | صفر؛ PASS |
| کل suite نامرتبط مخزن و GGUF واقعی در CI | NOT RUN |
| گواهی زنده دستگاه، نصب، حفظ داده/بارگذاری Qwen پس از ارتقا | NOT VERIFIED / NOT RUN |

پنج info Analyze مربوط به import و brace در folder_library، brace در ha_read_client/zim_wikipedia و print ابزار CI هستند؛ هیچ‌کدام خطای تازه آزمون ارتقا نیستند. برای رفع ظاهری این موارد runtime تغییر داده نشد.

کل اجرای `43641336444` با نتیجه **SUCCESS** پایان یافت. چهار job baseline، mvp، signing و upgrade موفق‌اند. هیچ ساخت مجدد، rerun یا Candidate موازی انجام نشد. پاک‌سازی کلید موقت CI نیز موفق بود.

### خروجی قابل‌دریافت

- [Artifact ارتقا](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/43641336444/artifacts/14133316348): `PALA-Offline-MVP-0.3.1-upgrade-v4`، ID=`14133316348`؛ فایل APK همراه با گزارش package، امضا و SHA256. زمان انقضای فعلی GitHub: `2027-02-12T21:09:55Z`؛ نسخه محلی مستقل از این انقضا محفوظ است.
- package=`ir.pardis.ai.pala.f1diag2`؛ versionName=`0.3.1`؛ versionCode=`4`؛ arm64؛ minSdk=28، compileSdk=36.
- APK: `111614642` بایت؛ SHA256=`a5af49e8094bebd2f00e37eb20d8bd32f3f87415fc39cd4c24e5c73b8d6b1749`.
- گواهی خروجی با مرجع و کلید خصوصی مالک یکسان است: `c8e89c07b45ed7789cf2e5484180a7d423d2a5e2040e1ac2a4192f0f14d1eb52`. امضای Debug استفاده نشده است.
- digest آرشیو Artifact طبق GitHub: `sha256:ebdd00ead0f7b9a2a2ee3d3a5fe3ca5c3365c8bc8ab30168b9dbb2f2e179b5d3`؛ این Hash با Hash خود APK متفاوت است.
- مسیر APK محلی: `C:\Users\Jama\Documents\Codex\PALA-Offline-MVP-20261114\upgrade-gate\upgrade-v4-43641336444\app-release.apk`.
- سه گزارش `app-release.sha256`، `upgrade-package.txt` و `upgrade-signing.txt` کنار APK هستند. Hash محلی با SHA256 گزارش CI برابر است؛ package/code4/certificate گزارش نیز به‌صورت خودکار کنترل شد. صفر عضو GGUF و صفر عضو p12/jks/keystore در APK و وجود `lib/arm64-v8a/libondevice_llm_cpu_i8mm.so` محلی بررسی شد.
- APK مرجع code3 و گزارش‌های آن در `C:\Users\Jama\Documents\Codex\PALA-Offline-MVP-20261114\upgrade-gate\previous-apk` حفظ شده‌اند؛ هیچ فایل قبلی بازنویسی نشد.

**وضعیت آمادگی:** بسته برای بررسی و نصب ارتقایی با همان package/گواهی مرجع آماده است؛ اثبات زنده نصب و حفظ اطلاعات واقعی فقط پس از مجوز جداگانه مالک و آزمون تبلت ممکن است. فضای آزاد و گواهی زنده تبلت در این جلسه بررسی نشده‌اند. به‌دلیل حفظ مدل موجود، Import مجدد یا فضای اضافی چندگیگابایتی برای یک نسخه دیگر از GGUF لازم نیست؛ فضای موقت لازم برای نصب خود APK همچنان باید موجود باشد.

## نصب و بازگشت امن

هیچ نصب خودکاری مجاز یا انجام‌شده نیست. پس از تأیید جداگانه مالک، فقط APK امضاشده همین خروجی به‌صورت Update روی f1diag2 نصب شود؛ برنامه قبلی حذف نشود. اگر نصب‌گر به‌جای به‌روزرسانی حذف برنامه خواست، خطای امضا داد، یا مدل قبلی پس از بازکردن دیده نشد، توقف؛ Clear Data، Uninstall، Import دوباره و Restore خودکار انجام نشود. برنامه اصلی سالم و سایر نسخه‌ها دست‌نخورده‌اند.

کوتاه‌ترین بررسی پس از نصب مجاز: وجود گفت‌وگوها و تنظیمات قبلی، نمایش همان مدل Qwen واردشده و یک پاسخ کوتاه محلی؛ سپس انتخاب/بازخوانی پوشه دانش از رابط موجود در صورت نیاز. این بررسی‌ها در این نوبت اجرا نشده‌اند و هیچ اتصال تازه HA تنظیم نشده است.

Rollback مستقیم از code4 به APK قبلی code3 مسیر استاندارد Android نیست. APK مرجع و پشتیبان محفوظ‌اند، اما بازگشت درجا نیازمند مأموریت جداگانه برای ساخت سورس قبلی با همین package، همان کلید مالک و versionCode بزرگ‌تر از ۴ است؛ schema v16 و مسیر مدل باید همچنان حفظ شوند. در این مأموریت چنین بسته‌ای ساخته نشده و downgrade/Restore اجرا نشده است. پشتیبان رمزگذاری‌شده جای نگهداری GGUF موجود را نمی‌گیرد.

منابع رسمی: [امضای به‌روزرسانی Android](https://developer.android.com/studio/publish/app-signing)، [نسخه‌بندی و جلوگیری از downgrade](https://developer.android.com/studio/publish/versioning).

## فایل‌های این مأموریت

- `.github/workflows/ci.yml`: دروازه امضا، آزمون حفظ داده و یک ساخت دستی وابسته به موفقیت آزمون‌ها.
- `scripts/CheckUpgradeSigner.java`: اثبات کلید خصوصی موجود و گواهی مرجع بدون انتشار secrets.
- `scripts/check_offline_baseline.py`: تقویت قرارداد سازگاری داده/مدل/تنظیمات با نسخه مرجع.
- `test/offline_upgrade_compatibility_test.dart`: رگرسیون بازگشایی داده و حفظ مدل ساختگی.
- `android/app/build.gradle.kts`: همان applicationId نصب فعلی و نوع PKCS12 برای signer دائمی.
- `pubspec.yaml`: نسخه ۰٫۳٫۱، کد ۴.
- همین Checkpoint؛ Checkpointهای پیشین و شواهد مرجع حفظ شدند.

برای بازیابی سورس خروجی از `ca8053209855ae32ea6f7f659c7ac24a49b57653` استفاده شود؛ Commit بعدی این Checkpoint فقط مستندسازی است و فایل‌های ساخت را تغییر نمی‌دهد. در پایان این تحویل تغییر ثبت‌نشده‌ای در worktree باقی نمی‌ماند. هیچ اقدامی در نصب‌های مالک، GGUF/ZIM، AI Knowledge، Home Assistant، PVM1 یا Restore انجام نشده است.
