import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/retrieval/domain/citation_match.dart';

void main() {
  const sources = [
    'WHO Director-General declared COVID-19 a pandemic on 11 March 2020 '
        'at a media briefing in Geneva.',
    'The Nikon Z30 weighs 405 g with battery and memory card; the body '
        'alone weighs 350 g.',
  ];

  test('PALA source zero is program-owned with no fetched evidence', () {
    final result = CitationMatch.appControlled(
      'درخت گلابی ممکن است آفت‌های متفاوت داشته باشد [۹۹].',
      const [],
    );
    expect(result.text, contains('[۰]'));
    expect(result.text, isNot(contains('[۹۹]')));
    expect(result.verifiedClaims, 0);
    expect(result.internalClaims, 1);
  });

  test('real multi-source pages receive distinct app-assigned numbers', () {
    final result = CitationMatch.appControlled(
      'The Nikon Z30 body weighs 350 g [99]. '
      'The WHO declared COVID-19 a pandemic on 11 March 2020 [1].',
      sources,
    );
    expect(result.text, contains('350 g [2].'));
    expect(result.text, contains('11 March 2020 [1].'));
    expect(result.text, isNot(contains('[99]')));
    expect(result.verifiedClaims, 2);
    expect(result.unverifiedClaims, 0);
  });

  test('mixed answer uses source zero only on unsupported claim', () {
    final result = CitationMatch.appControlled(
      'The Nikon Z30 body weighs 350 g [2]. '
      'The Nikon Z30 body weighs 390 g [2].',
      sources,
    );
    expect(result.text, contains('350 g [2].'));
    expect(result.text, contains('390 g [۰].'));
    expect(result.verifiedClaims, 1);
    expect(result.internalClaims, 1);
    expect(result.insufficientEvidence, true);
  });

  test('an unread search snippet cannot masquerade as fetched source', () {
    final result = CitationMatch.appControlled(
      'The Nikon Z30 body weighs 350 g [1].',
      const [''],
    );
    expect(result.text, contains('350 g [۰].'));
    expect(result.text, isNot(contains('[1]')));
  });

  test(
    'unsupported sensitive electrical advice receives a visible caution',
    () {
      final result = CitationMatch.appControlled(
        'Turn the electrical inverter voltage to 300 volts [99].',
        const [],
        sensitiveAdvice: CitationMatch.sensitiveRecommendation(
          'چطور ولتاژ اینورتر را تغییر بدهم؟',
        ),
      );
      expect(result.caution, true);
      expect(result.text, contains('[۰]'));
      expect(result.text, contains('شاهد کافی ندارد'));
      expect(result.text, isNot(contains('[99]')));
    },
  );

  test('literal code and inline array indexes do not become citations', () {
    final result = CitationMatch.appControlled(
      'Use `arr[0]` to access the value.\n'
      '```dart\nfinal x = arr[99];\n```\n'
      'The Nikon Z30 body weighs 350 g [۹۹].',
      sources,
    );
    expect(result.text, contains('`arr[0]`'));
    expect(result.text, contains('arr[99];'));
    expect(result.text, contains('350 g [2].'));
    expect(result.text, isNot(contains('350 g [۹۹]')));
  });

  test('no supporting evidence leaves no fabricated positive citation', () {
    final result = CitationMatch.appControlled(
      'The Nikon Z30 body weighs 390 g [1,۲،٩٩].',
      sources,
    );
    expect(result.text, contains('[۰]'));
    expect(result.text, isNot(contains('[1]')));
    expect(result.text, isNot(contains('[2]')));
  });

  test('uncited sentences get the source holding their words and figures', () {
    final cited = CitationMatch.attach(
      'The WHO declared COVID-19 a pandemic on 11 March 2020. '
      'The Nikon Z30 body weighs 350 g.',
      sources,
    );
    expect(
      cited,
      'The WHO declared COVID-19 a pandemic on 11 March 2020 [1]. '
      'The Nikon Z30 body weighs 350 g [2].',
    );
  });

  test('an abbreviation inside a sentence does not end it', () {
    expect(
      CitationMatch.attach(
        'The Nintendo Switch 2 price in the U.S. is 449.99 dollars.',
        ['Nintendo Switch 2 price in the U.S. is 449.99 dollars at launch.'],
      ),
      'The Nintendo Switch 2 price in the U.S. is 449.99 dollars [1].',
    );
  });

  test('a figure no source has leaves the sentence uncited', () {
    expect(
      CitationMatch.attach('The Nikon Z30 body weighs 390 g.', sources),
      'The Nikon Z30 body weighs 390 g.',
    );
  });

  test('cited answers, tables, code and small talk are left alone', () {
    const already = 'The WHO declared a pandemic in 2020 [1].';
    expect(CitationMatch.attach(already, sources), already);
    const table = '| Camera | Weight |\n|---|---|\n| Nikon Z30 body | 350 g |';
    expect(CitationMatch.attach(table, sources), table);
    expect(CitationMatch.attach('Sure!', sources), 'Sure!');
    expect(
      CitationMatch.attach('- **Weight:** the Nikon Z30 body weighs 350 g', [
        sources[1],
      ]),
      '- **Weight:** the Nikon Z30 body weighs 350 g [1]',
    );
  });

  test('source numbers must match actual retrieved evidence', () {
    expect(
      CitationMatch.stripUnknown(
        'Verified [1]. Invented [99]. Mixed [1, 40, 2]. Internal [0].',
        2,
      ),
      'Verified [1]. Invented . Mixed [1, 2]. Internal .',
    );
    expect(CitationMatch.stripUnknown('No source [1]', 0), 'No source ');
    expect(
      CitationMatch.stripUnknown('واقعی [۲] و ساختگی [۹۹]', 2),
      'واقعی [2] و ساختگی ',
    );
  });

  test('in-range fabricated citation is removed, real evidence corrected', () {
    expect(
      CitationMatch.verifyEvidence(
        'The Nikon Z30 body weighs 390 g [2].',
        sources,
      ),
      'The Nikon Z30 body weighs 390 g .',
    );
    expect(
      CitationMatch.verifyEvidence(
        'The Nikon Z30 body weighs 350 g [1].',
        sources,
      ),
      'The Nikon Z30 body weighs 350 g [2].',
    );
  });

  test('multiple citations on one claim collapse to one verified source', () {
    expect(
      CitationMatch.verifyEvidence(
        'The Nikon Z30 body weighs 350 g [1] [2].',
        sources,
      ),
      'The Nikon Z30 body weighs 350 g [2] .',
    );
    expect(
      CitationMatch.verifyEvidence(
        'The Nikon Z30 body weighs 390 g [1] [2].',
        sources,
      ),
      'The Nikon Z30 body weighs 390 g  .',
    );
  });

  test('a source line ending in a semicolon is read, not a crash', () {
    // An SEC page read on the phone (D1 benchmark, finance-sec-10k) threw
    // "No element" here and failed the whole send.
    expect(
      CitationMatch.attach('The Form 10-K is filed once a year.', [
        'Form 10-K;\nThe Form 10-K is filed once a year with the SEC;\n;',
      ]),
      'The Form 10-K is filed once a year [1].',
    );
  });
}
