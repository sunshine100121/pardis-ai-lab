/// Safe, predictable Persian speech choices; none may silently enable a
/// network recognizer or download an optional model.
abstract final class PersianSttPolicy {
  static const android = 'android-local';
  static const whisper = 'whisper-fa';
  static const vosk = 'vosk-fa';

  /// Old installs stored an empty listening preference. Keep their default
  /// Android route deterministic even if a Whisper pack is installed.
  static String selected(String setting) =>
      setting == whisper || setting == vosk ? setting : android;

  static bool ready({
    required String setting,
    required bool androidReady,
    required bool whisperReady,
    required bool voskReady,
  }) => switch (selected(setting)) {
    whisper => whisperReady,
    vosk => voskReady,
    _ => androidReady,
  };

  /// This is a visible manual fallback, never an automatic engine switch.
  static String unavailable({
    required String setting,
    required bool androidReady,
    required bool whisperReady,
    required bool voskReady,
  }) {
    final selectedEngine = selected(setting);
    final options = <String>[
      if (androidReady && selectedEngine != android) 'Android',
      if (voskReady && selectedEngine != vosk) 'Vosk فارسی',
      if (whisperReady && selectedEngine != whisper) 'Whisper',
    ];
    if (options.isNotEmpty) {
      return 'موتور انتخاب‌شده آماده نیست؛ از بالای همین صفحه '
          '${options.join(' یا ')} را انتخاب کنید. '
          'موتور دیگری خودکار فعال نمی‌شود.';
    }
    return 'هیچ موتور فارسی آماده نیست. وضعیت بسته فارسی Android را بررسی '
        'کنید؛ فقط در صورت تمایل مدل Vosk یا Whisper را دریافت کنید.';
  }

  /// Only a final, nonempty recognizer result can become a chat question.
  /// Interim captions, errors and empty replies must not reach the LLM.
  static String? finalPrompt(String transcript) {
    final cleaned = transcript.trim();
    return cleaned.isEmpty ? null : cleaned;
  }
}
