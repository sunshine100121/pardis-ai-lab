import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/core/theme/app_theme.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'package:ondevice_llm/features/voice/voice_models.dart';
import 'package:ondevice_llm/features/voice/offline_dictation.dart';
import 'package:ondevice_llm/features/voice/voice_models_provider.dart';
import 'package:ondevice_llm/features/voice/voice_settings.dart';
import 'package:ondevice_llm/features/voice/voice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final InferenceSettings initial;
  @override
  InferenceSettings build() {
    ready = Future.value();
    return initial;
  }

  @override
  Future<void> update(InferenceSettings next) async {
    state = next;
  }
}

class _Models extends ModelManagerNotifier {
  @override
  ModelManagerState build() {
    ready = Future.value();
    return const ModelManagerState(catalog: []);
  }
}

class _Packs extends VoiceModelsNotifier {
  _Packs(this.ready);
  final Set<String> ready;
  final downloaded = <VoicePack>[];
  final removed = <VoicePack>[];

  @override
  Future<void> download(VoicePack pack) async {
    downloaded.add(pack);
    state = VoiceModelsState({
      ...state.packs,
      pack.id: const VoicePackState(VoicePackStatus.ready),
    });
  }

  @override
  Future<void> delete(VoicePack pack) async {
    removed.add(pack);
    state = VoiceModelsState({
      ...state.packs,
      pack.id: const VoicePackState(VoicePackStatus.missing),
    });
  }

  @override
  VoiceModelsState build() => VoiceModelsState({
    for (final p in VoiceModels.all)
      p.id: VoicePackState(
        ready.contains(p.id) ? VoicePackStatus.ready : VoicePackStatus.missing,
      ),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OfflineDictation.channel, (call) async {
          if (call.method == 'capabilities') {
            return {'androidOfflineAvailable': true, 'apiLevel': 35};
          }
          return null;
        });
  });

  test(
    'failed TTS change restores the saved engine, not system default',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'pala_voice_android_tts_engine_v1': 'saved.engine',
      });
      const channel = MethodChannel('flutter_tts');
      final engines = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'setEngine')
              engines.add(call.arguments as String);
            if (call.method == 'getDefaultEngine') return 'system.engine';
            if (call.method == 'getVoices') return <Map<String, String>>[];
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(const InferenceSettings()),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        await container
            .read(voiceProvider.notifier)
            .setAndroidTtsEngine('bad.engine'),
        isFalse,
      );
      expect(engines, ['bad.engine', 'saved.engine']);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'pala_voice_android_tts_engine_v1',
        ),
        'saved.engine',
      );
    },
  );

  test(
    'selecting a Persian TTS engine persists independently of STT',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getDefaultEngine') return 'system.engine';
            if (call.method == 'getEngines') return ['fa.engine'];
            if (call.method == 'getVoices') {
              return [
                {'locale': 'fa-IR', 'name': 'voice', 'network_required': '0'},
              ];
            }
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(const InferenceSettings(listeningModel: 'vosk-fa')),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        await container
            .read(voiceProvider.notifier)
            .setAndroidTtsEngine('fa.engine'),
        isTrue,
      );
      expect(container.read(settingsProvider).listeningModel, 'vosk-fa');
      final reopened = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(const InferenceSettings(listeningModel: 'vosk-fa')),
          ),
        ],
      );
      addTearDown(reopened.dispose);
      final available = await reopened
          .read(voiceProvider.notifier)
          .androidTtsEngines();
      expect(available.$1, ['fa.engine']);
      expect(available.$2, 'fa.engine');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'pala_voice_android_tts_engine_v1',
        ),
        'fa.engine',
      );
    },
  );

  test('failed TTS initialization can be retried', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('flutter_tts');
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'awaitSpeakCompletion' && attempts++ == 0) {
            throw PlatformException(code: 'init_failed');
          }
          if (call.method == 'getDefaultEngine') return 'system.engine';
          if (call.method == 'getVoices') {
            return [
              {'locale': 'fa-IR', 'name': 'voice', 'network_required': '0'},
            ];
          }
          return 1;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => _Settings(const InferenceSettings()),
        ),
      ],
    );
    addTearDown(container.dispose);
    final voice = container.read(voiceProvider.notifier);
    expect(await voice.setAndroidTtsEngine('fa.engine'), isFalse);
    expect(await voice.setAndroidTtsEngine('fa.engine'), isTrue);
    expect(attempts, 2);
  });

  test('legacy and new listening preferences survive settings decoding', () {
    for (final value in [
      '',
      'parakeet-v3',
      'android-local',
      'whisper-fa',
      'vosk-fa',
    ]) {
      final settings = InferenceSettings.fromJson({'listeningModel': value});
      expect(settings.listeningModel, value);
      expect(
        InferenceSettings.fromJson(settings.toJson()).listeningModel,
        value,
      );
    }
    expect(
      InferenceSettings.fromJson({'listeningModel': 'invalid'}).listeningModel,
      '',
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required Set<String> ready,
    InferenceSettings settings = const InferenceSettings(),
  }) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(settings)),
        modelManagerProvider.overrideWith(_Models.new),
        voiceModelsProvider.overrideWith(() => _Packs(ready)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: NaturalVoiceSettings()),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('Persian voice settings remain scrollable with installed packs', (
    tester,
  ) async {
    await pump(
      tester,
      ready: {VoiceModels.listening.id, VoiceModels.voskPersian.id},
      settings: const InferenceSettings(localeCode: 'fa', naturalVoice: true),
    );
    tester.view.physicalSize = const Size(360, 640);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('voice-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-remove')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('STT test starts and stops only on user action', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OfflineDictation.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'capabilities') {
            return {'androidOfflineAvailable': true, 'apiLevel': 35};
          }
          return null;
        });
    final container = await pump(
      tester,
      ready: {},
      settings: const InferenceSettings(
        localeCode: 'fa',
        listeningModel: 'android-local',
      ),
    );
    await tester.pump();
    expect(calls, isNot(contains('listen')));
    await tester.ensureVisible(find.byKey(const Key('persian-stt-try')));
    await tester.tap(find.byKey(const Key('persian-stt-try')));
    await tester.pump();
    expect(calls, contains('listen'));
    expect(container.read(voiceProvider).listening, isTrue);
    await tester.tap(find.byKey(const Key('persian-stt-try')));
    await tester.pump();
    expect(calls, contains('stop'));
    expect(container.read(voiceProvider).listening, isFalse);
  });

  testWidgets('STT test cannot start an uninstalled selected model', (
    tester,
  ) async {
    await pump(
      tester,
      ready: {},
      settings: const InferenceSettings(
        localeCode: 'fa',
        listeningModel: 'vosk-fa',
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('persian-stt-try')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('Parakeet is offered as a download and chosen only when there', (
    tester,
  ) async {
    await pump(
      tester,
      ready: {VoiceModels.listening.id, VoiceModels.speaking.id},
      settings: const InferenceSettings(localeCode: 'en'),
    );
    expect(find.byKey(const Key('listening-model')), findsOneWidget);
    expect(find.byKey(const Key('parakeet-add')), findsOneWidget);
    expect(find.textContaining('640 MB'), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const Key('listening-parakeet')),
    );
    expect(chip.onSelected, isNull, reason: 'not downloaded yet');
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('listening-whisper')))
          .selected,
      isTrue,
    );
  });

  testWidgets('a downloaded Parakeet can be picked', (tester) async {
    final container = await pump(
      tester,
      ready: {
        VoiceModels.listening.id,
        VoiceModels.speaking.id,
        VoiceModels.parakeet.id,
      },
      settings: const InferenceSettings(localeCode: 'en'),
    );
    expect(find.byKey(const Key('parakeet-remove')), findsOneWidget);
    await tester.tap(find.byKey(const Key('listening-parakeet')));
    await tester.pump();
    expect(
      container.read(settingsProvider).listeningModel,
      VoiceModels.parakeetSetting,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('listening-parakeet')))
          .selected,
      isTrue,
    );
  });

  testWidgets(
    'Persian settings preserve installed speech pack and download only Whisper',
    (tester) async {
      final container = await pump(
        tester,
        ready: {VoiceModels.speaking.id},
        settings: const InferenceSettings(localeCode: 'fa', naturalVoice: true),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('kokoro-voice')), findsNothing);
      expect(find.byKey(const Key('reading-kokoro')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('voice-add')));
      await tester.tap(find.byKey(const Key('voice-add')));
      await tester.pump();
      final packs = container.read(voiceModelsProvider.notifier) as _Packs;
      expect(packs.downloaded, [VoiceModels.listening]);
      expect(container.read(voiceModelsProvider).canSpeak, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Persian STT selection persists independently of TTS preferences',
    (tester) async {
      final container = await pump(
        tester,
        ready: {VoiceModels.listening.id, VoiceModels.parakeet.id},
        settings: const InferenceSettings(
          localeCode: 'fa',
          readingVoice: 'supertonic-2',
        ),
      );
      expect(find.byKey(const Key('listening-parakeet')), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('persian-stt-vosk')))
            .onSelected,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const Key('persian-stt-android')));
      await tester.tap(find.byKey(const Key('persian-stt-android')));
      await tester.pump();
      expect(container.read(settingsProvider).listeningModel, 'android-local');
      expect(container.read(settingsProvider).readingVoice, 'supertonic-2');
      final reloaded = InferenceSettings.fromJson(
        container.read(settingsProvider).toJson(),
      );
      expect(reloaded.listeningModel, 'android-local');
      await tester.tap(find.byKey(const Key('persian-stt-whisper')));
      await tester.pump();
      expect(container.read(settingsProvider).listeningModel, 'whisper-fa');
      expect(
        InferenceSettings.fromJson(container.read(settingsProvider).toJson())
            .listeningModel,
        'whisper-fa',
      );
      expect(container.read(settingsProvider).readingVoice, 'supertonic-2');
    },
  );

  testWidgets('Vosk must be installed before selection and stays independent', (
    tester,
  ) async {
    final container = await pump(
      tester,
      ready: {VoiceModels.listening.id, VoiceModels.speaking.id},
      settings: const InferenceSettings(
        localeCode: 'fa',
        readingVoice: 'supertonic-2',
      ),
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('persian-stt-vosk')))
          .onSelected,
      isNull,
    );
    await tester.tap(find.byKey(const Key('vosk-download')));
    await tester.pump();
    final notifier = container.read(voiceModelsProvider.notifier) as _Packs;
    expect(notifier.downloaded, [VoiceModels.voskPersian]);
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('persian-stt-vosk')))
          .onSelected,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('persian-stt-vosk')));
    await tester.pump();
    final settings = container.read(settingsProvider);
    expect(settings.listeningModel, 'vosk-fa');
    expect(settings.readingVoice, 'supertonic-2');
    expect(
      InferenceSettings.fromJson(settings.toJson()).listeningModel,
      'vosk-fa',
    );
  });

  testWidgets(
    'selecting missing Supertonic offers its download and preserves Kokoro',
    (tester) async {
      final container = await pump(
        tester,
        ready: {VoiceModels.listening.id, VoiceModels.speaking.id},
        settings: const InferenceSettings(localeCode: 'en'),
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('reading-kokoro')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('reading-supertonic-2')));
      await tester.pump();
      expect(container.read(settingsProvider).readingVoice, 'supertonic-2');
      expect(find.textContaining('Supertonic 2'), findsWidgets);
      expect(find.byKey(const Key('voice-add')), findsOneWidget);
      expect(find.byKey(const Key('kokoro-voice')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('voice-add')));
      await tester.tap(find.byKey(const Key('voice-add')));
      await tester.pump();
      final packs = container.read(voiceModelsProvider.notifier) as _Packs;
      expect(packs.downloaded, [VoiceModels.supertonic]);
      expect(
        container.read(voiceModelsProvider).canSpeakWith('kokoro'),
        isTrue,
      );
      expect(find.text('Voice 10'), findsOneWidget);
      await tester.ensureVisible(find.text('Voice 5'));
      await tester.tap(find.text('Voice 5'));
      await tester.pump();
      expect(container.read(settingsProvider).supertonicSid, 4);
      await tester.ensureVisible(find.byKey(const Key('voice-remove')));
      await tester.tap(find.byKey(const Key('voice-remove')));
      await tester.pump();
      expect(packs.removed, [VoiceModels.listening, VoiceModels.supertonic]);
      expect(
        container.read(voiceModelsProvider).canSpeakWith('kokoro'),
        isTrue,
      );
      expect(find.byKey(const Key('voice-add')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reading-kokoro')));
      await tester.tap(find.byKey(const Key('reading-kokoro')));
      await tester.pump();
      expect(container.read(settingsProvider).readingVoice, 'kokoro');
      expect(find.text('Heart'), findsOneWidget);
    },
  );
}
