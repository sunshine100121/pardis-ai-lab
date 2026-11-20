import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/project_public_web_query.dart';
import 'package:ondevice_llm/features/chat/domain/online_permission_policy.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';

void main() {
  test('general Persian gardening topics stay useful and public', () {
    expect(
      ProjectPublicWebQuery.fromMessage(
        'جدیدترین روش مقابله با کنه انجیر را پیدا کن',
      ),
      'جدیدترین روش مقابله کنه انجیر',
    );
    expect(
      ProjectPublicWebQuery.fromMessage(
        'در اینترنت درباره بیماری برگ‌های انجیر جست‌وجو کن',
      ),
      'بیماری برگ انجیر',
    );
    expect(
      ProjectPublicWebQuery.fromMessage(
        'جدیدترین تحقیقات درباره آفات انار را پیدا کن',
      ),
      'جدیدترین تحقیقات آفات انار',
    );
  });

  test('no private project name, owner detail or unknown noun goes out', () {
    const raw =
        'در پروژه باغبانی پردیس، برای درخت انجیر باغ شخصی من '
        'جدیدترین تحقیقات کنه را در اینترنت پیدا کن';
    final query = ProjectPublicWebQuery.fromMessage(raw)!;
    expect(query, contains('انجیر'));
    expect(query, contains('کنه'));
    for (final secret in ['پردیس', 'شخصی', 'من', 'باغبانی پردیس']) {
      expect(query, isNot(contains(secret)));
    }
    expect(
      ProjectPublicWebQuery.fromMessage('در اینترنت درباره باغ من بگرد'),
      isNull,
    );
  });

  test('credential-like and direct links fail closed even when mixed', () {
    for (final raw in [
      'در اینترنت بررسی کن: کنه انجیر؛ توکن Home Assistant من abc',
      'آفات انار https://example.org/private?q=123',
      'آبیاری گردو user@example.com',
      'تعمیر باتری 192.168.100.246',
      'کنه انجیر sk_abcdefghijklmnopqrstuvw123',
    ]) {
      expect(ProjectPublicWebQuery.fromMessage(raw), isNull, reason: raw);
    }
  });

  test('internet mode is still the upper permission boundary', () {
    const raw = 'در اینترنت جستجو کن: آفات انار';
    final publicQuery = ProjectPublicWebQuery.fromMessage(raw)!;
    // Without calling the generalizer, the original M13 gate still denies
    // raw in-project text. The integration must supply the public query
    // explicitly and only through the guarded web pipeline.
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.always,
        input: raw,
        insideProject: true,
        approvedThisTurn: true,
      ),
      isFalse,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.off,
        input: publicQuery,
        insideProject: false,
        approvedThisTurn: true,
      ),
      isFalse,
    );
    expect(
      OnlinePermissionPolicy.mayContact(
        mode: WebMode.auto,
        input: raw,
        insideProject: false,
        approvedThisTurn: false,
      ),
      isTrue,
    );
  });

  test('only recognized public words survive unusual personal details', () {
    const raw = 'جدیدترین روش آبیاری انار در مزرعه اختصاصی '
        'نامعلوم به نام آفتابستان';
    final q = ProjectPublicWebQuery.fromMessage(raw)!;
    expect(q, 'جدیدترین روش آبیاری انار');
    expect(q, isNot(contains('آفتابستان')));
    expect(q, isNot(contains('اختصاصی')));
  });
}
