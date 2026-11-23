import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/zim/zim_archive.dart';
import 'package:ondevice_llm/features/zim/zim_subtitles.dart';
import 'package:ondevice_llm/features/zim/zim_video_selection.dart';

void main() {
  test('local ZIM video references exclude internet/data/script schemes', () {
    final selected = ZimVideoSelection.fromArticleHtml('''
      <video title="Plant biology">
        <source src="plant.webm" type="video/webm">
        <track src="plant.en.vtt" srclang="en">
        <track src="plant.fa.vtt" srclang="fa">
      </video>
      <a href="http://example.org/fake.mp4">External movie</a>
      <a href="//example.org/fake.mp4">External movie 2</a>
      <a href="data:video/mp4;base64,123">Data movie</a>
      <a href="../outside.mp4">Outside article folder</a>
      <a href="local.mp4">Second video</a>
    ''');
    expect(selected, hasLength(2));
    expect(selected.first.reference, 'plant.webm');
    expect(selected.first.subtitleReference, 'plant.fa.vtt');
    expect(selected.first.subtitleLanguage, 'fa');
    expect(selected.last.reference, 'local.mp4');
    expect(ZimVideoSelection.localReference('javascript:bad.mp4'), isNull);
  });

  test('SRT and VTT captions preserve exact times and searchable transcript', () {
    const vtt = '''WEBVTT

00:00:01.250 --> 00:00:02.500 line:90%
<v Speaker>سلام</v>

00:00:03.000 --> 00:00:05.000
این یک <b>فیلم</b> است
''';
    final cues = ZimSubtitles.parse(vtt);
    expect(cues, hasLength(2));
    expect(ZimSubtitles.at(cues, const Duration(milliseconds: 1500)), 'سلام');
    expect(ZimSubtitles.at(cues, const Duration(milliseconds: 2800)), isNull);
    expect(ZimSubtitles.fullText(cues), contains('فیلم'));
    expect(ZimSubtitles.parse(ZimSubtitles.srt(cues)), hasLength(2));
    expect(ZimSubtitles.parse('00:00:04,000 --> 00:00:03,000\nbad'), isEmpty);
  });

  test('unrelated or remote media never produces a scratch video', () async {
    final zim = await ZimArchive.open('test/fixtures/zim/mini.zim');
    addTearDown(zim.close);
    final article = await zim.findByTitle('Paris');
    expect(article, isNotNull);
    final scratch = File('${Directory.systemTemp.path}/zim-video-invalid.mp4');
    expect(await zim.extractLocalVideo(article!, 'https://bad.org/a.mp4',
        scratch), isFalse);
    expect(await zim.extractLocalVideo(article, 'not-in-archive.mp4',
        scratch), isFalse);
    expect(await scratch.exists(), isFalse);
    expect(await zim.localSubtitle(article, 'https://bad.org/a.vtt'), isNull);
  });
}
