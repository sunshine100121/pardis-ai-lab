# امضای پایدار نسخه تشخیصی PALA F1

نسخه تشخیصی با شناسه `ir.pardis.ai.pala.f1diag` باید همیشه با همان کلید خصوصی امضا شود. APK ساخته‌شده در اجرای `42875180326` با کلید Debug موقت GitHub Actions امضا شده و برای نصب پایدار یا به‌روزرسانی بعدی مناسب نیست. پیش از نصب نسخه‌ای که قرار است نگه داشته شود، کلید مالک را بسازید و Secrets زیر را در تنظیمات مخزن GitHub ثبت کنید.

## نگهداری کلید

- یک فایل PKCS#12 با نامی مانند `pala-f1diag-release.p12` و Alias برابر `pala-f1diag` بسازید.
- فایل کلید را در دو محل امن و رمزگذاری‌شده نگه دارید؛ یکی از آن‌ها باید نسخه پشتیبان جدا از رایانه اصلی باشد. رمزهای کلید را در Password Manager نگه دارید.
- فایل `.p12`، رمزها و نسخه Base64 آن را هرگز وارد مخزن عمومی، Commit، Artifact یا Checkpoint نکنید.
- برای ساخت کلید از یک Java `keytool` مورد اعتماد و فرمان زیر در محیط امن استفاده کنید. رمزها را در پرسش تعاملی وارد کنید و در خط فرمان ننویسید:

```powershell
keytool -genkeypair -v -keystore .\pala-f1diag-release.p12 -storetype PKCS12 -alias pala-f1diag -keyalg RSA -keysize 3072 -validity 10000
```

## GitHub Actions Secrets

در `Settings → Secrets and variables → Actions → New repository secret` این چهار Secret را ثبت کنید:

| نام Secret | مقدار |
|---|---|
| `PALA_F1_KEYSTORE_BASE64` | محتوای Base64 فایل PKCS#12 |
| `PALA_F1_KEYSTORE_PASSWORD` | رمز keystore |
| `PALA_F1_KEY_ALIAS` | `pala-f1diag` |
| `PALA_F1_KEY_PASSWORD` | رمز کلید |

برای ساخت Base64 در PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('.\pala-f1diag-release.p12'))
```

متن خروجی را فقط در Secret مربوط به GitHub وارد کنید. Actions فایل را موقتاً در فضای Runner می‌سازد و بعد از کار حذف می‌کند. Workflow ساخت APK را در صورت نبود هرکدام از Secrets متوقف می‌کند و به امضای Debug برنمی‌گردد.

پس از ثبت Secrets، از Workflow `ci.yml` روی شاخه `pala/f1-f2-f3-2026-11-09`، ورودی `build_apk=true` را اجرا کنید. Pushهای معمولی فقط اعتبارسنجی می‌شوند و APK تولید نمی‌کنند.

> اگر فایل یا رمز keystore گم شود، امضای همان شناسه برنامه قابل بازیابی نیست. نسخه‌ای با کلید دیگری به‌روزرسانی نصب موجود محسوب نمی‌شود و نصب آن ممکن است به حذف داده‌های برنامه نیاز داشته باشد.
