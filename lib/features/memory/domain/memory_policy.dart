/// M11: policy for the EXISTING local memory database and project workspaces.
/// No secondary fact store, paid service, or online memory synchronisation.
enum MemoryLearningMode { off, confirm, automatic }

enum MemoryRetention {
  sevenDays(7, '۷ روز'),
  thirtyDays(30, '۳۰ روز'),
  ninetyDays(90, '۹۰ روز'),
  untilDeleted(null, 'تا حذف دستی');

  const MemoryRetention(this.days, this.label);
  final int? days;
  final String label;

  DateTime? expiresFrom(DateTime date) =>
      days == null ? null : date.add(Duration(days: days!));
}

enum MemoryResponseStyle {
  formal('رسمی'),
  friendly('دوستانه'),
  humorous('شوخ‌طبع');

  const MemoryResponseStyle(this.label);
  final String label;

  /// Response style is guidance, never evidence or a change to safety policy.
  String get promptNote => switch (this) {
    formal => 'Use a clear, professional and respectful response style.',
    friendly => 'Use a friendly, natural, concise response style.',
    humorous => 'Use light humor only when appropriate; never in safety, '
        'health, emergency, factual uncertainty, or sensitive matters.',
  };
}

enum MemoryScope { general, project, conversation }

/// Prompt and retention routing over existing PALA stores:
/// general: local memories rows
/// project: ChatProject.memoryNotes (only matching project ID)
/// conversation: saved messages/history for the current chat ID.
abstract final class MemoryScopePolicy {
  static bool isVisible({
    required MemoryScope scope,
    String? itemProjectId,
    String? itemChatId,
    String? currentProjectId,
    String? currentChatId,
  }) => switch (scope) {
    MemoryScope.general => currentProjectId == null,
    MemoryScope.project =>
      itemProjectId != null &&
      itemProjectId.isNotEmpty &&
      itemProjectId == currentProjectId,
    MemoryScope.conversation =>
      itemChatId != null &&
      itemChatId.isNotEmpty &&
      itemChatId == currentChatId,
  };

  /// Only low-risk explicit USER statements are automatically eligible.
  /// Model suggestions, hypothetical wording, sensitive data and any
  /// third-party claim always require review (or must be rejected).
  static bool lowRiskExplicit(String fact) {
    final text = fact.trim();
    if (text.length < 8 || text.length > 220) return false;
    if (_sensitive.hasMatch(text) || _speculative.hasMatch(text)) return false;
    return _benign.hasMatch(text);
  }

  static final _sensitive = RegExp(
    r'\b(?:password|passcode|pin|token|secret|api key|allerg|illness|disease|'
    r'diagnos|medicat|bank|account number|credit card|religion|politic|'
    r'vot|sexual|pregnan|health|debt|salary|address|passport|ssn|'
    r'biometric|location history)\b|'
    r'(?:رمز|گذرواژه|توکن|کلید خصوصی|بیماری|دارو|حساسیت|بانک|'
    r'شماره حساب|کارت بانکی|مذهب|دین|سیاسی|رأی|بارداری|سلامت|'
    r'درآمد|آدرس|نشانی خانه|گذرنامه|هویت گوینده)',
    caseSensitive: false,
    unicode: true,
  );
  static final _speculative = RegExp(
    r'\b(?:maybe|perhaps|might|guess|imagine|hypothetical|'
    r'rumor|rumour|the assistant thinks)\b|'
    r'(?:شاید|احتمالا|احتمالاً|حدس|فرض کنیم|تصور کن|ممکن است|'
    r'به نظر مدل|گمان می‌کنم)',
    caseSensitive: false,
    unicode: true,
  );
  static final _benign = RegExp(
    r'\b(?:prefer|prefers|speak|speaks|language|languages|'
    r'work|works|job|profession|favourite|favorite|'
    r'likes|use|uses|hobby|hobbies)\b|'
    r'(?:ترجیح می‌دهم|دوست دارم|علاقه دارم|زبان|'
    r'کار می‌کنم|شغل|سرگرمی|کتاب مورد علاقه|سبک پاسخ)',
    caseSensitive: false,
    unicode: true,
  );
}

enum MemoryEvidence { ownerConfirmed, explicitUserStatement, modelProposal }

abstract final class MemoryAdmissionPolicy {
  static bool mayPersist({
    required MemoryLearningMode mode,
    required MemoryEvidence evidence,
    required String content,
  }) {
    if (evidence == MemoryEvidence.ownerConfirmed) return true;
    if (mode != MemoryLearningMode.automatic) return false;
    return evidence == MemoryEvidence.explicitUserStatement &&
        MemoryScopePolicy.lowRiskExplicit(content);
  }

  static bool needsApproval({
    required MemoryLearningMode mode,
    required MemoryEvidence evidence,
  }) => mode != MemoryLearningMode.off &&
      evidence != MemoryEvidence.ownerConfirmed &&
      (mode == MemoryLearningMode.confirm ||
          evidence == MemoryEvidence.modelProposal);
}
