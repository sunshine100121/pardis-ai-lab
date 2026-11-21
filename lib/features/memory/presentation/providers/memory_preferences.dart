import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/memory_policy.dart';

/// Saved *preferences*, not a second memory store. The actual facts remain
/// in the original Drift memories table / project workspace / chat history.
class MemoryPreferences {
  final MemoryLearningMode learning;
  final MemoryRetention retention;
  final MemoryResponseStyle responseStyle;

  const MemoryPreferences({
    this.learning = MemoryLearningMode.automatic,
    this.retention = MemoryRetention.untilDeleted,
    this.responseStyle = MemoryResponseStyle.systemDefault,
  });

  MemoryPreferences copyWith({
    MemoryLearningMode? learning,
    MemoryRetention? retention,
    MemoryResponseStyle? responseStyle,
  }) => MemoryPreferences(
    learning: learning ?? this.learning,
    retention: retention ?? this.retention,
    responseStyle: responseStyle ?? this.responseStyle,
  );

  Map<String, String> toJson() => {
    'learning': learning.name,
    'retention': retention.name,
    'responseStyle': responseStyle.name,
  };

  factory MemoryPreferences.fromJson(Map json) {
    T read<T extends Enum>(List<T> options, String key, T fallback) {
      final value = json[key];
      for (final option in options) {
        if (option.name == value) return option;
      }
      return fallback;
    }

    return MemoryPreferences(
      learning: read(
        MemoryLearningMode.values,
        'learning',
        MemoryLearningMode.automatic,
      ),
      retention: read(
        MemoryRetention.values,
        'retention',
        MemoryRetention.untilDeleted,
      ),
      responseStyle: read(
        MemoryResponseStyle.values,
        'responseStyle',
        MemoryResponseStyle.systemDefault,
      ),
    );
  }
}

final memoryPreferencesProvider =
    NotifierProvider<MemoryPreferencesNotifier, MemoryPreferences>(
      MemoryPreferencesNotifier.new,
    );

class MemoryPreferencesNotifier extends Notifier<MemoryPreferences> {
  static const key = 'pala_memory_preferences_v1';
  SharedPreferences? _prefs;
  Future<void> _writeQueue = Future.value();
  bool _changedDuringLoad = false;
  bool _disposed = false;
  late Future<void> ready;

  @override
  MemoryPreferences build() {
    ref.onDispose(() => _disposed = true);
    ready = Future.microtask(_load);
    return const MemoryPreferences();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final saved = prefs.getString(key);
      if (saved == null || _disposed || _changedDuringLoad) return;
      final obj = jsonDecode(saved);
      if (obj is Map) state = MemoryPreferences.fromJson(obj);
    } catch (_) {
      // A damaged preference must never delete or rewrite memory facts.
    }
  }

  Future<void> update(MemoryPreferences prefs) async {
    _changedDuringLoad = true;
    state = prefs;
    final encoded = jsonEncode(prefs.toJson());
    _writeQueue = _writeQueue.then((_) async {
      _prefs ??= await SharedPreferences.getInstance();
      if (!await _prefs!.setString(key, encoded)) {
        throw StateError('Memory preferences could not be saved');
      }
    });
    await _writeQueue;
  }
}

/// Suggestions are intentionally not durable facts. A model proposal cannot
/// survive as "verified" merely because the application has restarted.
class MemorySuggestion {
  final String content;
  final String? sourceChatId;
  final String? sourceMessageId;

  const MemorySuggestion(
    this.content, {
    this.sourceChatId,
    this.sourceMessageId,
  });
}

final memorySuggestionsProvider =
    NotifierProvider<MemorySuggestionsNotifier, List<MemorySuggestion>>(
      MemorySuggestionsNotifier.new,
    );

class MemorySuggestionsNotifier extends Notifier<List<MemorySuggestion>> {
  @override
  List<MemorySuggestion> build() => const [];

  void propose(
    String content, {
    String? sourceChatId,
    String? sourceMessageId,
  }) {
    final fact = content.trim();
    if (fact.isEmpty || fact.length > 220) return;
    if (state.any((s) => s.content.toLowerCase() == fact.toLowerCase())) {
      return;
    }
    // Pending notes are visible for explicit approval on Settings > Memory.
    state = [
      ...state.take(24),
      MemorySuggestion(
        fact,
        sourceChatId: sourceChatId,
        sourceMessageId: sourceMessageId,
      ),
    ];
  }

  void discard(MemorySuggestion suggestion) {
    state = [
      for (final s in state)
        if (!identical(s, suggestion)) s,
    ];
  }

  void clear() => state = const [];
}
