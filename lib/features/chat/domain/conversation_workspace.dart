import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ChatProject {
  final String id, name, instructions, collection, memoryNotes;
  final List<String> sourceIds;
  const ChatProject(
    this.id,
    this.name, {
    this.instructions = '',
    this.collection = '',
    this.memoryNotes = '',
    this.sourceIds = const [],
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'instructions': instructions,
    'collection': collection,
    'memoryNotes': memoryNotes,
    'sourceIds': sourceIds,
  };
}

class ConversationWorkspace {
  final List<ChatProject> projects;
  final Map<String, String> memberships, states;
  final bool loaded, readable;
  const ConversationWorkspace({
    this.projects = const [],
    this.memberships = const {},
    this.states = const {},
    this.loaded = true,
    this.readable = true,
  });
  ChatProject? projectFor(String? chatId) =>
      projects.where((p) => p.id == memberships[chatId]).firstOrNull;
  String stateOf(String id) => states[id] ?? 'active';
}

final conversationWorkspaceProvider =
    NotifierProvider<ConversationWorkspaceNotifier, ConversationWorkspace>(
      ConversationWorkspaceNotifier.new,
    );

/// A separate versioned metadata contract leaves existing chat rows and branch
/// ancestry untouched. Backups include this key alongside the chat database.
class ConversationWorkspaceNotifier extends Notifier<ConversationWorkspace> {
  static const key = 'conversation_workspace_v1';
  late Future<void> ready;
  Future<void> _pending = Future.value();
  bool _alive = true;
  @override
  ConversationWorkspace build() {
    ref.onDispose(() => _alive = false);
    ready = _load();
    return const ConversationWorkspace(loaded: false, readable: false);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final j = jsonDecode(prefs.getString(key) ?? '{}') as Map;
      final next = ConversationWorkspace(
        projects: [
          for (final p in (j['projects'] as List? ?? []))
            if (p is Map && p['id'] is String && p['name'] is String)
              ChatProject(
                p['id'],
                p['name'],
                instructions: p['instructions'] as String? ?? '',
                collection: p['collection'] as String? ?? '',
                memoryNotes: p['memoryNotes'] is String
                    ? p['memoryNotes'] as String
                    : '',
                sourceIds:
                    (p['sourceIds'] is List ? p['sourceIds'] as List : const [])
                        .whereType<String>()
                        .toList(),
              ),
        ],
        memberships: Map<String, String>.from(j['memberships'] as Map? ?? {}),
        states: Map<String, String>.from(j['states'] as Map? ?? {}),
      );
      if (_alive) state = next;
    } catch (_) {
      if (_alive) state = const ConversationWorkspace(readable: false);
    }
  }

  Future<void> _change(
    ConversationWorkspace Function(ConversationWorkspace) edit,
  ) {
    final next = _pending.then((_) async {
      await ready;
      if (!_alive) return;
      if (!state.readable)
        throw StateError('اطلاعات پروژه‌ها خوانده نشد؛ تغییری ذخیره نشد.');
      final updated = edit(state);
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(
        key,
        jsonEncode({
          'projects': updated.projects.map((p) => p.toJson()).toList(),
          'memberships': updated.memberships,
          'states': updated.states,
        }),
      );
      if (!saved) throw StateError('Could not save conversation organization.');
      if (_alive) state = updated;
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> saveProject({
    String? id,
    required String name,
    String instructions = '',
    String collection = '',
    String? memoryNotes,
    List<String>? sourceIds,
  }) => _change((s) {
    final previous = s.projects.where((p) => p.id == id).firstOrNull;
    final notes = memoryNotes ?? previous?.memoryNotes ?? '';
    if (name.trim().isEmpty ||
        name.length > 100 ||
        instructions.length > 4000 ||
        collection.length > 200 ||
        notes.length > 6000) {
      throw const FormatException('Invalid project name or instructions.');
    }
    if (id == null && s.projects.length >= 32) {
      throw StateError('Project limit reached.');
    }
    final project = ChatProject(
      id ?? const Uuid().v4(),
      name.trim(),
      instructions: instructions.trim(),
      collection: collection.trim(),
      memoryNotes: notes.trim(),
      sourceIds: List.unmodifiable(
        sourceIds ?? previous?.sourceIds ?? const [],
      ),
    );
    return ConversationWorkspace(
      projects: [...s.projects.where((p) => p.id != id), project],
      memberships: s.memberships,
      states: s.states,
    );
  });
  /// Only an explicitly reviewed USER message may become project memory.
  /// The note, source IDs and date live alongside the existing project
  /// metadata, not in global memory or a separate copy of chat history.
  Future<void> rememberChatMessage({
    required String projectId,
    required String chatId,
    required String messageId,
    required String note,
    required DateTime notedAt,
  }) => _change((s) {
    if (s.memberships[chatId] != projectId) {
      throw StateError('این گفتگو عضو پروژه انتخابی نیست.');
    }
    final text = note.trim();
    if (text.isEmpty || text.length > 400) {
      throw const FormatException('یادداشت باید بین ۱ تا ۴۰۰ نویسه باشد.');
    }
    final project = s.projects.where((p) => p.id == projectId).firstOrNull;
    if (project == null) throw StateError('پروژه یافت نشد.');
    if (project.memoryNotes.contains(text)) {
      throw StateError('این یادداشت قبلاً در حافظه پروژه ثبت شده است.');
    }
    final origin = notedAt.toIso8601String();
    final entry = '• $text (تأیید مالک؛ تاریخ: $origin؛ '
        'گفتگو: $chatId؛ پیام: $messageId)';
    final updatedNotes = project.memoryNotes.isEmpty
        ? entry
        : '${project.memoryNotes}\n$entry';
    if (updatedNotes.length > 6000) {
      throw StateError(
        'فضای یادداشت‌های پروژه پر شده است؛ ابتدا آن‌ها را ویرایش کنید.',
      );
    }
    final updatedProject = ChatProject(
      project.id,
      project.name,
      instructions: project.instructions,
      collection: project.collection,
      memoryNotes: updatedNotes,
      sourceIds: project.sourceIds,
    );
    return ConversationWorkspace(
      projects: [
        for (final p in s.projects)
          if (p.id == projectId) updatedProject else p,
      ],
      memberships: s.memberships,
      states: s.states,
    );
  });

  Future<void> assign(Iterable<String> ids, String? projectId) => _change((s) {
    if (projectId != null && !s.projects.any((p) => p.id == projectId)) {
      throw StateError('Project no longer exists.');
    }
    final memberships = {...s.memberships};
    for (final id in ids) {
      if (projectId == null) {
        memberships.remove(id);
      } else {
        memberships[id] = projectId;
      }
    }
    return ConversationWorkspace(
      projects: s.projects,
      memberships: memberships,
      states: s.states,
    );
  });
  Future<void> setState(Iterable<String> ids, String destination) =>
      _change((s) {
        if (!const {'active', 'archived', 'trash'}.contains(destination)) {
          throw ArgumentError(destination);
        }
        final states = {...s.states};
        for (final id in ids) {
          if (destination == 'active') {
            states.remove(id);
          } else {
            states[id] = destination;
          }
        }
        return ConversationWorkspace(
          projects: s.projects,
          memberships: s.memberships,
          states: states,
        );
      });
  Future<void> removeProject(String id) => _change(
    (s) => ConversationWorkspace(
      projects: s.projects.where((p) => p.id != id).toList(),
      memberships: {...s.memberships}..removeWhere((_, v) => v == id),
      states: s.states,
    ),
  );
  Future<void> forget(String id) => _change(
    (s) => ConversationWorkspace(
      projects: s.projects,
      memberships: {...s.memberships}..remove(id),
      states: {...s.states}..remove(id),
    ),
  );
}

/// Project memories can answer owner-specific questions, never unrelated
/// encyclopedic claims or current sensor readings. This is a deterministic
/// guard, not an LLM judgment and not a substitute for source citations.
class ProjectMemoryGate {
  static final _words = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true);
  static final _personal = RegExp(
    r'(?<![\p{L}\p{N}])(?:من|ما|خودم|دارم|داریم|قبلاً|یادته|یادت|حافظه|یادداشت|my|our|remember)(?![\p{L}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );
  static const _common = <String>{
    'the', 'and', 'what', 'have', 'your', 'that',
    'من', 'ما', 'برای', 'چند', 'چطور', 'است', 'هست', 'دارم',
    'داریم', 'این', 'اون', 'یادداشت', 'حافظه',
  };

  static bool relevant(String question, String ownerNotes) {
    if (ownerNotes.trim().isEmpty || !_personal.hasMatch(question)) {
      return false;
    }
    Set<String> tokens(String text) => {
      for (final match in _words.allMatches(text.toLowerCase()))
        if (!_common.contains(match.group(0)!)) match.group(0)!,
    };
    final questionTerms = tokens(question);
    final shared = questionTerms.intersection(tokens(ownerNotes));
    return shared.length >= 2;
  }
}
