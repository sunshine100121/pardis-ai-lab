import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class OnlineTurnQuestion {
  final String prompt;
  final String query;
  const OnlineTurnQuestion({required this.prompt, required this.query});
}

/// Pending approval is ephemeral; it is never an enduring broad grant.
final onlineTurnPermissionProvider =
    NotifierProvider<OnlineTurnPermission, OnlineTurnQuestion?>(
  OnlineTurnPermission.new,
);

class OnlineTurnPermission extends Notifier<OnlineTurnQuestion?> {
  Completer<bool>? _answer;
  @override
  OnlineTurnQuestion? build() {
    ref.onDispose(() {
      if (!(_answer?.isCompleted ?? true)) _answer!.complete(false);
    });
    return null;
  }

  Future<bool> ask({required String query}) async {
    // The old pending request is denied rather than silently shared.
    reject();
    final answer = _answer = Completer<bool>();
    state = OnlineTurnQuestion(
      prompt: 'منابع محلی برای این درخواست کافی نبودند. '
          'این بار اجازه می‌دهید فقط عبارت زیر در اینترنت جست‌وجو شود؟',
      query: query,
    );
    // In a headless task there may be no UI at all; do not grant by default.
    final timeout = Future<bool>.delayed(
      const Duration(seconds: 45), () => false,
    );
    final allowed = await Future.any([answer.future, timeout]);
    if (identical(_answer, answer)) {
      _answer = null;
      state = null;
    }
    return allowed;
  }

  void approve() => _resolve(true);
  void reject() => _resolve(false);

  void _resolve(bool approved) {
    final pending = _answer;
    _answer = null;
    state = null;
    if (pending != null && !pending.isCompleted) pending.complete(approved);
  }
}
