import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';

void main() {
  test('restored PALA default and persisted Persian locale are supported',() {
    expect(const InferenceSettings().localeCode,'fa');
    expect(InferenceSettings.fromJson({'localeCode':'fa'}).localeCode,'fa');
    expect(AppLocalizations.supportedLocales,contains(const Locale('fa')));
  });
  testWidgets('Persian UI has actual translated text and RTL layout',(tester) async {
    await tester.pumpWidget(MaterialApp(locale:const Locale('fa'),
      localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:Builder(builder:(context)=>Text(AppLocalizations.of(context).newChat))));
    await tester.pumpAndSettle();
    expect(find.text('گفت‌وگوی جدید'),findsOneWidget);
    expect(Directionality.of(tester.element(find.text('گفت‌وگوی جدید'))),TextDirection.rtl);
  });
}
