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
    String? instructions,
    String? collection,
    String? memoryNotes,
    List<String>? sourceIds,
  }) => _change((s) {
    final previous = s.projects.where((p) => p.id == id).firstOrNull;
    if (id != null && previous == null) {
      throw StateError('پروژه دیگر وجود ندارد؛ اطلاعاتی بازنویسی نشد.');
    }
    final nextInstructions = instructions ?? previous?.instructions ?? '';
    final nextCollection = collection ?? previous?.collection ?? '';
    final notes = memoryNotes ?? previous?.memoryNotes ?? '';
    if (name.trim().isEmpty ||
        name.length > 100 ||
        nextInstructions.length > 4000 ||
        nextCollection.length > 200 ||
        notes.length > 6000) {
      throw const FormatException('Invalid project name or instructions.');
    }
    if (id == null && s.projects.length >= 32) {
      throw StateError('Project limit reached.');
    }
    final project = ChatProject(
      id ?? const Uuid().v4(),
      name.trim(),
      instructions: nextInstructions.trim(),
      collection: nextCollection.trim(),
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
    // A saved fact is always a single line, even when the owner's original
    // message had line breaks. Its origin stays attached for future edits.
    final clean = note.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty || clean.length > 400) {
      throw const FormatException('یادداشت باید بین ۱ تا ۴۰۰ نویسه باشد.');
    }
    final project = s.projects.where((p) => p.id == projectId).firstOrNull;
    if (project == null) throw StateError('پروژه یافت نشد.');
    final lines = project.memoryNotes.isEmpty
        ? <String>[]
        : project.memoryNotes.split('\n');
    final existing = lines.indexWhere(
      (entry) => ProjectMemoryEntry.belongsTo(entry, chatId, messageId),
    );
    if (lines.indexed.any(
      (pair) =>
          pair.$1 != existing &&
          (pair.$2 == clean ||
              pair.$2.startsWith('• $clean (تأیید مالک؛ تاریخ: ')),
    )) {
      throw StateError('این یادداشت قبلاً در حافظه پروژه ثبت شده است.');
    }
    final origin = notedAt.toIso8601String();
    final entry =
        '• $clean (تأیید مالک؛ تاریخ: $origin؛ '
        'گفتگو: $chatId؛ پیام: $messageId)';
    // Re-save the same message by replacing its previous fact, not adding
    // two conflicting copies to Qwen's persistent context.
    if (existing >= 0) {
      lines[existing] = entry;
    } else {
      lines.add(entry);
    }
    final updatedNotes = lines.join('\n');
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

  /// Revoke only one explicitly saved note. Never erase chat history or
  /// memories belonging to another project.
  Future<void> forgetChatMessage({
    required String projectId,
    required String chatId,
    required String messageId,
  }) => _change((s) {
    if (s.memberships[chatId] != projectId) {
      throw StateError('این گفتگو عضو پروژه انتخابی نیست.');
    }
    final project = s.projects.where((p) => p.id == projectId).firstOrNull;
    if (project == null) throw StateError('پروژه یافت نشد.');
    final lines = project.memoryNotes.split('\n');
    final existing = lines.indexWhere(
      (entry) => ProjectMemoryEntry.belongsTo(entry, chatId, messageId),
    );
    if (existing < 0) {
      throw StateError('یادداشت مربوط به این پیام پیدا نشد.');
    }
    lines.removeAt(existing);
    final updatedProject = ChatProject(
      project.id,
      project.name,
      instructions: project.instructions,
      collection: project.collection,
      memoryNotes: lines.join('\n').trim(),
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
  // Offline inference always stays local. A remote profile must explicitly
  // allow sharing saved memory before any project note enters its prompt.
  static bool mayShareWithModel({
    required bool usesRemote,
    required bool shareMemory,
  }) => !usesRemote || shareMemory;

  static final _words = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true);
  static final _overview = RegExp(
    r'(?:چه|چیا|چی|همه).{0,48}(?:اطلاعات|یادداشت|خاطره|چیز).{0,60}(?:ثبت|یاد|ذخیره|داری|دارم)',
    unicode: true,
  );
  static final _pastConversation = RegExp(
    r'(?:قبلاً|قبلا|یادت|یادته).{0,64}(?:صحبت|گفتگو|گفت‌وگو|حرف|گفتیم|پرسید)',
    unicode: true,
  );

  // Very small Persian normalization for owner-memory questions:
  // «درخت گردوی من» and «درخت گردو» describe the same plant.
  static String _normalizeWord(String word) {
    final normalized = word
        .toLowerCase()
        .replaceAll('ي', 'ی')
        .replaceAll('ك', 'ک');
    return normalized.endsWith('وی')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  static final _personal = RegExp(
    r'(?<![\p{L}\p{N}])(?:من|ما|خودم|دارم|داریم|قبلاً|یادته|یادت|حافظه|یادداشت|my|our|remember)(?![\p{L}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );
  static const _common = <String>{
    'the',
    'and',
    'what',
    'have',
    'your',
    'that',
    'من',
    'ما',
    'برای',
    'چند',
    'چطور',
    'است',
    'هست',
    'دارم',
    'داریم',
    'این',
    'اون',
    'یادداشت',
    'حافظه',
  };

  static bool relevant(String question, String ownerNotes) {
    if (ownerNotes.trim().isEmpty || !_personal.hasMatch(question)) {
      return false;
    }
    Set<String> tokens(String text) => {
      for (final match in _words.allMatches(text))
        if (!_common.contains(_normalizeWord(match.group(0)!)))
          _normalizeWord(match.group(0)!),
    };
    // An explicit request to list the current project's saved facts is
    // different from asking a factual question about the outside world.
    if (_overview.hasMatch(question)) return true;
    final questionTerms = tokens(question);
    // Two terms appearing in different notes are not evidence for one
    // personal claim. Each owner-confirmed entry must match on its own.
    for (final entry in ownerNotes.split('\n')) {
      // Stored origin metadata is provenance, not evidence for a claim.
      final fact = entry.split(' (تأیید مالک؛ تاریخ: ').first;
      final matching = questionTerms.intersection(tokens(fact));
      // A question about an earlier *conversation* needs an actual chat
      // origin. Manually entered facts cannot prove a past conversation.
      if (_pastConversation.hasMatch(question)) {
        if (entry.contains(' (تأیید مالک؛ تاریخ: ') &&
            matching.any((word) => word.length >= 4)) {
          return true;
        }
        continue;
      }
      if (matching.length >= 2) return true;
    }
    return false;
  }
}

/// Find the owner-approved note for a particular user message in a project.
/// Hand-written and older project notes keep their existing storage format.
class ProjectMemoryEntry {
  static bool belongsTo(String line, String chatId, String messageId) =>
      line.startsWith('• ') &&
      line.contains(' (تأیید مالک؛ تاریخ: ') &&
      line.endsWith('؛ گفتگو: $chatId؛ پیام: $messageId)');

  static String? noteFor(
    String notes, {
    required String chatId,
    required String messageId,
  }) {
    for (final line in notes.split('\n')) {
      if (!belongsTo(line, chatId, messageId)) continue;
      final marker = line.lastIndexOf(' (تأیید مالک؛ تاریخ: ');
      if (marker > 2) return line.substring(2, marker);
    }
    return null;
  }
}
