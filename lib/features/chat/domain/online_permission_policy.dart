import '../../settings/domain/entities/inference_settings.dart';

/// M13: a pure, testable gate in front of the EXISTING web retrieval stack.
/// This is NOT a second search engine or a substitute for settings.
abstract final class OnlinePermissionPolicy {
  static final _explicit = RegExp(
    r'(?:(?:در\s+)?اینترنت|وب|آنلاین).{0,30}(?:جست[‌ ]?وجو|جستجو|بگرد|بگردید|بررسی کن)|'
    r'(?:جست[‌ ]?وجو|جستجو|بگرد|بگردید|سرچ کن).{0,35}(?:اینترنت|وب|آنلاین)|'
    r'(?:search|browse|look up|find online).{0,25}(?:web|internet|online)|'
    r'(?:on the web|on the internet)\b',
    caseSensitive: false,
    unicode: true,
  );

  static final _private = RegExp(
    r'(?:home.?assistant.{0,30}(?:token|secret|password|api.?key)|'
    r'(?:token|secret|password|api.?key).{0,30}home.?assistant|'
    r'ه[وُ]م\s*اسیستنت.{0,30}(?:توکن|رمز)|'
    r'توکن|رمز|گذرواژه|password|passphrase|'
    r'api[ _-]?key|access[ _-]?token|bearer|authorization|'
    r'private[ _-]?key|کلید خصوصی|secret|'
    r'شماره حساب|بانک|کارت بانکی|شماره کارت|'
    r'کد ملی|passport|آدرس منزل|نشانی منزل|'
    r'نام کاربری و رمز|مختصات خانه|مکان دقیق خانه)',
    caseSensitive: false,
    unicode: true,
  );

  static final _credential = RegExp(
    r'(?:(?:Bearer\s+)?eyJ[A-Za-z0-9_\-]{30,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)|'
    r'(?:\b(?:sk|ghp|gho|glpat|hf)_[A-Za-z0-9_\-]{16,}\b)|'
    r'(?:\b\d{16,19}\b)',
    caseSensitive: false,
  );

  static bool explicitlyAsked(String input) =>
      _explicit.hasMatch(input.trim());

  static bool privateContent(String input) =>
      _private.hasMatch(input) || _credential.hasMatch(input);

  /// A project always keeps external access off until a separate, strictly
  /// scoped public-query mechanism has been reviewed. Project notes never
  /// become web search text, including on an explicit search request.
  static bool mayContact({
    required WebMode mode,
    required String input,
    required bool insideProject,
    required bool approvedThisTurn,
  }) =>
      mode != WebMode.off &&
      !insideProject &&
      !privateContent(input) &&
      (mode == WebMode.always ||
          explicitlyAsked(input) ||
          approvedThisTurn);

  static bool requiresPermission({
    required WebMode mode,
    required String input,
    required bool insideProject,
  }) =>
      mode == WebMode.auto &&
      !insideProject &&
      !privateContent(input) &&
      !explicitlyAsked(input);
}
