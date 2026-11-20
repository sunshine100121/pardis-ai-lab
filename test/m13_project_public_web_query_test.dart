import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/project_public_web_query.dart';
import 'package:ondevice_llm/features/chat/domain/online_permission_policy.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';

void main() {
  test('any public topic can be searched in a project, without a wordlist', () {
    for (final question in [
      'جدیدترین تحقیقات درباره کنه انجیر در سال ۲۰۲۶',
      'آخرین تغییرات کتابخانه Flutter و سازگاری با Qwen3.5 4B',
      'مقایسه فلسفه ودانتا و آیین ذن از منابع معتبر',
      'قیمت دوربین Hikvision DS-2CD2043G2 در بازار ایران',
      'آخرین مصاحبه نویسنده Haruki Murakami',
      'The latest research into battery degradation LiFePO4',
      'بانک مرکزی اروپا نرخ بهره امروز',
      'شخصیت رستم در شاهنامه در منابع معتبر',
      'آدرس وب سایت رسمی دانشگاه آکسفورد',
    ]) {
      final result = ProjectPublicWebQuery.fromMessage(question);
      expect(result, isNotNull, reason: question);
      expect(result!.length, greaterThan(8), reason: question);
      // Generic web-instruction words may be stripped; the public subject
      // must remain, even when the question mentions the word "وب".
      if (question.contains('آکسفورد')) {
        expect(result, contains('آکسفورد'));
      }
    }
  });

  test('project title, ownership labels and references never leave', () {
    const input =
        'در پروژه باغبانی پردیس، جدیدترین روش مقابله با کنه انجیر را '
        'در اینترنت جستجو کن';
    final query = ProjectPublicWebQuery.fromMessage(
      input, projectName: 'باغبانی پردیس',
    )!;
    expect(query, contains('کنه انجیر'));
    expect(query, isNot(contains('پردیس')));
    expect(query, isNot(contains('پروژه')));
    expect(query, isNot(contains('اینترنت')));
    final owned = ProjectPublicWebQuery.fromMessage(
      'روش آبیاری باغ من برای گردو چیست؟',
    )!;
    expect(owned, contains('آبیاری'));
    expect(owned, contains('گردو'));
    expect(owned, isNot(contains('باغ من')));
  });

  test('sensitive current-turn content fails closed without guessing', () {
    for (final raw in [
      'در اینترنت بررسی کن: کنه انجیر؛ توکن Home Assistant من abc',
      'آفات انار https://example.org/private?q=123',
      'آبیاری گردو user@example.com',
      'تعمیر باتری 192.168.100.246',
      'کنه انجیر sk_abcdefghijklmnopqrstuvw123',
      'شماره موبایل من برای آبیاری قطره ای',
      'در باغ من در شیراز چه درختی بکارم',
      'در اینترنت درباره باغ من بگرد',
    ]) {
      expect(ProjectPublicWebQuery.fromMessage(raw), isNull, reason: raw);
    }
  });

  test('pasted public HTTPS pages can be read inside projects', () {
    const raw = 'این مقاله را بررسی کن https://www.nature.com/articles/test';
    expect(
      ProjectPublicWebQuery.publicUrlsFromMessage(
        raw, [Uri.parse('https://www.nature.com/articles/test')],
      ),
      isTrue,
    );
    for (final u in [
      'http://example.com/article',
      'https://192.168.100.246/info',
      'https://localhost/manual',
      'https://example.com:8443/secret',
      'https://example.com/?token=secret',
      'https://user:pass@example.com/',
    ]) {
      expect(
        ProjectPublicWebQuery.publicUrlsFromMessage(u, [Uri.parse(u)]),
        isFalse, reason: u,
      );
    }
  });

  test('permission modes remain the owner-controlled ceiling', () {
    const q = 'جدیدترین تحقیقات آفات انجیر';
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.off, input: q, insideProject: false,
        approvedThisTurn: true,
      ), isFalse,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.auto, input: q, insideProject: false,
        approvedThisTurn: false,
      ), isFalse,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.auto, input: q, insideProject: false,
        approvedThisTurn: true,
      ), isTrue,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.always, input: q, insideProject: false,
        approvedThisTurn: false,
      ), isTrue,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.always, input: q, insideProject: true,
        approvedThisTurn: true,
      ), isFalse,
    );
  });

  test('empty and generic commands do not cause outbound searches', () {
    for (final q in [
      '',
      'سلام',
      'در اینترنت بگرد',
      'برای پروژه من سرچ کن',
      'my private project',
    ]) {
      expect(ProjectPublicWebQuery.fromMessage(q), isNull, reason: q);
    }
  });
}
