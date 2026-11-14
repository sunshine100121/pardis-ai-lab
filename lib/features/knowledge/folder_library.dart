import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../data/network/web_search/search_models.dart';
import '../attachments/domain/document_text.dart';
import '../zim/zim_source.dart';
import '../zim/zim_wikipedia.dart';

typedef LibraryFile = ({String uri, String name, int size, int modified});

abstract interface class FolderAccess {
  Future<bool> pick();
  Future<({String? tree, List<LibraryFile> files})> list();
  Future<ZimSource> open(String uri);
}

class AndroidFolderAccess implements FolderAccess {
  static const channel = MethodChannel('pala/documents');
  @override
  Future<bool> pick() async => await channel.invokeMethod<bool>('pickTree') ?? false;
  @override
  Future<({String? tree, List<LibraryFile> files})> list() async {
    final data = (await channel.invokeMapMethod<String, dynamic>('listTree'))!;
    return (tree: data['tree'] as String?, files: [for(final f in data['files'] as List)
      (uri:f['uri'] as String,name:f['name'] as String,size:(f['size'] as num).toInt(),modified:(f['modified'] as num).toInt())]);
  }
  @override
  Future<ZimSource> open(String uri) => ZimSource.open(uri);
}

/// Only metadata and a bounded, rebuildable text index are persisted.
/// Original files are never written, removed or copied to app storage.
class FolderLibrary {
  static const key = 'pala_folder_library_v1';
  static const maxDocumentBytes = 8 * 1024 * 1024;
  static const maxIndexBytes = 2 * 1024 * 1024;
  static const extensions = {'zim','pdf','epub','docx','txt','md','markdown','rtf'};
  final FolderAccess access;
  final Future<String> Function(Uint8List) pdfText;
  FolderLibrary({FolderAccess? access, Future<String> Function(Uint8List)? pdfText})
    : access=access ?? AndroidFolderAccess(), pdfText=pdfText ?? readPdf;
  bool _refreshing = false;

  static bool supported(String name) => extensions.contains(name.split('.').last.toLowerCase());
  static String normalize(String s) => s.toLowerCase().replaceAll('ي','ی').replaceAll('ك','ک').replaceAll('\u200c',' ');
  static Future<String> readPdf(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    try {
      if(document.pages.length > 100) throw const FormatException('PDF بیش از ۱۰۰ صفحه است؛ خوانندهٔ محدود این نسخه مناسب آن نیست.');
      final text=StringBuffer();
      for(var i=0;i<document.pages.length;i++) {
        final page=(await document.pages[i].loadText())?.fullText ?? '';
        text.writeln('--- Page ${i+1} ---\n$page');
        if(text.length>DocumentText.maxChars) break;
      }
      if(text.toString().replaceAll(RegExp(r'--- Page \d+ ---'),'').trim().isEmpty) {
        throw const FormatException('این PDF متن قابل‌خواندن ندارد؛ OCR مطمئن در این مسیر فعال نیست.');
      }
      return text.toString();
    } finally { await document.dispose(); }
  }

  Future<Map<String,dynamic>> state() async {
    final raw=(await SharedPreferences.getInstance()).getString(key);
    return raw==null ? {'tree':null,'files':<dynamic>[]} : jsonDecode(raw) as Map<String,dynamic>;
  }
  Future<void> _save(Map<String,dynamic> value) async {
    final encoded=jsonEncode(value);
    if(utf8.encode(encoded).length>maxIndexBytes) throw const FormatException('سقف ۲ MiB نمایه پر شده است؛ منابع کمتری فعال کنید.');
    await (await SharedPreferences.getInstance()).setString(key,encoded);
  }
  Future<int> indexBytes() async => utf8.encode(jsonEncode(await state())).length;
  Future<void> setEnabled(String uri,bool enabled) async {
    final data=await state();
    for(final f in data['files'] as List) { if(f['uri']==uri) f['enabled']=enabled; }
    await _save(data);
  }
  Future<void> refresh({bool pick=false}) async {
    if(_refreshing) throw StateError('بازخوانی در حال انجام است');
    _refreshing=true;
    try {
      if(pick && !await access.pick()) return;
      final listing=await access.list();
      final previous=await state();
      final old={for(final f in previous['files'] as List) f['uri']:f};
      final files=<Map<String,dynamic>>[];
      var readBytes=0, indexed=0;
      for(final file in listing.files.where((f)=>supported(f.name))) {
        final same=old[file.uri];
        final enabled=same?['enabled'] != false;
        final row=<String,dynamic>{'uri':file.uri,'name':file.name,'size':file.size,'modified':file.modified,
          'enabled':enabled,'status':'آمادهٔ جست‌وجو','passages':<dynamic>[]};
        files.add(row);
        if(file.name.toLowerCase().endsWith('.zim')) continue;
        try {
          if(!enabled) { row['status']='غیرفعال؛ برای ساخت نمایه بازخوانی کنید'; continue; }
          if(file.size<0 || file.size>maxDocumentBytes) throw const FormatException('اندازه نامعلوم یا بیش از ۸ MiB؛ بدون ساخت کپی رد شد.');
          if(same!=null && same['size']==file.size && same['modified']==file.modified && (same['passages'] as List).isNotEmpty) {
            row['passages']=same['passages']; row['status']=same['status']; continue;
          }
          if(indexed>=32 || readBytes+file.size>64*1024*1024) throw const FormatException('سقف بازخوانی ۳۲ سند یا ۶۴ MiB پر شد؛ منابع کمتری فعال کنید.');
          indexed++; readBytes+=file.size;
          final source=await access.open(file.uri);
          late Uint8List bytes;
          try {
            final length=await source.length();
            if(length!=file.size || length>maxDocumentBytes) throw const FormatException('اندازه فایل تغییر کرده است؛ دوباره بازخوانی کنید.');
            bytes=await source.readAt(0,length);
            if(bytes.length!=length) throw const FormatException('خواندن فایل ناقص بود');
          } finally { await source.close(); }
          final extracted=await DocumentText.extract(bytes,file.name,pdfText:pdfText,localeCode:'fa').timeout(const Duration(seconds:20));
          if(extracted.text.trim().isEmpty) throw const FormatException('متن قابل‌خواندن موجود نیست');
          row['passages']=passages(extracted.text);
          row['status']='نمایهٔ محدود؛ حداکثر ۲۴ قطعه از ابتدای سند';
          // Keep the serialized index bounded even with many documents.
          if(utf8.encode(jsonEncode(files)).length>maxIndexBytes-16384) {
            row['passages']=<dynamic>[]; row['status']='سقف نمایه پر است؛ این منبع نمایه نشد';
          }
        } catch(e) { row['status']= e is FormatException ? e.message : 'خواندن منبع ناموفق بود؛ مجوز و قالب را بررسی کنید'; }
      }
      await _save({'tree':listing.tree,'files':files});
    } finally { _refreshing=false; }
  }
  static List<Map<String,dynamic>> passages(String text) {
    final marks=RegExp(r'^--- (?:Page (\d+)|فصل: (.+)) ---\s*$',multiLine:true).allMatches(text).toList();
    final out=<Map<String,dynamic>>[];
    void add(String body,String location) {
      for(var at=0;at<body.length && out.length<24;at+=1500) {
        final end=(at+1500).clamp(0,body.length);
        final chunk=body.substring(at,end).trim();
        if(chunk.isNotEmpty) out.add({'location':location,'text':chunk});
      }
    }
    if(marks.isEmpty) { add(text,'بخش متن'); }
    else { for(var i=0;i<marks.length && out.length<24;i++) {
      final mark=marks[i]; add(text.substring(mark.end,i+1<marks.length?marks[i+1].start:text.length),
        mark[1]!=null ? 'صفحه ${mark[1]}' : 'فصل ${mark[2]}');
    } }
    return out;
  }
  Future<List<SearchResult>> search(String question) async {
    final data=await state();
    if(data['tree']==null) return [];
    final live=await access.list(); // Revoked grants and moved/changed files fail closed.
    final current={for(final f in live.files) f.uri:f};
    final terms=normalize(question).split(RegExp(r'[^\p{L}\p{N}]+',unicode:true)).where((s)=>s.length>2).toSet();
    final found=<(int,SearchResult)>[];
    var archives=0;
    for(final f in data['files'] as List) {
      final now=current[f['uri']];
      if(f['enabled']!=true || now==null || now.size!=f['size'] || now.modified!=f['modified']) continue;
      if((f['name'] as String).toLowerCase().endsWith('.zim')) {
        if(archives++>=8) continue;
        final wiki=ZimWikipedia(f['uri'] as String);
        try { final result=await wiki.lookup(question).timeout(const Duration(seconds:8));
          if(result!=null) found.add((100,result));
        } catch(_) { /* One unavailable encyclopedia must not hide other sources. */ }
        finally { await wiki.close(); }
        continue;
      }
      for(final p in f['passages'] as List) {
        final text=normalize(p['text'] as String);
        final score=terms.where(text.contains).length;
        if(score==0) continue;
        final id=sha256.convert(utf8.encode(f['uri'] as String)).toString();
        found.add((score,SearchResult(title:'${f['name']} · ${p['location']}',url:'pala-knowledge://$id',
          snippet:'',source:'پوشه AI Knowledge',rank:score,pageText:p['text'] as String,
          fetchedAt:DateTime.now().toUtc())));
      }
    }
    found.sort((a,b)=>b.$1.compareTo(a.$1));
    return found.take(4).map((e)=>e.$2).toList();
  }
}

final folderLibraryProvider=Provider<FolderLibrary>((ref)=>FolderLibrary());
