import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_multilingual_source_route.dart';
import 'package:ondevice_llm/features/zim/zim_query_translation.dart';

void main() {
  final rows = <Map<String, Object>>[
    {
      'uri': 'content://folder/gardening.zim',
      'name': 'gardening.stackexchange.com_en_all_2026-10.zim',
      'enabled': true,
    },
    {
      'uri': 'content://folder/wikipedia.zim',
      'name': 'wikipedia_fa_all_maxi_2026-10.zim',
      'enabled': true,
    },
    {
      'uri': 'content://folder/wikivoyage.zim',
      'name': 'wikivoyage_fa_all_maxi_2026-09.zim',
      'enabled': true,
    },
    {
      'uri': 'content://folder/pi.zim',
      'name': 'raspberrypi.stackexchange.com_en_all_2026-10.zim',
      'enabled': true,
    },
    {
      'uri': 'content://folder/dreame.pdf',
      'name': 'Dreame_X50_Pardis_Home_Assistant_Complete_FA_2026.pdf',
      'enabled': true,
    },
    {
      'uri': 'content://folder/medical.pdf',
      'name': 'راهنمای پزشکی.pdf',
      'enabled': true,
    },
    {
      'uri': 'content://folder/disabled.zim',
      'name': 'gardening.stackexchange.com_en_all_disabled.zim',
      'enabled': false,
    },
  ];
  final data = <String, dynamic>{'files': rows};
  String id(String uri) => FolderLibrary.sourceId('content://folder/$uri');

  test('Persian gardening searches English specialist and relevant general article, NOT medical PDF', () {
    final route = ZimMultilingualSourceRoute.choose(
      'تفاوت مقاومت درخت بادام و گردو به سرمای پاییز چیست؟',
      data,
    );
    expect(route.exclusive, false);
    expect(route.sourceIds, {id('gardening.zim'), id('wikipedia.zim')});
    expect(route.sourceIds, isNot(contains(id('medical.pdf'))));
  });

  test('English cold-protection question routes to specialist', () {
    final route = ZimMultilingualSourceRoute.choose(
      'How do I protect young fig trees from frost?',
      data,
    );
    expect(route.sourceIds, {id('gardening.zim'), id('wikipedia.zim')});
  });

  test('only named garden ZIM excludes ALL other files', () {
    final route = ZimMultilingualSourceRoute.choose(
      'Search ONLY the local offline archive '
      'gardening.stackexchange.com_en_all_2026-10.zim. '
      'What is the best way to protect young fig trees from frost? '
      'Do not use any other PDF.',
      data,
    );
    expect(route.exclusive, true);
    expect(route.missingOrAmbiguous, false);
    expect(route.sourceIds, {id('gardening.zim')});
  });

  test(
    'explicit missing, disabled or project-unapproved archive fails closed',
    () {
      final question =
          'Search ONLY gardening.stackexchange.com_en_all_2026-10.zim';
      final project = ZimMultilingualSourceRoute.choose(
        question,
        data,
        projectAllowed: {id('wikipedia.zim')},
      );
      expect(project.sourceIds, isEmpty);
      expect(project.missingOrAmbiguous, true);
      final missing = ZimMultilingualSourceRoute.choose(
        'Search ONLY not_existing_2026.zim',
        data,
      );
      expect(missing.exclusive, true);
      expect(missing.sourceIds, isEmpty);
      expect(missing.missingOrAmbiguous, true);
    },
  );

  test(
    'travel selects Wikivoyage and generic Persian source, not gardening',
    () {
      final route = ZimMultilingualSourceRoute.choose(
        'برای سفر سه روزه به اصفهان جاذبه های تاریخی کدامند؟',
        data,
      );
      expect(route.sourceIds, {id('wikivoyage.zim'), id('wikipedia.zim')});
    },
  );

  test('Home Assistant favors existing Raspberry and HA document, not unrelated PDFs', () {
    final route = ZimMultilingualSourceRoute.choose(
      'How do Home Assistant Zigbee sensors work on Raspberry Pi?',
      data,
    );
    expect(route.sourceIds, {id('pi.zim'), id('dreame.pdf')});
    expect(route.sourceIds, isNot(contains(id('medical.pdf'))));
  });

  test('generic questions retain source scope; no forced source selection', () {
    final route = ZimMultilingualSourceRoute.choose('What is gravity?', data);
    expect(route.sourceIds, isNull);
    expect(route.exclusive, false);
  });

  test('simple bilingual specialist terms require no model generation', () {
    expect(
      ZimQueryTranslation.fastSpecialistTerms(
        'تفاوت بادام و گردو در سرمازدگی پاییز چیست؟',
      ),
      contains('almond'),
    );
    expect(
      ZimQueryTranslation.fastSpecialistTerms('آبیاری درخت گردو'),
      contains('watering'),
    );
    final fig = ZimQueryTranslation.fastSpecialistTerms(
      'Search ONLY gardening.stackexchange.com_en_all_2026-10.zim. '
      'What is the best way to protect young fig trees from winter frost?',
    )!;
    expect(fig, contains('fig'));
    expect(fig, contains('frost'));
    expect(fig, isNot(contains('archive')));
    expect(ZimQueryTranslation.fastSpecialistTerms('What is gravity?'), isNull);
  });
}
