import 'package:shared_preferences/shared_preferences.dart';

import 'voice_engine_selection.dart';

/// Separate, migration-safe preferences for future model variants.
/// This never changes the installed PALA 0.3.3 InferenceSettings contract.
class VoiceChoiceStorage {
  static const sttKey = 'pala_voice_stt_model_choice_v1';
  static const ttsKey = 'pala_voice_tts_model_choice_v1';

  static String _key(VoiceSelectionKind kind) =>
      kind == VoiceSelectionKind.stt ? sttKey : ttsKey;

  static Future<String?> current(VoiceSelectionKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key(kind));
    final selection = VoiceEngineSelection.parse(stored);
    return selection?.kind == kind ? stored : null;
  }

  static Future<void> choose(VoiceSelectionKind kind, String id) async {
    final parsed = VoiceEngineSelection.parse(id);
    if (parsed == null || parsed.kind != kind) {
      throw const FormatException('شناسه موتور/مدل گفتار معتبر نیست.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key(kind), id)) {
      throw StateError('ذخیره انتخاب موتور/مدل ممکن نشد.');
    }
  }

  static Future<void> clear(VoiceSelectionKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_key(kind))) {
      throw StateError('پاک‌سازی انتخاب موتور/مدل ممکن نشد.');
    }
  }
}
