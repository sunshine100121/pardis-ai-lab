import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/pocket_farsi_v2_audio.dart';
import 'package:ondevice_llm/features/voice/pocket_farsi_v2_reader.dart';
import 'package:ondevice_llm/features/voice/sherpa_voice.dart';

PocketGeneratedAudio fakeClip() => PocketGeneratedAudio(
  SpeechAudio(Int16List.fromList([0, 10, -10, 0]), 24000),
  25,
  1,
);

void main() {
  test('long Persian paragraphs are fully preserved in bounded sections', () {
    final input = List.filled(
      25,
      'امروز دمای باغ ۲۳ درجه است، و رطوبت خاک رزماری ۴۵ درصد است.',
    ).join(' ');
    final plan = PocketPersianTextPlan.split(input);
    expect(plan.length, greaterThan(4));
    expect(plan.every((p) => p.length <= 200 && p.isNotEmpty), isTrue);
    expect(plan.join(' ').replaceAll(RegExp(r'\s+'), ' '), input);
  });

  test('prefer the nearest phrase stop instead of mid-clause splitting', () {
    final text = List.filled(15, 'باران شروع شده است.').join(' ');
    final plan = PocketPersianTextPlan.split(text, maxCharacters: 75);
    expect(plan.length, greaterThan(1));
    expect(plan.first.endsWith('.'), isTrue);
    expect(plan.every((p) => p.length <= 75), isTrue);
  });

  test('reject exceptionally long unsplittable word without dropping parts', () {
    final text = List.filled(300, 'آ').join('');
    expect(
      () => PocketPersianTextPlan.split(text),
      throwsFormatException,
    );
  });

  test('read twenty sections in order without a global 250-character cap',
      () async {
    final spoken = <String>[];
    var playback = 0;
    final reader = PocketFarsiLongReader(
      synthesize: (piece) async {
        spoken.add(piece);
        return fakeClip();
      },
      play: (audio) async {
        playback++;
        return true;
      },
      stopPlayback: () async {},
    );
    final text = List.filled(42, 'صدای طبیعی فارسی در باغ شنیده می‌شود.').join(' ');
    final expected = PocketPersianTextPlan.split(text);
    final result = await reader.read(text);
    expect(result.finished, isTrue);
    expect(result.completed, expected.length);
    expect(spoken, expected);
    expect(playback, expected.length);
  });

  test('pause interrupts audio and resume repeats the unfinished segment',
      () async {
    final firstPlayback = Completer<bool>();
    final utterances = <String>[];
    final reader = PocketFarsiLongReader(
      synthesize: (part) async {
        utterances.add(part);
        return fakeClip();
      },
      play: (audio) async {
        if (utterances.length == 1) return firstPlayback.future;
        return true;
      },
      stopPlayback: () async {
        if (!firstPlayback.isCompleted) firstPlayback.complete(false);
      },
    );
    final text = List.filled(9, 'روز خوبی است.').join(' ');
    final reading = reader.read(text);
    await Future<void>.delayed(Duration.zero);
    await reader.pause();
    final paused = await reading;
    expect(paused.paused, isTrue);
    expect(paused.completed, 0);
    final result = await reader.resume();
    expect(result.finished, isTrue);
    expect(utterances.first, utterances[1]);
  });

  test('failed native generation stops reading without a fallback voice',
      () async {
    var played = false;
    final reader = PocketFarsiLongReader(
      synthesize: (_) async => throw StateError('model not installed'),
      play: (_) async {
        played = true;
        return true;
      },
      stopPlayback: () async {},
    );
    await expectLater(reader.read('سلام'), throwsStateError);
    expect(played, isFalse);
  });

  test('cancel during synthesis does not play stale audio', () async {
    final first = Completer<PocketGeneratedAudio>();
    var played = false;
    final reader = PocketFarsiLongReader(
      synthesize: (_) => first.future,
      play: (_) async {
        played = true;
        return true;
      },
      stopPlayback: () async {},
    );
    final task = reader.read('سلام، امروز هوا عالی است.');
    await reader.cancel();
    first.complete(fakeClip());
    final progress = await task;
    expect(played, isFalse);
    expect(progress.total, 0);
  });
}
