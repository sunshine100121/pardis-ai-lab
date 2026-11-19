import 'dart:async';

/// Source: OnDevice LLM v1.7.0, memory admission. Heavy engine allocations
/// are serialized in the app isolate, rather than racing for free RAM.
/// The native loader checks current free memory inside each admitted load.
/// This does not change context lengths, GGUF data or persisted settings.
class MemoryAdmission {
  static final shared = MemoryAdmission();
  Future<void>? _tail;
  int _queued = 0;

  Future<T> run<T>(Future<T> Function() allocate) {
    final tail = _tail;
    final next = tail == null
        ? Future.sync(allocate)
        : tail.then((_) => allocate());
    _queued++;
    late final Future<void> done;
    done = next
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (--_queued == 0 && identical(_tail, done)) _tail = null;
        });
    _tail = done;
    return next;
  }
}
