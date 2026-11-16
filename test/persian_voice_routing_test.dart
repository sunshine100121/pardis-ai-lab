import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/voice_pipeline.dart';

void main() {
  test('Persian content cannot be voiced by an English natural pack', () {
    expect(voiceLanguageForText('en','این پاسخ فارسی است'),'fa');
    expect(naturalVoiceSpeaks(voiceLanguageForText('en','پاسخ')),false);
    expect(voiceLanguageForText('en','A sample answer'),'en');
    expect(dictationLocale('FA_IR',null),'fa-IR');
    expect(dictationLocale('fa','fa-IR'),'fa-IR');
  });
  test('network, missing pack, wrong language and failed selection never pass',() async {
    var calls=0;
    final voices=[
      {'name':'mock-en','locale':'en-US','network_required':'0'},
      {'name':'mock-online','locale':'fa-IR','network_required':'1'},
      {'name':'mock-missing','locale':'fa-IR','network_required':'0','features':'notInstalled'},
      {'name':'mock-fa','locale':'fa-IR','network_required':'0'},
    ];
    expect(await selectOfflineVoice(language:'fa',voices:()async=>voices,select:(voice)async {
      calls++; expect(voice['name'],'mock-fa'); return 0;
    }),false);
    expect(calls,1);
    expect(await selectOfflineVoice(language:'fa',voices:()async=>voices,
      select:(_)async=>1),true);
    expect(await selectOfflineVoice(language:'fa',voices:()async=>[],
      select:(_)async=>throw StateError('must not select')),false);
  });
}
