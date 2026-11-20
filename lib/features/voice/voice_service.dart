import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueChanged, TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/l10n/l10n.dart';
import '../../core/platform/desktop_host.dart';
import '../../core/utils/inference_admission.dart';
import '../settings/domain/entities/inference_settings.dart';
import '../settings/presentation/providers/settings_provider.dart';
import 'desktop_voice_policy.dart';
import 'offline_dictation.dart';
import 'persian_stt_policy.dart';
import 'voice_choice_storage.dart';
import 'voice_engine_selection.dart';
import 'vosk_local_models.dart';
import 'persian_sherpa_models.dart';
import 'persian_sherpa_runtime.dart';
import 'pocket_farsi_v2_reader.dart';
import 'sherpa_voice.dart';
import 'voice_models.dart';
import 'voice_models_provider.dart';
import 'voice_pipeline.dart';

/// Dictation and read-aloud (FX-01). With the on-device voice installed
/// (2026-10-07) Whisper listens and Kokoro speaks, all on the phone; else
/// verified offline platform voices. Android dictation always uses the
/// dedicated on-device recognizer; unverified system voices fail closed.
class VoiceState {
  final bool listening, speaking, available, paused;
  final String partial;
  final String? error;

  /// Id of the message being read, for the bubble's speaker icon.
  final String? speakingId;
  const VoiceState({
    this.listening = false,
    this.speaking = false,
    this.paused = false,
    this.available = true,
    this.partial = '',
    this.error,
    this.speakingId,
  });
  VoiceState copyWith({
    bool? listening,
    bool? speaking,
    bool? paused,
    bool? available,
    String? partial,
    String? error,
    bool clearError = false,
    String? speakingId,
    bool clearSpeakingId = false,
  }) => VoiceState(
    listening: listening ?? this.listening,
    speaking: speaking ?? this.speaking,
    paused: paused ?? this.paused,
    available: available ?? this.available,
    partial: partial ?? this.partial,
    error: clearError ? null : error ?? this.error,
    speakingId: clearSpeakingId ? null : speakingId ?? this.speakingId,
  );
}

class VoiceNotifier extends Notifier<VoiceState> {
  static const _androidTtsEngineKey = 'pala_voice_android_tts_engine_v1';
  static const _androidTtsVoiceKey = 'pala_voice_android_tts_voice_v1';
  SpeechToText? _stt;
  FlutterTts? _tts;
  Future<void>? _ttsInitialization;

  /// True while a system-voice speak() is pending. flutter_tts on Windows
  /// answers the pending speak() inside stop() without a null check, so a
  /// stop() with nothing playing crashed the PC app (owner, 2026-11-01).
  bool _ttsBusy = false;
  bool _sttReady = false, _alive = true, _usingOffline = false;
  OfflineDictation? _offline;
  PersianCtcListener? _ctc;
  PersianPiperSpeaker? _piper;
  PocketFarsiLongReader? _pocketReader;
  String _spokenText = '';
  int _position = 0, _chunkStart = 0, _speechEpoch = 0;
  double _rate = 0.5;
  KokoroSpeaker? _kokoro;
  WhisperListener? _whisper;
  Timer? _whisperIdle;

  /// Ends the Whisper dictation with everything heard (set while it runs).
  void Function()? _whisperDone;
  int _listenEpoch = 0;

  /// Kokoro read-out: the sentences and the one playing, for pause/resume.
  List<String> _sentences = const [];
  int _sentence = 0;

  /// Bounded utterances preserve every character and break at sentences.
  static List<String> chunks(String text, {int limit = 3000}) {
    if (limit < 32) throw ArgumentError.value(limit, 'limit');
    final out = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + limit).clamp(0, text.length);
      if (end < text.length) {
        final segment = text.substring(start, end);
        final boundaries = RegExp(r'[.!?]\s|\n').allMatches(segment).toList();
        if (boundaries.isNotEmpty && boundaries.last.end > limit ~/ 2) {
          end = start + boundaries.last.end;
        } else {
          final space = segment.lastIndexOf(' ');
          if (space > limit ~/ 2) end = start + space + 1;
        }
        if (end > start &&
            text.codeUnitAt(end - 1) >= 0xD800 &&
            text.codeUnitAt(end - 1) <= 0xDBFF) {
          end--;
        }
      }
      out.add(text.substring(start, end));
      start = end;
    }
    return out;
  }

  @override
  VoiceState build() {
    // Queued sentences carry the old engine's speaker/language IDs. Stop them
    // before a newly selected engine can receive them (owner, 2026-11-02).
    ref.listen(
      settingsProvider.select((s) => s.readingVoice),
      (_, _) => unawaited(stopSpeaking()),
    );
    ref.onDispose(() {
      _alive = false;
      _whisperIdle?.cancel();
      _whisper?.dispose();
      unawaited(_kokoro?.stop());
      unawaited(_offline?.dispose());
      _ctc?.dispose();
      _piper?.dispose();
      unawaited(_pocketReader?.cancel());
      _stt?.cancel();
      unawaited(_stopTts());
    });
    return const VoiceState();
  }

  /// Markdown → speakable text: no code fences, links become their label,
  /// emphasis and headings lose their markers, citations disappear.
  static String speakable(String markdown) => markdown
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' code omitted. ')
      .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
      // With the space before it: "today [1]." must not read "today .".
      .replaceAll(RegExp(r'\s*\[\d+(?:\s*,\s*\d+)*\]'), '')
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
      .replaceAll(RegExp(r'[*_~]{1,3}'), '')
      .replaceAll(RegExp(r'\|'), ', ')
      // "Bonne journée! 😊": not something to read out.
      .replaceAll(
        RegExp(
          r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
          unicode: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .trim();

  Future<bool> _initStt() async {
    if (_sttReady) return true;
    _stt ??= SpeechToText();
    try {
      _sttReady = await _stt!.initialize(
        onError: (e) {
          if (!_alive) return;
          state = state.copyWith(
            listening: false,
            error: _speechError(e.errorMsg),
          );
        },
        onStatus: (s) {
          if (!_alive) return;
          if (s == 'done' || s == 'notListening') {
            state = state.copyWith(listening: false);
          }
        },
      );
    } catch (e) {
      _sttReady = false;
      state = state.copyWith(
        available: false,
        error: 'Dictation unavailable: $e',
      );
    }
    if (!_sttReady) state = state.copyWith(available: false);
    return _sttReady;
  }

  static String _explain(String code) => switch (code) {
    'offline_unavailable' => 'On-device dictation is unavailable. Install an offline speech service and language pack. No network recognizer was started.',
    'offline_recognition_failed' => 'On-device dictation failed. Check the offline language pack in the phone\'s speech settings. No network recognizer was started.',
    'error_no_match' => 'No speech recognised.',
    'error_speech_timeout' => 'No speech heard.',
    'error_permission' ||
    'error_audio' => 'Microphone permission is needed for dictation.',
    'error_language_unavailable' || 'error_language_not_supported' => 'On-device recognition has no language pack installed. Install one in the phone\'s speech settings, or allow the network recognizer.',
    'error_network' => 'The recognizer needs a network and none is available.',
    _ => 'Dictation error ($code).',
  };

  String _speechError(String code) {
    if (DesktopHost.active &&
        RegExp(
          'permission|denied|audio',
          caseSensitive: false,
        ).hasMatch(code)) {
      return stringsFor(ref.read(settingsProvider).localeCode)
          .desktopVoiceMicPrivacy;
    }
    if (voiceLanguage(ref.read(settingsProvider).localeCode) == 'fa') {
      return switch (code) {
        'offline_unavailable' => 'موتور آفلاین Android موجود نیست؛ Vosk یا Whisper آماده را انتخاب کنید.',
        'offline_recognition_failed' || 'dictation_failed' =>
          'تشخیص گفتار آفلاین انجام نشد؛ میکروفون و مدل را بررسی کنید.',
        'error_no_match' => 'گفتار قابل‌تشخیص نبود؛ دوباره امتحان کنید.',
        'error_speech_timeout' => 'گفتاری شنیده نشد؛ زمان آزمایش تمام شد.',
        'error_permission' || 'error_audio' =>
          'مجوز میکروفون لازم است؛ در تنظیمات Android آن را فعال کنید.',
        'error_language_unavailable' || 'error_language_not_supported' =>
          'بسته فارسی آفلاین آماده نیست؛ موتور نصب‌شده دیگری انتخاب کنید.',
        'error_network' =>
          'موتور انتخاب‌شده بدون شبکه کار نکرد؛ جایگزین خودکار فعال نشد.',
        'vosk_model_unavailable' =>
          'مدل Vosk فارسی در دسترس نیست؛ وضعیت دانلود را بررسی کنید.',
        _ => 'خطای تشخیص گفتار آفلاین ($code).',
      };
    }
    return _explain(code);
  }

  /// Starts dictation; [onText] receives the running transcript, [onFinal]
  /// the last words when the session ends.
  Future<void> listen({
    required ValueChanged<String> onText,
    ValueChanged<String>? onFinal,
    bool onDeviceOnly = true,
    String? localeId,
  }) async {
    if (state.listening) return stop();
    final epoch = ++_listenEpoch;
    final futureChoice = await VoiceChoiceStorage.current(
      VoiceSelectionKind.stt,
    );
    if (!_alive || epoch != _listenEpoch) return;
    // A user-imported Vosk ZIP is a real local adapter route. Unknown
    // adapters fail closed, without silently falling back to Android STT.
    final requested = VoiceEngineSelection.parse(futureChoice);
    final customPath =
        requested?.kind == VoiceSelectionKind.stt &&
            requested?.adapter == 'vosk'
        ? await VoskLocalModels.pathFor(requested!.model)
        : null;
    if (!_alive || epoch != _listenEpoch) return;
    final shenava =
        requested?.kind == VoiceSelectionKind.stt &&
            requested?.adapter == 'sherpa-ctc'
        ? await PersianSherpaModels.find(
            PersianSherpaKind.stt,
            requested!.model,
          )
        : null;
    if (!_alive || epoch != _listenEpoch) return;
    if (futureChoice != null && customPath == null && shenava == null) {
      state = state.copyWith(
        listening: false,
        error:
            'مدل STT انتخابی موجود یا سازگار نیست؛ '
            'انتخاب حفظ شد و موتور جایگزین خودکار اجرا نشد.',
      );
      return;
    }
    final selectedSettings = ref.read(settingsProvider);
    final persian = voiceLanguage(selectedSettings.localeCode) == 'fa';
    final selectedPersian = PersianSttPolicy.effective(
      selectedSettings.listeningModel,
      customVoskReady: customPath != null,
    );
    final explicitWhisper =
        persian && selectedPersian == PersianSttPolicy.whisper;
    final explicitVosk =
        persian &&
        (selectedPersian == PersianSttPolicy.vosk || customPath != null);
    if (futureChoice != null && !persian) {
      state = state.copyWith(
        listening: false,
        error: 'مدل گفتار واردشده فارسی است؛ زبان مکالمه را فارسی انتخاب کنید.',
      );
      return;
    }
    if (shenava != null) {
      _ctc?.dispose();
      late final PersianCtcListener listener;
      listener = PersianCtcListener(
        model: shenava,
        onFinal: (text) {
          if (!_alive || epoch != _listenEpoch) return;
          state = state.copyWith(listening: false, partial: text);
          onText(text);
          onFinal?.call(text);
        },
        onError: (message) {
          if (!_alive || epoch != _listenEpoch) return;
          state = state.copyWith(listening: false, error: message);
        },
      );
      _ctc = listener;
      state = state.copyWith(
        listening: true,
        partial: '',
        available: true,
        clearError: true,
      );
      try {
        if (!await listener.start()) {
          if (_alive && epoch == _listenEpoch) {
            state = state.copyWith(
              listening: false,
              error: 'میکروفون یا مدل شنوا آماده نیست.',
            );
          }
        }
      } catch (_) {
        if (_alive && epoch == _listenEpoch) {
          state = state.copyWith(
            listening: false,
            error: 'اجرای موتور آفلاین شنوا ناموفق بود.',
          );
        }
      }
      return;
    }
    if (persian &&
        selectedPersian != PersianSttPolicy.android &&
        !explicitWhisper &&
        !explicitVosk) {
      state = state.copyWith(
        listening: false,
        error:
            'مدل STT انتخابی در تنظیمات حفظ شده، اما آداپتور آن '
            'آماده نیست. موتور دیگری خودکار اجرا نمی‌شود.',
      );
      return;
    }
    if (explicitWhisper && !_naturalListening()) {
      state = state.copyWith(
        listening: false,
        error: 'مدل Whisper آماده نیست؛ وضعیت دانلود را بررسی کنید.',
      );
      return;
    }
    if (customPath == null && _naturalListening()) {
      try {
        if (await _listenWhisper(onText, onFinal)) return;
        if (explicitWhisper && _alive && epoch == _listenEpoch) {
          state = state.copyWith(
            listening: false,
            error: 'شروع Whisper ناموفق بود؛ موتور دیگری به‌طور خودکار انتخاب نشد.',
          );
          return;
        }
      } on PlatformException catch (e) {
        if (e.code == 'microphone_denied') {
          state = state.copyWith(
            listening: false,
            error: stringsFor(ref.read(settingsProvider).localeCode)
                .desktopVoiceMicPrivacy,
          );
          return;
        }
        rethrow;
      }
    }
    if (!_alive || epoch != _listenEpoch) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final voskPath =
          customPath ??
          (explicitVosk ? await VoiceModels.voskPersianPath() : null);
      if (explicitVosk && voskPath == null) {
        state = state.copyWith(
          listening: false,
          error: 'مدل Vosk فارسی نصب نشده است؛ ابتدا آن را دریافت کنید.',
        );
        return;
      }
      if (persian && !explicitVosk) {
        try {
          final capabilities = await OfflineDictation.capabilities();
          if (capabilities['androidOfflineAvailable'] != true) {
            if (_alive && epoch == _listenEpoch) {
              state = state.copyWith(
                listening: false,
                error:
                    'بسته تشخیص گفتار فارسی Android آماده نیست؛ '
                    'از تنظیمات گفتار، Vosk یا Whisper نصب‌شده را '
                    'به‌صورت دستی انتخاب کنید. تشخیص آنلاین اجرا نشد.',
              );
            }
            return;
          }
        } catch (_) {
          if (_alive && epoch == _listenEpoch) {
            state = state.copyWith(
              listening: false,
              error:
                  'آمادگی موتور آفلاین Android تأیید نشد. '
                  'موتور دیگری خودکار فعال نمی‌شود.',
            );
          }
          return;
        }
      }
      if (!_alive || epoch != _listenEpoch) return;
      _usingOffline = true;
      _offline ??= OfflineDictation();
      state = state.copyWith(
        listening: true,
        available: true,
        partial: '',
        clearError: true,
      );
      try {
        await _offline!.listen(
          engine: explicitVosk ? 'vosk-fa' : 'android-local',
          modelPath: voskPath,
          localeId: dictationLocale(
            ref.read(settingsProvider).localeCode,
            localeId,
          ),
          onResult: (text, isFinal) {
            if (!_alive || epoch != _listenEpoch) return;
            state = state.copyWith(partial: text, listening: !isFinal);
            onText(text);
            if (isFinal) onFinal?.call(text);
          },
          onError: (code) {
            if (!_alive || epoch != _listenEpoch) return;
            state = state.copyWith(
              listening: false,
              error: code == 'cancelled' ? null : _speechError(code),
              clearError: code == 'cancelled',
            );
          },
        );
      } on PlatformException catch (e) {
        if (_alive) {
          state = state.copyWith(
            listening: false,
            error: e.code == 'cancelled' ? null : _speechError(e.code),
            clearError: e.code == 'cancelled',
          );
        }
      } on MissingPluginException {
        if (_alive) {
          state = state.copyWith(
            listening: false,
            error: _speechError('offline_unavailable'),
          );
        }
      }
      return;
    }
    if (!_alive || epoch != _listenEpoch) return;
    _usingOffline = false;
    if (DesktopHost.active && await VoiceAudioChannel.micPrivacyDenied()) {
      state = state.copyWith(
        listening: false,
        error: stringsFor(ref.read(settingsProvider).localeCode)
            .desktopVoiceMicPrivacy,
      );
      return;
    }
    if (!await _initStt() || !_alive || epoch != _listenEpoch) return;
    state = state.copyWith(listening: true, partial: '', clearError: true);
    try {
      await _stt!.listen(
        onResult: (r) {
          if (!_alive) return;
          state = state.copyWith(partial: r.recognizedWords);
          onText(r.recognizedWords);
          if (r.finalResult) {
            onFinal?.call(r.recognizedWords);
            state = state.copyWith(listening: false);
          }
        },
        listenOptions: SpeechListenOptions(
          onDevice: true,
          partialResults: true,
          cancelOnError: true,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
          localeId: dictationLocale(
            ref.read(settingsProvider).localeCode,
            localeId,
          ),
        ),
      );
    } catch (e) {
      state = state.copyWith(listening: false, error: 'Dictation failed: $e');
    }
  }

  bool _naturalListening() {
    final settings = ref.read(settingsProvider);
    final packs = ref.read(voiceModelsProvider);
    if (settings.listeningModel == 'android-local') return false;
    if (settings.listeningModel == 'vosk-fa') return false;
    if (voiceLanguage(settings.localeCode) == 'fa') {
      // Natural voice is not consent to silently replace Android STT.
      return settings.listeningModel == PersianSttPolicy.whisper &&
          packs.of(VoiceModels.listening).status == VoicePackStatus.ready;
    }
    return offlineVoiceReady(
      enabled: settings.naturalVoice,
      installed: packs.canListen,
    );
  }

  bool _naturalSpeaking() =>
      naturalVoiceSpeaks(
        voiceLanguageForText(
          ref.read(settingsProvider).localeCode,
          _spokenText,
        ),
      ) &&
      offlineVoiceReady(
        enabled: ref.read(settingsProvider).naturalVoice,
        installed: ref
            .read(voiceModelsProvider)
            .canSpeakWith(ref.read(settingsProvider).readingVoice),
      );

  /// The voice for the app language and the chosen speaker.
  KokoroVoice kokoroVoice() {
    final s = ref.read(settingsProvider);
    if (s.readingVoice == VoiceModels.supertonic.id) {
      return KokoroVoice(
        s.supertonicSid,
        voiceLanguage(s.localeCode),
        'Supertonic 2',
      );
    }
    return KokoroVoice.forLanguage(
      voiceLanguage(s.localeCode),
      sid: s.kokoroSid < 0 ? null : s.kokoroSid,
    );
  }

  /// Dictation through Whisper: captions while speaking, each sentence
  /// added when the user pauses, and listening goes on across pauses until
  /// the user stops (or 20 s of silence). One pause used to end it, so a
  /// long prompt kept only its first sentences. False when the microphone
  /// could not start.
  Future<bool> _listenWhisper(
    ValueChanged<String> onText,
    ValueChanged<String>? onFinal,
  ) async {
    final voice = ref.read(sherpaVoiceProvider);
    _whisper?.dispose();
    var heard = false;
    final said = <String>[];
    String withSaid(String text) =>
        [...said, if (text.isNotEmpty) text].join(' ');
    void idle(Duration after) {
      _whisperIdle?.cancel();
      _whisperIdle = Timer(after, () {
        if (_alive && state.listening) unawaited(stop());
      });
    }

    late final WhisperListener listener;
    listener = _whisper = WhisperListener(
      voice: voice,
      language: voiceLanguage(ref.read(settingsProvider).localeCode),
      endSilence: 1.0,
      captionAll: true,
      onSpeechStart: () {
        heard = true;
        _whisperIdle?.cancel();
      },
      onPartial: (text) {
        if (!_alive) return;
        final all = withSaid(text);
        state = state.copyWith(partial: all);
        onText(all);
      },
      onFinal: (text) {
        if (!_alive) return;
        said.add(text);
        final all = withSaid('');
        state = state.copyWith(partial: all);
        onText(all);
        if (identical(_whisper, listener)) idle(const Duration(seconds: 20));
      },
    );
    _whisperDone = () {
      final all = withSaid('');
      if (all.isNotEmpty) onText(all);
      onFinal?.call(all);
    };
    state = state.copyWith(
      listening: true,
      available: true,
      partial: '',
      clearError: true,
    );
    if (!await listener.start()) {
      _whisper = null;
      listener.dispose();
      if (_alive) state = state.copyWith(listening: false);
      return false;
    }
    if (!_alive || !identical(_whisper, listener)) {
      await listener.stop();
      return true;
    }
    // Nothing said within 8 s ends the session like the system recognizer.
    _whisperIdle?.cancel();
    _whisperIdle = Timer(const Duration(seconds: 8), () {
      if (!heard && _alive && state.listening) {
        unawaited(_stopWhisper());
        state = state.copyWith(
          listening: false,
          error: _explain('error_speech_timeout'),
        );
      }
    });
    return true;
  }

  /// Stops the Whisper dictation; the sentence being said is still
  /// transcribed and kept.
  Future<void> _stopWhisper() async {
    _whisperIdle?.cancel();
    final w = _whisper;
    final done = _whisperDone;
    _whisper = null;
    _whisperDone = null;
    if (_alive && w != null) state = state.copyWith(listening: false);
    await w?.finish();
    w?.dispose();
    if (_alive) done?.call();
  }

  Future<void> stop() async {
    _listenEpoch++;
    if (_ctc != null) {
      final listener = _ctc;
      _ctc = null;
      await listener?.stop();
      if (_alive) state = state.copyWith(listening: false);
      return;
    }
    if (_whisper != null) {
      await _stopWhisper();
      if (_alive) state = state.copyWith(listening: false);
      return;
    }
    try {
      if (_usingOffline) {
        await _offline?.stop();
      } else {
        await _stt?.stop();
      }
    } on PlatformException catch (e) {
      if (_alive) {
        state = state.copyWith(error: 'Could not stop dictation: ${e.message}');
      }
    } finally {
      if (_alive) state = state.copyWith(listening: false);
    }
  }

  Future<void> _initTts() async {
    final running = _ttsInitialization;
    if (running != null) return running;
    final initialization = _initializeTts();
    _ttsInitialization = initialization;
    try {
      await initialization;
    } catch (_) {
      _ttsInitialization = null;
      _tts = null;
      rethrow;
    }
  }

  Future<void> _initializeTts() async {
    _tts = FlutterTts();
    await _tts!.awaitSpeakCompletion(true);
    _tts!.setProgressHandler((text, start, end, word) {
      if (_alive && state.speaking) {
        _position = (_chunkStart + end).clamp(0, _spokenText.length);
      }
    });
    _tts!.setErrorHandler((e) {
      if (!_alive) return;
      state = state.copyWith(
        speaking: false,
        clearSpeakingId: true,
        error: 'Read-aloud failed: $e',
      );
    });
  }

  Future<(List<String>, String?)> androidTtsEngines() async {
    await _initTts();
    final raw = await _tts!.getEngines;
    final engines = raw is List ? raw.whereType<String>().toList() : <String>[];
    final prefs = await SharedPreferences.getInstance();
    final system = await _tts!.getDefaultEngine as String?;
    final selected = prefs.getString(_androidTtsEngineKey) ?? system;
    return (engines, engines.contains(selected) ? selected : null);
  }

  /// Installed offline Persian voices of the currently selected Android
  /// engine. Individual voice choice is independent from the STT model.
  Future<(List<Map<String, String>>, String?)> androidPersianTtsVoices() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return (const <Map<String, String>>[], null);
    }
    await _initTts();
    final prefs = await SharedPreferences.getInstance();
    final chosenEngine = prefs.getString(_androidTtsEngineKey);
    if (chosenEngine != null && chosenEngine.isNotEmpty) {
      await _tts!.setEngine(chosenEngine);
    }
    final available = offlinePersianVoiceOptions(await _tts!.getVoices);
    final selected = prefs.getString(_androidTtsVoiceKey);
    return (
      available,
      available.any((item) => item['name'] == selected) ? selected : null,
    );
  }

  Future<bool> setAndroidPersianTtsVoice(String name) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await stopSpeaking();
      final (voices, _) = await androidPersianTtsVoices();
      final candidates = voices.where((v) => v['name'] == name).toList();
      if (candidates.isEmpty) return false;
      final voice = candidates.first;
      final result = await _tts!.setVoice(voice);
      if (result != 1) return false;
      final saved = await (await SharedPreferences.getInstance()).setString(
        _androidTtsVoiceKey,
        name,
      );
      if (saved) await VoiceChoiceStorage.clear(VoiceSelectionKind.tts);
      return saved;
    } catch (_) {
      return false;
    }
  }

  /// Selects an installed Android engine only when it exposes an offline
  /// Persian voice. An incompatible choice leaves the current engine intact.
  Future<bool> setAndroidTtsEngine(String engine) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    String? previous;
    try {
      // Do not overlap voices when the user selects another Android engine.
      await stopSpeaking();
      await _initTts();
      final prefs = await SharedPreferences.getInstance();
      previous =
          prefs.getString(_androidTtsEngineKey) ??
          await _tts!.getDefaultEngine as String?;
      await _tts!.setEngine(engine);
      final voices = await _tts!.getVoices;
      final hasOfflinePersian =
          voices is List &&
          voices.any((voice) {
            if (voice is! Map || voice['locale'] is! String) return false;
            final language = (voice['locale'] as String)
                .split(RegExp(r'[-_]'))
                .first
                .toLowerCase();
            return language == 'fa' &&
                (voice['network_required'] == '0' ||
                    voice['network_required'] == false) &&
                !'${voice['features'] ?? ''}'.contains('notInstalled');
          });
      if (!hasOfflinePersian) {
        if (previous is String && previous.isNotEmpty) {
          await _tts!.setEngine(previous);
        }
        return false;
      }
      final saved = await prefs.setString(_androidTtsEngineKey, engine);
      if (saved) {
        await prefs.remove(_androidTtsVoiceKey);
        await VoiceChoiceStorage.clear(VoiceSelectionKind.tts);
      }
      if (!saved && previous is String && previous.isNotEmpty) {
        await _tts!.setEngine(previous);
      }
      return saved;
    } catch (_) {
      if (previous is String && previous.isNotEmpty) {
        try {
          await _tts!.setEngine(previous);
        } catch (_) {}
      }
      return false;
    }
  }

  /// Reads [markdown] aloud; tapping the same message again stops it.
  Future<void> speak(String markdown, {String? id, double? rate}) async {
    final futureChoice = await VoiceChoiceStorage.current(
      VoiceSelectionKind.tts,
    );
    if (futureChoice != null) {
      final choice = VoiceEngineSelection.parse(futureChoice);
      // Device-trial route only. This ID has no installer/UI entry, and
      // cannot be selected automatically while Pocket is unverified.
      if (choice?.kind == VoiceSelectionKind.tts &&
          choice?.adapter == 'pocket-farsi-v2' &&
          choice?.model == 'onnx') {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
          state = state.copyWith(
            speaking: false,
            error: 'Pocket Farsi v2 فقط روی اندروید آزمایشی اجرا می‌شود.',
          );
          return;
        }
        if (state.speaking && (id == null || id == state.speakingId)) {
          return pauseSpeaking();
        }
        if (state.paused && id == state.speakingId) {
          return resumeSpeaking();
        }
        return _speakPocket(speakable(markdown), id: id);
      }
      final model =
          choice?.kind == VoiceSelectionKind.tts && choice?.adapter == 'piper'
          ? await PersianSherpaModels.find(PersianSherpaKind.tts, choice!.model)
          : null;
      if (model == null) {
        state = state.copyWith(
          speaking: false,
          clearSpeakingId: true,
          error:
              'مدل TTS انتخابی یا آداپتور آن آماده نیست؛ '
              'موتور دیگری خودکار اجرا نمی‌شود.',
        );
        return;
      }
      if (state.speaking && (id == null || id == state.speakingId)) {
        return pauseSpeaking();
      }
      final text = speakable(markdown);
      if (text.isEmpty) return;
      final epoch = ++_speechEpoch;
      await _stopTts();
      await _kokoro?.stop();
      await _piper?.stop();
      if (!_alive || epoch != _speechEpoch) return;
      _spokenText = text;
      _position = 0;
      state = state.copyWith(
        speaking: true,
        paused: false,
        speakingId: id,
        clearError: true,
      );
      final piper = _piper ??= PersianPiperSpeaker();
      try {
        for (final chunk in chunks(text, limit: 240)) {
          if (!_alive || epoch != _speechEpoch) return;
          final played = await piper.play(
            model,
            chunk,
            speed: ref.read(settingsProvider).readingSpeed,
          );
          if (!_alive || epoch != _speechEpoch) return;
          if (!played) {
            throw StateError('پخش صدای Piper کامل نشد.');
          }
          _position += chunk.length;
        }
        if (_alive && epoch == _speechEpoch) {
          state = state.copyWith(
            speaking: false,
            paused: false,
            clearSpeakingId: true,
          );
        }
      } catch (_) {
        if (_alive && epoch == _speechEpoch) {
          state = state.copyWith(
            speaking: false,
            clearSpeakingId: true,
            error: 'موتور Piper فارسی نتوانست پاسخ را پخش کند.',
          );
        }
      }
      return;
    }
    final preferred = ref.read(settingsProvider).readingVoice;
    if (preferred != 'kokoro' && preferred != 'supertonic-2') {
      state = state.copyWith(
        speaking: false,
        clearSpeakingId: true,
        error:
            'مدل TTS انتخابی در تنظیمات حفظ شده، اما آداپتور آن '
            'آماده نیست. صدای دیگری خودکار پخش نمی‌شود.',
      );
      return;
    }
    await _initTts();
    if (state.speaking && (id == null || id == state.speakingId)) {
      return pauseSpeaking();
    }
    if (state.paused && id == state.speakingId) return resumeSpeaking();
    final text = speakable(markdown);
    if (text.isEmpty) return;
    _speechEpoch++;
    await _stopTts();
    await _kokoro?.stop();
    await _piper?.stop();
    _rate = rate ?? 0.5 * ref.read(settingsProvider).readingSpeed;
    _spokenText = text;
    if (_naturalSpeaking()) {
      _spokenText = text;
      _sentences = KokoroSpeaker.sentences(text);
      _sentence = 0;
      state = state.copyWith(
        speaking: true,
        paused: false,
        speakingId: id,
        clearError: true,
      );
      _readKokoro();
      return;
    }
    _spokenText = text;
    _position = 0;
    _rate = rate ?? 0.5 * ref.read(settingsProvider).readingSpeed;
    state = state.copyWith(
      speaking: true,
      paused: false,
      speakingId: id,
      clearError: true,
    );
    await _read();
  }

  /// Only reachable through the explicit, experimental Pocket adapter ID.
  /// No automatic switching of Gyro, Piper, or the user's stored voice.
  Future<void> _speakPocket(String text, {String? id}) async {
    if (text.isEmpty) return;
    final epoch = ++_speechEpoch;
    await _stopTts();
    await _kokoro?.stop();
    await _piper?.stop();
    final older = _pocketReader;
    if (older != null) await older.cancel();
    if (!_alive || epoch != _speechEpoch) return;
    final reader = _pocketReader = PocketFarsiLongReader();
    _spokenText = text;
    _position = 0;
    state = state.copyWith(
      speaking: true,
      paused: false,
      speakingId: id,
      clearError: true,
    );
    try {
      await reader.read(text);
      if (_alive && epoch == _speechEpoch) {
        state = state.copyWith(
          speaking: false,
          paused: false,
          clearSpeakingId: true,
        );
      }
    } catch (_) {
      if (_alive && epoch == _speechEpoch) {
        state = state.copyWith(
          speaking: false,
          paused: false,
          clearSpeakingId: true,
          error: 'موتور Pocket هنوز برای این متن یا بسته مدل آماده نیست.',
        );
      }
    }
  }

  Future<void> _resumePocket() async {
    final reader = _pocketReader;
    if (reader == null || !reader.progress.paused) return;
    final epoch = ++_speechEpoch;
    state = state.copyWith(speaking: true, paused: false, clearError: true);
    try {
      await reader.resume();
      if (_alive && epoch == _speechEpoch) {
        state = state.copyWith(
          speaking: false,
          paused: false,
          clearSpeakingId: true,
        );
      }
    } catch (_) {
      if (_alive && epoch == _speechEpoch) {
        state = state.copyWith(
          speaking: false,
          paused: false,
          error: 'ادامه خواندن Pocket ناموفق بود؛ صدای دیگری جایگزین نشد.',
        );
      }
    }
  }

  /// Android voices may stream from the network: pick one flutter_tts
  /// reports as local ("0"). Windows voices (SAPI/OneCore) are all local.
  Future<bool> _selectOfflineVoice() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    final prefs = await SharedPreferences.getInstance();
    final savedEngine = prefs.getString(_androidTtsEngineKey);
    final explicitlyChosenVoice = prefs.getString(_androidTtsVoiceKey);
    if (savedEngine != null && savedEngine.isNotEmpty) {
      try {
        await _tts!.setEngine(savedEngine);
      } catch (_) {
        return false;
      }
    }
    String? preferredVoice = explicitlyChosenVoice;
    try {
      final current = await _tts!.getDefaultVoice;
      if (preferredVoice == null &&
          current is Map &&
          current['name'] is String &&
          current['locale'] is String &&
          (current['locale'] as String)
                  .split(RegExp(r'[-_]'))
                  .first
                  .toLowerCase() ==
              voiceLanguageForText(
                ref.read(settingsProvider).localeCode,
                _spokenText,
              )) {
        preferredVoice = current['name'] as String;
      }
    } catch (_) {}
    final language = voiceLanguageForText(
      ref.read(settingsProvider).localeCode,
      _spokenText,
    );
    final selected = await selectOfflineVoice(
      language: language,
      voices: () => _tts!.getVoices,
      select: (voice) => _tts!.setVoice(voice),
      preferredName: preferredVoice,
    );
    if (selected || explicitlyChosenVoice != null) return selected;
    // Without an explicit user choice, prefer any verified local voice
    // over a default that is missing or requires the network.
    return selectOfflineVoice(
      language: language,
      voices: () => _tts!.getVoices,
      select: (voice) => _tts!.setVoice(voice),
    );
  }

  Future<void> _read() async {
    final epoch = ++_speechEpoch;
    final release = InferenceAdmission.shared.hold();
    try {
      if (!await _selectOfflineVoice()) {
        if (_alive && epoch == _speechEpoch) {
          state = state.copyWith(
            speaking: false,
            clearSpeakingId: true,
            error: stringsFor(ref.read(settingsProvider).localeCode)
                .voiceOfflineUnavailable,
          );
        }
        return;
      }
      if (!_alive || epoch != _speechEpoch) return;
      await _tts!.setSpeechRate(_rate);
      for (final chunk in chunks(_spokenText.substring(_position))) {
        if (!_alive || epoch != _speechEpoch) return;
        _chunkStart = _position;
        _ttsBusy = true;
        try {
          final completed = await _tts!.speak(chunk);
          if (defaultTargetPlatform == TargetPlatform.android &&
              completed != 1 &&
              _alive &&
              epoch == _speechEpoch) {
            throw StateError('خواندن با صدای آفلاین تأیید نشد.');
          }
        } finally {
          _ttsBusy = false;
        }
        if (!_alive || epoch != _speechEpoch) return;
        _position = _chunkStart + chunk.length;
      }
      if (_alive && epoch == _speechEpoch) {
        state = state.copyWith(
          speaking: false,
          paused: false,
          clearSpeakingId: true,
        );
      }
    } catch (e) {
      if (!_alive || epoch != _speechEpoch) return;
      state = state.copyWith(
        speaking: false,
        clearSpeakingId: true,
        error: 'Read-aloud failed: $e',
      );
    } finally {
      release();
    }
  }

  /// Kokoro from sentence [_sentence]; falls back to the system voice when
  /// synthesis fails.
  void _readKokoro() {
    final epoch = _speechEpoch;
    final speaker = _kokoro ??= KokoroSpeaker(
      voice: ref.read(sherpaVoiceProvider),
      kokoro: kokoroVoice(),
    );
    speaker
      ..kokoro = kokoroVoice()
      ..speed = (_rate / 0.5).clamp(0.6, 1.6)
      ..onSentence = (s) {
        if (epoch != _speechEpoch) return;
        final at = _sentences.indexOf(s, _sentence);
        if (at >= 0) _sentence = at;
      }
      ..onIdle = () {
        if (!_alive || epoch != _speechEpoch) return;
        state = state.copyWith(
          speaking: false,
          paused: false,
          clearSpeakingId: true,
        );
      }
      ..onError = (e) {
        if (!_alive || epoch != _speechEpoch) return;
        // The system voice takes over from the start of the sentence.
        _speechEpoch++;
        unawaited(speaker.stop());
        final from = _sentences.skip(_sentence).join(' ');
        _sentences = const [];
        _spokenText = from;
        _position = 0;
        unawaited(_initTts().then((_) => _read()));
      };
    speaker.add(_sentences.skip(_sentence).join('\n'));
  }

  Future<void> _stopTts() async {
    if (!_ttsBusy) return;
    _ttsBusy = false;
    await _tts?.stop();
  }

  Future<void> pauseSpeaking() async {
    _speechEpoch++;
    state = state.copyWith(speaking: false, paused: true);
    await _stopTts();
    await _kokoro?.stop();
    await _piper?.stop();
    if (_pocketReader?.isRunning == true) await _pocketReader?.pause();
  }

  Future<void> resumeSpeaking() async {
    if (!state.paused || _spokenText.isEmpty) return;
    if (_pocketReader?.progress.paused == true &&
        await VoiceChoiceStorage.current(VoiceSelectionKind.tts) ==
            'tts:pocket-farsi-v2:onnx') {
      return _resumePocket();
    }
    if (await VoiceChoiceStorage.current(VoiceSelectionKind.tts) != null) {
      final messageId = state.speakingId;
      final utterance = _spokenText;
      state = state.copyWith(speaking: false, paused: false);
      return speak(utterance, id: messageId);
    }
    state = state.copyWith(speaking: true, paused: false);
    if (_sentences.isNotEmpty) {
      _speechEpoch++;
      _readKokoro();
      return;
    }
    await _read();
  }

  Future<void> stopSpeaking() async {
    _speechEpoch++;
    _spokenText = '';
    _position = 0;
    _sentences = const [];
    if (_pocketReader != null &&
        (_pocketReader!.isRunning || _pocketReader!.progress.paused)) {
      await _pocketReader!.cancel();
    }
    await _stopTts();
    await _kokoro?.stop();
    await _piper?.stop();
    if (_alive) {
      state = state.copyWith(
        speaking: false,
        paused: false,
        clearSpeakingId: true,
      );
    }
  }
}

final voiceProvider = NotifierProvider<VoiceNotifier, VoiceState>(
  VoiceNotifier.new,
);

/// The sherpa-onnx engines (Kokoro, Whisper), shared by read-aloud,
/// dictation and the conversation screen.
final sherpaVoiceProvider = Provider<SherpaVoice>((ref) {
  final voice = SherpaVoice();
  ref.onDispose(voice.dispose);
  // A pack deleted or being downloaded again: its worker must not go on
  // with the old files.
  ref.listen(voiceModelsProvider, (before, now) {
    for (final pack in VoiceModels.all) {
      final was = before?.of(pack).status == VoicePackStatus.ready;
      final isReady = now.of(pack).status == VoicePackStatus.ready;
      // Gone, or Parakeet just arrived: the listener picks again.
      if ((was && !isReady) ||
          (!was && isReady && pack.id == VoiceModels.parakeet.id)) {
        voice.releasePack(speaking: pack.unpackTo != null);
      }
    }
  });
  voice.readingVoice = ref.read(settingsProvider).readingVoice;
  ref.listen(
    settingsProvider.select((s) => s.readingVoice),
    (_, id) => voice.readingVoice = id,
  );
  String effectiveListeningModel(InferenceSettings settings) =>
      voiceLanguage(settings.localeCode) == 'fa' ? '' : settings.listeningModel;
  voice.listeningModel = effectiveListeningModel(ref.read(settingsProvider));
  ref.listen(
    settingsProvider.select((s) => (s.listeningModel, s.localeCode)),
    (_, values) => voice.listeningModel = effectiveListeningModel(
      ref.read(settingsProvider),
    ),
  );
  return voice;
});
