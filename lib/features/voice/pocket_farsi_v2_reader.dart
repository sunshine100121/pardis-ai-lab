import 'dart:async';

import 'pocket_farsi_v2_audio.dart';

/// Plan complete prose into bounded utterances without dropping words.
/// The model's ~18 phoneme-token budget is handled by native chunking;
/// this outer plan only caps each G2P call and keeps memory bounded.
abstract final class PocketPersianTextPlan {
  static List<String> split(String text, {int maxCharacters = 200}) {
    if (maxCharacters < 48 || maxCharacters > 240) {
      throw RangeError.range(maxCharacters, 48, 240, 'maxCharacters');
    }
    var remaining = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final result = <String>[];
    while (remaining.length > maxCharacters) {
      var natural = -1;
      var whitespace = -1;
      final lowerBound = maxCharacters ~/ 3;
      // Prefer phrase endings, including a comma or Persian punctuation.
      for (var i = lowerBound; i < maxCharacters; i++) {
        final char = remaining[i];
        if (char == ' ') {
          whitespace = i;
          if (i > 0 && '.!?؟؛،:'.contains(remaining[i - 1])) {
            natural = i;
          }
        } else if ('.!?؟؛'.contains(char)) {
          natural = i + 1;
        }
      }
      final cut = natural > 0 ? natural : whitespace;
      if (cut <= 0) {
        // Do not cut a long technical word in half and silently corrupt TTS.
        throw const FormatException(
          'Pocket cannot safely split a word longer than the speech budget',
        );
      }
      final sentence = remaining.substring(0, cut).trim();
      if (sentence.isEmpty) {
        throw const FormatException('Pocket segmentation returned empty text');
      }
      result.add(sentence);
      remaining = remaining.substring(cut).trimLeft();
    }
    if (remaining.isNotEmpty) result.add(remaining);
    return List.unmodifiable(result);
  }
}

class PocketReadingProgress {
  final int completed;
  final int total;
  final bool paused;

  const PocketReadingProgress(this.completed, this.total, this.paused);

  bool get finished => !paused && total > 0 && completed == total;
}

class _Prepared {
  final PocketGeneratedAudio? clip;
  final Object? error;
  final StackTrace? stack;

  const _Prepared.ok(this.clip) : error = null, stack = null;

  const _Prepared.fail(this.error, this.stack) : clip = null;
}

/// Explicit diagnostic reader, not enabled as a daily TTS selection yet.
///
/// It can read arbitrarily many bounded sections while holding at most one
/// next PCM clip. By default prefetching is OFF until RAM alongside Qwen 4B
/// is measured on the owner's tablet. A paused section is replayed from its
/// beginning on resume; the cursor only advances after complete playback.
class PocketFarsiLongReader {
  PocketFarsiLongReader({
    Future<PocketGeneratedAudio> Function(String)? synthesize,
    Future<bool> Function(PocketGeneratedAudio)? play,
    Future<void> Function()? stopPlayback,
    this.prefetchOne = false,
  }) : _synthesize = synthesize ?? PocketFarsiV2Audio.synthesize,
       _play = play ?? PocketFarsiV2Audio.play,
       _stopPlayback = stopPlayback ?? PocketFarsiV2Audio.stopPlayback;

  final Future<PocketGeneratedAudio> Function(String) _synthesize;
  final Future<bool> Function(PocketGeneratedAudio) _play;
  final Future<void> Function() _stopPlayback;
  final bool prefetchOne;

  List<String> _pieces = const [];
  int _cursor = 0;
  int _generation = 0;
  bool _paused = false;
  bool _running = false;

  PocketReadingProgress get progress =>
      PocketReadingProgress(_cursor, _pieces.length, _paused);

  bool get isRunning => _running;

  Future<PocketReadingProgress> read(String text) {
    if (_running) throw StateError('Pocket reader is already running');
    final pieces = PocketPersianTextPlan.split(text);
    if (pieces.isEmpty) {
      throw const FormatException('There is no text to read');
    }
    _pieces = pieces;
    _cursor = 0;
    _paused = false;
    return _drain();
  }

  Future<PocketReadingProgress> resume() {
    if (_running) throw StateError('Pocket reader is still stopping');
    if (!_paused || _pieces.isEmpty) {
      throw StateError('No paused reading session');
    }
    _paused = false;
    return _drain();
  }

  Future<void> pause() async {
    if (!_running) return;
    _paused = true;
    _generation++;
    await _stopPlayback();
  }

  Future<void> cancel() async {
    _generation++;
    _paused = false;
    _pieces = const [];
    _cursor = 0;
    await _stopPlayback();
  }

  Future<_Prepared> _prepare(String piece) async {
    try {
      return _Prepared.ok(await _synthesize(piece));
    } catch (error, stack) {
      return _Prepared.fail(error, stack);
    }
  }

  Future<PocketReadingProgress> _drain() async {
    _running = true;
    final generation = ++_generation;
    try {
      Future<_Prepared>? next;
      while (_cursor < _pieces.length) {
        final prepared = await (next ?? _prepare(_pieces[_cursor]));
        next = null;
        if (_generation != generation) break;
        if (prepared.error != null) {
          Error.throwWithStackTrace(prepared.error!, prepared.stack!);
        }
        final clip = prepared.clip!;
        if (prefetchOne && _cursor + 1 < _pieces.length) {
          next = _prepare(_pieces[_cursor + 1]);
        }
        final heard = await _play(clip);
        if (_generation != generation) break;
        if (!heard) {
          throw StateError('Pocket speech playback was interrupted');
        }
        _cursor++;
      }
      return progress;
    } finally {
      _running = false;
    }
  }
}
