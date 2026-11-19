import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/zim/zim_image_selection.dart';

void main() {
  test('six local images: two most relevant first, four on request', () {
    final html = '''
      <article>
        <img src="I/pear-tree.jpg" alt="درخت گلابی">
        <img src="I/pear-rust.jpg" alt="آفت زنگ برگ گلابی">
        <img src="I/pear-aphid.jpg" alt="شته آفت درخت گلابی">
        <img src="I/pear-leaf.jpg" alt="برگ درخت گلابی">
        <img src="I/pear-fruit.jpg" alt="میوه گلابی">
        <img src="I/pear-gallery.jpg" alt="گالری گیاهان">
      </article>
    ''';
    final result = ZimImageSelection.fromArticleHtml(
      html,
      'آفت درخت گلابی',
    );
    expect(result.foundCount, 6);
    expect(result.initial, hasLength(2));
    expect(result.more, hasLength(4));
    expect(result.initial.first.reference, 'I/pear-aphid.jpg');
    expect(result.initial.last.reference, 'I/pear-rust.jpg');
  });

  test('external URLs and repeated assets are not treated as local images', () {
    final result = ZimImageSelection.fromArticleHtml('''
      <img src="https://example.com/pear.jpg" alt="remote">
      <img src="//example.com/photo.png">
      <img src="data:image/png;base64,AAA">
      <img src="I/pear.jpg?width=200" alt="Pear">
      <img src="I/pear.jpg?width=800" alt="Pear">
      <img src="I/icon.png" alt="icon">
      <img src="I/pear.svg">
    ''', 'pear');
    expect(result.foundCount, 2);
    expect(result.initial.first.reference, 'I/pear.jpg');
    expect(result.more, isEmpty);
  });

  test('missing pictures produce an empty gallery, not an invented image', () {
    final result = ZimImageSelection.fromArticleHtml(
      '<p>متن مربوط به بیماری درخت گلابی</p>',
      'گلابی',
    );
    expect(result.foundCount, 0);
    expect(result.initial, isEmpty);
    expect(result.more, isEmpty);
  });

  test('gallery is capped without changing the discovered count', () {
    final html = List.generate(
      12,
      (i) => '<img src="I/image-$i.webp" alt="درخت">',
    ).join();
    final result = ZimImageSelection.fromArticleHtml(html, 'درخت');
    expect(result.foundCount, 12);
    expect(result.candidates, hasLength(6));
    expect(result.initial, hasLength(2));
    expect(result.more, hasLength(4));
  });
}
