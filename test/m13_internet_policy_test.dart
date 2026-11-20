import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/online_permission_policy.dart';
import 'package:ondevice_llm/features/chat/domain/retrieval_plan.dart';
import 'package:ondevice_llm/features/chat/presentation/providers/online_turn_permission.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline-only never authorizes web, even with explicit Persian search',
      () {
    const input = 'در اینترنت جستجو کن: هواشناسی فردا';
    expect(OnlinePermissionPolicy.explicitlyAsked(input), isTrue);
    expect(OnlinePermissionPolicy.mayContact(
      mode: WebMode.off, input: input, insideProject: false,
      approvedThisTurn: true,
    ), isFalse);
    expect(RetrievalPlan.of(input, webEnabled: false).mode,
        RetrievalMode.none);
  });

  test('explicit search is a one-turn user grant, not a repeat dialog', () {
    for (final phrase in [
      'در اینترنت جستجو کن: روش آبیاری گردو',
      'در وب جست‌وجو کن: شیراز',
      'جستجو کن در اینترنت برای باغبانی',
      'search on the internet for weather',
    ]) {
      expect(OnlinePermissionPolicy.explicitlyAsked(phrase), isTrue,
          reason: phrase);
      expect(OnlinePermissionPolicy.requiresPermission(
        mode: WebMode.auto, input: phrase, insideProject: false,
      ), isFalse, reason: phrase);
      expect(OnlinePermissionPolicy.mayContact(
        mode: WebMode.auto, input: phrase, insideProject: false,
        approvedThisTurn: false,
      ), isTrue, reason: phrase);
    }
  });

  test('offline-first requires one approval for inferred online needs', () {
    const input = 'جدیدترین نسخه فلاتر امروز چیست؟';
    expect(OnlinePermissionPolicy.explicitlyAsked(input), isFalse);
    expect(OnlinePermissionPolicy.requiresPermission(
      mode: WebMode.auto, input: input, insideProject: false,
    ), isTrue);
    expect(OnlinePermissionPolicy.mayContact(
      mode: WebMode.auto, input: input, insideProject: false,
      approvedThisTurn: false,
    ), isFalse);
    expect(OnlinePermissionPolicy.mayContact(
      mode: WebMode.auto, input: input, insideProject: false,
      approvedThisTurn: true,
    ), isTrue);
    expect(OnlinePermissionPolicy.mayContact(
      mode: WebMode.always, input: input, insideProject: false,
      approvedThisTurn: false,
    ), isTrue);
  });

  test('project facts and home assistant credentials never reach the web', () {
    for (final message in [
      'در اینترنت جستجو کن: رمز عبور Home Assistant من',
      'API key: sk_test-secretkey_abcdefghijklmnopqrst',
      'Bearer eyJhbGciOiJIUzI1NiJ9.e30.signature',
      'جستجو کن در وب: توکن سیستم من',
    ]) {
      expect(OnlinePermissionPolicy.privateContent(message), isTrue,
          reason: message);
      expect(OnlinePermissionPolicy.mayContact(
        mode: WebMode.always, input: message, insideProject: false,
        approvedThisTurn: true,
      ), isFalse);
    }
    expect(OnlinePermissionPolicy.privateContent(
      'در اینترنت جستجو کن: خبرهای عمومی Home Assistant',
    ), isFalse);
    expect(OnlinePermissionPolicy.mayContact(
      mode: WebMode.always,
      input: 'در اینترنت جستجو کن: آبیاری قطره‌ای گردو',
      insideProject: true,
      approvedThisTurn: true,
    ), isFalse);
  });

  test('the original WebMode serializes under existing settings contract', () {
    for (final mode in WebMode.values) {
      final original = InferenceSettings(webMode: mode);
      final saved = InferenceSettings.fromJson(original.toJson());
      expect(saved.webMode, mode);
    }
    expect(const InferenceSettings().webMode, WebMode.off);
  });

  test('denying one request cannot grant the next request', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(onlineTurnPermissionProvider.notifier);
    final first = notifier.ask(query: 'آیا امروز باران می‌بارد؟');
    expect(c.read(onlineTurnPermissionProvider)?.query, contains('باران'));
    notifier.reject();
    expect(await first, isFalse);
    expect(c.read(onlineTurnPermissionProvider), isNull);
    final second = notifier.ask(query: 'قیمت طلا امروز');
    expect(c.read(onlineTurnPermissionProvider)?.query, contains('طلا'));
    notifier.approve();
    expect(await second, isTrue);
    expect(c.read(onlineTurnPermissionProvider), isNull);
  });

  test('new pending request cancels previous without inheriting approval', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(onlineTurnPermissionProvider.notifier);
    final first = notifier.ask(query: 'منبع اول');
    final second = notifier.ask(query: 'منبع دوم');
    expect(await first, isFalse);
    notifier.approve();
    expect(await second, isTrue);
    expect(c.read(onlineTurnPermissionProvider), isNull);
  });
}
