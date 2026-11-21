import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/memory/domain/memory_policy.dart';
import 'package:ondevice_llm/features/memory/domain/memory_statements.dart';
import 'package:ondevice_llm/features/memory/domain/user_memory.dart';

void main() {
  test('clear Persian user preferences and interests are grounded facts', () {
    expect(
      MemoryStatements.extract('من به یوگا علاقه دارم.'),
      contains('کاربر به یوگا علاقه دارد'),
    );
    expect(
      MemoryStatements.extract('من ترجیح می‌دهم پاسخ‌ها کوتاه باشند.'),
      contains('کاربر ترجیح می‌دهد پاسخ‌ها کوتاه باشند'),
    );
    expect(
      MemoryStatements.extract('زبان من فارسی است.'),
      contains('زبان کاربر فارسی'),
    );
    expect(
      MemoryStatements.extract('اسم من جمال است.'),
      contains('نام کاربر جمال'),
    );
    expect(
      UserMemory.explicitFacts('من به یوگا علاقه دارم.', existing: const []),
      contains('کاربر به یوگا علاقه دارد'),
    );
  });

  test(
    'speculative, quoted, temporal and negative Persian claims are rejected',
    () {
      for (final input in [
        'شاید من به یوگا علاقه دارم.',
        'اگر من به یوگا علاقه دارم.',
        'مثال: من به یوگا علاقه دارم.',
        '«من به یوگا علاقه دارم»',
        'من امروز به یوگا علاقه دارم.',
        'من به یوگا علاقه ندارم.',
      ]) {
        expect(MemoryStatements.extract(input), isEmpty, reason: input);
      }
    },
  );

  test('Persian memory can be recalled for a personal follow-up', () {
    expect(UserMemory.personalQuery('من به چه چیزی علاقه دارم؟'), isTrue);
    expect(
      UserMemory.relevant('من به چه چیزی علاقه دارم؟', const [
        'کاربر به یوگا علاقه دارد',
      ]),
      [0],
    );
    expect(UserMemory.relevant('اسم من چیست؟', const ['نام کاربر جمال']), [0]);
  });

  test(
    'Persian benign facts are low-risk, not private addresses or guesses',
    () {
      expect(
        MemoryScopePolicy.lowRiskExplicit('کاربر به یوگا علاقه دارد'),
        isTrue,
      );
      expect(MemoryScopePolicy.lowRiskExplicit('زبان کاربر فارسی است'), isTrue);
      expect(
        MemoryScopePolicy.lowRiskExplicit('کاربر شاید در شیراز زندگی کند'),
        isFalse,
      );
      expect(
        MemoryScopePolicy.lowRiskExplicit('رمز حساب بانکی من ۱۲۳۴ است'),
        isFalse,
      );
    },
  );
}
