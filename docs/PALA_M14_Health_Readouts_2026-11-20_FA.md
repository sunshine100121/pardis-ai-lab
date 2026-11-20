# PALA — HA Doctor M14: گسترش تشخیص Supervisor، منابع، Integration و بکاپ

تاریخ: ۲۰ نوامبر ۲۰۲۶
شاخه: pala/m14-health-readouts-2026-11-20
مبنا: Checkpoint موفق M14 در Commit e7988e1d4a29d416c51468829e9c2cc89f256ef7

## طراحی و سادگی
همان اتصال محلی Home Assistant و توکن موجود در Secure Storage استفاده می‌شوند. هیچ توکن ویژه Supervisor، افزونه یا سرور جدید، ابزار موازی، مدل دیگر و HA write اضافه نمی‌شود. تنظیمات برای مالک همان گزینه یک‌باره HA Doctor در صفحه اتصال است؛ متن آن اکنون محدوده خواندن موقت اطلاعات سیستم را توضیح می‌دهد.

## منابع جدید خواندنی
۱. Core GET /api/config/config_entries/entry: وضعیت Config Entryها (loaded، error، retry، disabled) در حافظه برنامه شمارش می‌شود. نام شخصی و شناسه و تنظیمات Integration به گزارش راه نمی‌یابند. این شمارش به معنی سلامت تک‌تک دستگاه‌ها نیست.
۲. Core GET /api/states: فقط با اجازه HA Doctor و صرفاً هنگام درخواست، تا سقف ۵ مگابایت در حافظه دریافت و به داده‌های پذیرفته‌شده کاهش می‌یابد. هیچ متن خام State به Qwen، اینترنت، گزارش، فایل یا GitHub ارسال نمی‌شود.
۳. فقط نام‌های شناخته‌شده مربوط به نسخه OS/Supervisor، چند حسگر رسمی System Monitor / Supervisor Host (CPU، RAM، فضای خالی دیسک) و Backup (آخرین موفقیت و تلاش خودکار و وضعیت Backup Manager) با اعتبارسنجی مقدار و واحد در گزارش ظاهر می‌شوند.
۴. بدون Sensor فعال، تاریخ یا مقدار معتبر، یا پاسخ دارای خطای دسترسی، نتیجه «نامعلوم» است. عدد صفر یا سالم‌بودن سامانه استنباط نمی‌شود.

## محدودیت‌ها
- شماره نسخه Supervisor وضعیت سلامت داخلی آن را ثابت نمی‌کند.
- داده‌های Backup خودکار، بکاپ دستی، بکاپ بیرونی، کامل بودن آرشیو، امکان رمزگشایی یا موفقیت Restore را اثبات نمی‌کنند.
- نام‌های محلی و تغییرنام Entityها ممکن است باعث شوند حسگر سیستم شناخته نشود. ترجیح بر ندادن نتیجه است تا نسبت دادن داده یک دستگاه دیگر به میزبان.
- API Supervisor برای اطلاعات پیشرفته و فهرست واقعی Backup وجود دارد، اما نقش/توکن ممتاز جداگانه می‌طلبد؛ در این فاز استفاده نمی‌شود.
- هیچ Restart، Backup Create، Restore، حذف، کنترل تجهیزات، تغییر تنظیمات یا پایش پس‌زمینه مجاز نیست.

## پذیرش
تست‌های ساختگی: گزارش خطا/بارگذاری/disabled در Config Entry؛ نسخه OS/Supervisor و سنجه‌های معتبر؛ تاریخ بکاپ خودکار و نبود داده؛ عدم نشت اطلاعات خصوصی؛ فقط GET با endpoint ثابت؛ حفظ رگرسیون‌های مأموریت ۱۴.
تا اجرای نهایی GitHub، قبولی قطعی اعلام نشود. آزمایش زنده در تبلت و Home Assistant، عدم نشت داده و عملکرد عملی منوط به انتشار یکپارچه با Backup/Restore/Rollback است.
هیچ APK، نصب، Merge به main، تغییر داده مالک یا دستکاری روی Home Assistant در این مرحله انجام نمی‌شود.

## منابع عمومی
Home Assistant official: https://www.home-assistant.io/integrations/hassio/
Home Assistant System Monitor: https://www.home-assistant.io/integrations/systemmonitor/
Home Assistant Backup: https://www.home-assistant.io/integrations/backup/
Core config entries: https://github.com/home-assistant/core/blob/dev/homeassistant/components/config/config_entries.py
Supervisor API role model: https://contributors.home-assistant.io/apps/supervisor-api/

## بازگشت
Checkpoint قبلی M14 در Commit e7988e1 حفظ می‌شود؛ نسخه نصب‌شده تبلت هیچ تغییری نکرده است.
