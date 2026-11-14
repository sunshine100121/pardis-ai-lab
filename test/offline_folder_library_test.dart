import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';

class TestFolder implements FolderAccess {
  List<LibraryFile> files=[];
  int picks=0, opens=0;
  bool revoked=false;
  final bytes=<String,Uint8List>{};
  @override
  Future<bool> pick() async { picks++; return true; }
  @override
  Future<({String? tree,List<LibraryFile> files})> list() async {
    if(revoked) throw StateError('permission revoked');
    return (tree:'content://test/tree/knowledge',files:files);
  }
  @override
  Future<ZimSource> open(String uri) async { opens++; return MemorySource(bytes[uri]!); }
  void add(String name,Uint8List data) {
    bytes[name]=data;
    files.add((uri:name,name:name,size:data.length,modified:1));
  }
}
class MemorySource implements ZimSource {
  final Uint8List bytes;
  bool closed=false;
  MemorySource(this.bytes);
  @override
  Future<int> length() async=>bytes.length;
  @override
  Future<Uint8List> readAt(int offset,int count) async=>Uint8List.sublistView(bytes,offset,(offset+count).clamp(0,bytes.length));
  @override
  Future<void> close() async { closed=true; }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  test('one tree grant, refresh discovers new files, no original copies and disabled source isolated',() async {
    final folder=TestFolder()..add('notes.txt',Uint8List.fromList(utf8.encode('orchid nutrient concentration is 42.')))
      ..add('model.gguf',Uint8List.fromList([1,2,3]));
    final library=FolderLibrary(access:folder);
    await library.refresh(pick:true);
    expect(folder.picks,1); expect(folder.opens,1);
    expect(await library.search('orchid concentration'),isNotEmpty);
    folder.add('second.md',Uint8List.fromList(utf8.encode('orchid nutrient concentration is 51.')));
    await library.refresh();
    expect(folder.picks,1);
    expect((await library.state())['files'],hasLength(2));
    await library.setEnabled('notes.txt',false);
    expect((await library.search('orchid concentration')).single.pageText,contains('51'));
    final reopened=FolderLibrary(access:folder);
    expect((await reopened.search('orchid concentration')).single.pageText,contains('51'));
    expect(await reopened.indexBytes(),lessThan(FolderLibrary.maxIndexBytes));
    expect(folder.bytes['notes.txt'],Uint8List.fromList(utf8.encode('orchid nutrient concentration is 42.')));
    folder.revoked=true;
    await expectLater(reopened.search('orchid concentration'),throwsStateError);
  });
  test('PDF reader receives bounded bytes and page citation is preserved; EPUB chapter retained',() async {
    final folder=TestFolder()..add('small.pdf',Uint8List.fromList(utf8.encode('%PDF fixture')));
    final zip=Archive()..addFile(ArchiveFile.string('OEBPS/chapter.xhtml','<html><head><title>Orchids</title></head><body><p>Orchid nutrient concentration is 73.</p></body></html>'));
    folder.add('book.epub',Uint8List.fromList(ZipEncoder().encode(zip)));
    final library=FolderLibrary(access:folder,pdfText:(bytes)async {
      expect(utf8.decode(bytes),startsWith('%PDF')); return '--- Page 2 ---\nOrchid nutrient concentration is 42.';
    });
    await library.refresh(pick:true);
    final results=await library.search('orchid nutrient');
    expect(results.any((s)=>s.title.contains('صفحه 2') && s.pageText!.contains('42')),true);
    expect(results.any((s)=>s.title.contains('فصل Orchids') && s.pageText!.contains('73')),true);
  });
  test('two direct ZIM files are independent and remain byte-identical',() async {
    final paths=['test/fixtures/zim/mini.zim','test/fixtures/zim/libzim-modern.zim'];
    final before=[for(final p in paths) await File(p).readAsBytes()];
    final folder=TestFolder();
    for(final p in paths) { folder.files.add((uri:p,name:p,size:await File(p).length(),modified:1)); }
    final library=FolderLibrary(access:folder);
    await library.refresh(pick:true);
    expect(folder.opens,0);
    expect(await library.search('Paris'),hasLength(2));
    await library.setEnabled(paths.first,false);
    expect(await library.search('Paris'),hasLength(1));
    for(var i=0;i<paths.length;i++) { expect(await File(paths[i]).readAsBytes(),before[i]); }
  });
  test('oversized document refused before open and changed source not served from stale index',() async {
    final folder=TestFolder()..add('note.txt',Uint8List.fromList(utf8.encode('orchid text')));
    folder.files.add((uri:'huge.pdf',name:'huge.pdf',size:FolderLibrary.maxDocumentBytes+1,modified:1));
    final library=FolderLibrary(access:folder);
    await library.refresh(pick:true);
    expect(folder.opens,1);
    final state=await library.state();
    expect(state['files'][1]['status'],contains('بدون ساخت کپی'));
    folder.files[0]=(uri:'note.txt',name:'note.txt',size:10,modified:2);
    expect(await library.search('orchid'),isEmpty);
  });
}
