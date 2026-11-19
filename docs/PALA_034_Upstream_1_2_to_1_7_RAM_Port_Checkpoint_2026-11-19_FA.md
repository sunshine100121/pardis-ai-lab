# PALA 0.3.4 — بررسی تفاوت OnDevice LLM نسخه‌های 1.2.0 تا 1.7.0 و انتقال ایمن RAM
**تاریخ:** ۱۹ نوامبر ۲۰۲۶ | **محدوده:** شاخه آزمایشی `pala/integrated-034-2026-11-17`
**وضعیت:** مقایسه کد و انتقال کم‌خطر انجام شد؛ تأیید نهایی CI و اندازه‌گیری تبلت جداگانه درج می‌شود.

## منابع و خط مبنا
- نسخه پایه: [OnDevice LLM v1.2.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.2.0)، GitHub رسمی `sebytzr16/on-device-llm`.
- تاریخ انتشار واقعی نسخه‌های بعدی: [v1.3.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.3.0) — ۴ نوامبر؛ [v1.4.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.4.0) — ۸ نوامبر؛ [v1.5.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.5.0) — ۱۳ نوامبر؛ [v1.6.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.6.0) — ۱۷ نوامبر؛ **[v1.7.0](https://github.com/sebytzr16/on-device-llm/releases/tag/v1.7.0) — ۱۸ نوامبر ۲۰۲۶**.
- مدل واقعی مالک روی تبلت Galaxy Tab S10 Ultra با ۱۲ گیگابایت RAM: Qwen3.5 4B GGUF Q4_K_M؛ نسخه نصب‌شده PALA `0.3.3+6`. هیچ مدل، تنظیمات یا داده واقعی دستکاری نشد.
- در ارزیابی کد از فایل‌های upstream `lib/core/utils/memory_admission.dart`, `lib/inference/engine/llama_engine.dart`, `lib/features/models/presentation/providers/model_manager_provider.dart`, `lib/features/settings/domain/entities/inference_settings.dart`, `native/src/bridge.cpp` و نمونه‌های متناظر PALA استفاده شد.

## مقایسه، تصمیم انتقال و ریسک
| مورد / اولین نسخه مرتبط | وضعیت در upstream | وضعیت مشاهده‌شده در PALA پیش از مأموریت | تصمیم | دلیل / آزمون |
|---|---|---|---|---|
| جلوگیری از رقابت بارگذاری حافظه (1.5–1.7) | `MemoryAdmission.shared` صف سراسری تخصیص سنگین دارد | کلاس و سه آزمون آن از قبل وجود داشت ولی `LlamaEngine._load` از صف استفاده نمی‌کرد | **اتصال انجام شد** | کم‌خطر؛ کاهش احتمال اوج حافظه ناشی از *هم‌زمانی*، نه ادعای کاهش RAM تک‌بارگذاری |
| استفاده از Memory Mapping | `useMmap` و کنترل حافظه بومی | `useMmap=true` پیش‌فرض است؛ bridge پیشین قابلیت mmap داشت | **قبلاً موجود بود** | تنظیم موجود حفظ شد؛ از ایجاد تکرار پرهیز شد |
| برآورد مدل و هشدار کمبود حافظه | load estimate، `memoryGuard` و نمایش هشدار | `LlamaEngine.estimate`، `contextCapNote` و `memoryRefusal` پیشاپیش وجود داشت | **بخش اصلی موجود بود** | تفاوت دقیق فرمول‌های ۱.۶ باید در نسخه بومی قابل‌ساخت/آزمون بررسی شود |
| حساب‌کردن وزن‌های mmap و OpenCL GPU در RAM اندروید (1.6) | بهبود `native/src/bridge.cpp` و `memory_admission.h` | قواعد قدیمی‌تر در native C++ وجود دارند، اما همسان با ۱.۶ نیستند | **تعویق با دلیل** | تغییر native/llama.cpp بدون ABI، بسته بومی سازگار و تست تبلت پرریسک است |
| Context Auto متناسب با RAM و فضای آزاد (1.6) | `contextAuto=true` و کاهش پویای Context | تنظیم `contextSize` و `InferenceSettings.forDevice` ثابت؛ `contextAuto` در تنظیمات فعلی نیست؛ native قدیمی هنگام بارگذاری کاهش ظرفیت دارد | **تعویق با دلیل** | انتقال ناقص Dart بدون native ممکن است درخواست کاربر یا حفظ Context را نادرست تفسیر کند |
| FP8 KV cache و MoE expert caching (1.5) | `f8_e4m3` و مسیرهای متکی به موتور جدید | `KvCacheType` شامل `fp16/q8_0/q4_0` است | **فعلاً انتقال نشد** | سازگاری با Qwen3.5 4B، OpenCL و موتور بومی PALA تأیید نشده؛ تغییر کورکورانه ممنوع |
| توقف Warm-up و استفاده مجدد از prompt (1.6، 1.7) | شتاب در برخی مدل‌های بزرگ؛ اصلاح prompt reuse در Regenerate | PALA از قبل `_stopPriming` و بارگذاری مجدد مشروط دارد؛ parity عملکرد جدید ثابت نیست | **بررسی شد؛ انتقال native به بعد** | بهبود منتشرشده برای مدل Qwen3.6 35B روی لپ‌تاپ، معیار معتبر تبلت ما نیست |
| بارگذاری تکراری مدل / آزادسازی | کنترل مدل بارگذاری‌شده و file lease | `holdsLoad`، `_fileLeases`، `unload` و حفظ مدل هنگام پرسش تکراری موجود | **قبلاً موجود بود** | بدون ساخت موتور یا مدل موازی |
| نمایش وضعیت و انتخاب مدل مناسب (1.6) | راهنمای شروع، کارت‌های مدل، نمایش کمبود RAM | بخش قابل‌توجه رابط مدل و خطای RAM موجود است | **بدون تغییر UI** | فعلاً UX اضافه بی‌دلیل و تنظیمات تخصصی تحمیل نشود |
| ذخیره/خواندن امن فایل و منابع مشترک (1.4–1.6) | file leases، فایل‌های اشتراکی و سیاست‌های حفاظت | ModelFileLeases و حفاظت‌های فایل موجود؛ ZIM/PDF مسیر ویژه PALA دارند | **بدون بازنویسی** | مدل و ZIM اصلی مالک نباید کپی/جابجا شوند |
| تصویر در پاسخ (1.5، 1.6) | viewer برای تصاویر chat/generation | PALA کد اختصاصی `zim_image_selection.dart` و `zim_inline_gallery.dart` دارد | **در الزام تصویری مستقل باقی بماند** | نمایش تصویر موجود در ZIM با تولید تصویر یا Vision متفاوت است |
| Remote workspace و ابزار Agent (1.3–1.4) | انتقال پردازش به سرور | پروژه آفلاین‌اول و مستقل است | **انتقال نشد** | دورشدن از مدل محلی و افزایش پیچیدگی خلاف اولویت مالک |
| موتور خودبه‌روزرسان Windows / Android x86_64 (1.7) | امکانات سیستم‌عامل‌های دیگر | تبلت اندرویدی ARM64 و برنامه مستقل | **نامرتبط** | هزینه نگهداری بدون فایده مشخص |

## اصلاح کد و روش بازگشت
- تلاش اولیه `ecd5e508` برای افزودن صف مستقیماً در `lib/inference/engine/llama_engine.dart` با خط مبنای محافظت‌شده پروژه مغایرت داشت؛ اجرای [CI #154](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/44503147108) خطای قطعی `PROTECTED_RUNTIME_DRIFT` داد. این تغییر کامل با Commit [`1562931`](https://github.com/sunshine100121/pardis-ai-lab/commit/1562931acd62b671b51e7168b7d164b6f4bef3b5) **بازگردانده شد**. به‌هیچ‌وجه حفاظت CI دور زده نشد.
- **پیاده‌سازی جاری مجاز**: Commit [`41a9bbf`](https://github.com/sunshine100121/pardis-ai-lab/commit/41a9bbf6f1bc79f9605e05f301342eb9bb983725) در `lib/features/chat/presentation/providers/chat_provider.dart` و `lib/features/models/presentation/screens/models_screen.dart`. مسیر بارگذاری از چت و دکمه فهرست مدل‌ها با `MemoryAdmission.shared.run` صف‌بندی می‌شوند.
- دسترسی مستقیم به native، `lib/inference`، `model_manager_provider.dart` و ذخیره‌سازی سازگار با نسخه نصب‌شده حفظ و بدون تغییر مانده است.
- **دامنه محدود:** بارگذاری‌هایی که از دو مسیر UI بالا عبور می‌کنند با هم رقابت نمی‌کنند؛ بارگذاری‌های سایر ابزارها لزوماً از این صف عبور نمی‌کنند. این به‌معنی داشتن تمام بهبودهای native ۱.۷ یا کاهش اثبات‌شده RAM نیست.
- آزمون موجود `test/pala_memory_admission_test.dart` سه حالت صف، بازیابی پس از خطا و آزادسازی صف را می‌آزماید؛ آزمون روی دستگاه و سنجش RSS همچنان باقی است. مسیر بازگشت فقط Revert `41a9bbf` در شاخه آزمایشی است.

## اعتبارسنجی GitHub / تبلت
- CI `#154`: **FAIL در حفاظت خط مبنا** (تغییر قبلی موتور، اکنون Revert شده).
- CI مربوط به پیاده‌سازی مجاز `41a9bbf`: [GitHub Actions #155](https://github.com/sunshine100121/pardis-ai-lab/actions/runs/44504676437)؛ **تا پایان اجرای واقعی نباید PASS اعلام شود**.
- آزمایش Galaxy Tab S10 Ultra، اندازه‌گیری سرعت، RSS و اثربخشی حافظه: **NOT RUN**. APK، نصب، Work، GGUF و ZIM دست‌نخورده مانده‌اند.
- معیار پذیرش دستگاهی: مدل و پرسش یکسان، اندازه Context ثابت، دمای نزدیک، طول پاسخ و کیفیت مشابه، زمان بارگذاری و نخستین توکن، سرعت، اوج RSS، رفتار بارگذاری هم‌زمان و جست‌وجوی ZIM/PDF.

## نتیجه تصمیم مالک
آفلاین‌اول، حفظ داده‌ها و مدل‌ها، رابط ساده، عدم اشتراک اجباری و نبود هزینه جدید رعایت شده‌اند. انتقال انتخابی محدود به تغییر ایمن قابل‌آزمون بود؛ ارتقای گسترده native بدون ساخت APK و آزمایش تبلت **مجاز/قابل‌تأیید نیست**.
