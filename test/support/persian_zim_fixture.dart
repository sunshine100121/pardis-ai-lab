import 'dart:convert';
import 'dart:typed_data';
import 'package:ondevice_llm/features/zim/zim_source.dart';

/// A valid modern ZIM with an exact Persian redirect. The large variant is
/// virtual: offsets exceed 4 GiB and a stored cluster exceeds 64 MiB, while
/// only a few KiB exist in RAM. No large file is created or copied.
class SparseZimSource implements ZimSource {
  final Map<int,Uint8List> pieces;
  final int size;
  int bytesRead=0,maxRead=0,highestOffset=0;
  bool closed=false;
  SparseZimSource(this.pieces,this.size);
  SparseZimSource fresh()=>SparseZimSource(pieces,size);
  @override
  Future<int> length() async=>size;
  @override
  Future<Uint8List> readAt(int offset,int count) async {
    if(closed) throw StateError('closed fixture');
    if(count>1024*1024) throw StateError('whole cluster read attempted');
    if(offset<0 || offset>size) throw RangeError('fixture range');
    final length=count.clamp(0,size-offset);
    final out=Uint8List(length);
    for(final item in pieces.entries) {
      final lo=offset>item.key?offset:item.key;
      final hi=offset+length<item.key+item.value.length?offset+length:item.key+item.value.length;
      if(hi>lo) out.setRange(lo-offset,hi-offset,item.value,lo-item.key);
    }
    bytesRead+=length;
    if(count>maxRead) maxRead=count;
    if(offset>highestOffset) highestOffset=offset;
    return out;
  }
  @override
  Future<void> close() async { closed=true; }
}

SparseZimSource persianZim({bool large=false,bool shortText=false,String archive='دانشنامهٔ فارسی آزمون'}) {
  final entries=<Map<String,dynamic>>[
    {'ns':'C','url':'Behbahan','title':'بهبهان','text':'<html><body><h1>بهبهان</h1><p>بهبهان شهری در استان خوزستان در جنوب غربی ایران است. این مقاله متن ساختگی آزمون برای بررسی خواندن و استناد واقعی از دانشنامه است و دادهٔ مالک نیست.</p></body></html>'},
    {'ns':'C','url':'Mars','title':'بهرام (سیاره)','text':'<html><body><h1>بهرام (سیاره)</h1><p>مریخ یا بهرام چهارمین سیاره از خورشید است. این متن فارسیِ ساختگی برای آزمون بازیابی مقاله و تبدیل HTML به شاهد قابل‌استناد در برنامه استفاده می‌شود.</p></body></html>'},
    {'ns':'C','url':'Mars_alias','title':'مریخ','redirect':'Mars'},
    {'ns':'M','url':'Title','title':'Title','text':archive},
    {'ns':'M','url':'Language','title':'Language','text':'fas'},
    {'ns':'M','url':'Date','title':'Date','text':'2026-11-15'},
    {'ns':'X','url':'listing/titleOrdered/v1','title':'listing/titleOrdered/v1'},
  ]..sort((a,b)=>'${a['ns']}${a['url']}'.compareTo('${b['ns']}${b['url']}'));
  if(shortText) {
    for(final entry in entries.where((e)=>e['ns']=='C' && !e.containsKey('redirect'))) {
      entry['text']='<html><body>کوتاه</body></html>';
    }
  }
  Uint8List numbers(List<int> values,int width) {
    final data=ByteData(values.length*width);
    for(var i=0;i<values.length;i++) {
      if(width==8) { data.setUint64(i*width,values[i],Endian.little); }
      else { data.setUint32(i*width,values[i],Endian.little); }
    }
    return data.buffer.asUint8List();
  }
  final order=List<int>.generate(entries.length,(i)=>i)
    ..sort((a,b)=>'${entries[a]['ns']}${entries[a]['title']}'.compareTo('${entries[b]['ns']}${entries[b]['title']}'));
  final blobs=<Uint8List>[];
  for(final entry in entries) {
    if(entry.containsKey('redirect')) continue;
    entry['blob']=blobs.length;
    blobs.add(entry['ns']=='X'?numbers(order,4):Uint8List.fromList(utf8.encode(entry['text'] as String)));
  }
  // An unrelated large blob shares the stored cluster with the title list.
  final offsets=<int>[];
  var at=(blobs.length+2)*8;
  for(final blob in blobs) { offsets.add(at); at+=blob.length; }
  offsets.add(at); at+=large?70*1024*1024:16; offsets.add(at);
  final dirs=<Uint8List>[];
  for(final entry in entries) {
    final redirect=entry.containsKey('redirect');
    final header=ByteData(redirect?12:16);
    header.setUint16(0,redirect?0xffff:entry['ns']=='C'?0:1,Endian.little);
    header.setUint8(3,(entry['ns'] as String).codeUnitAt(0));
    header.setUint32(8,redirect?entries.indexWhere((e)=>e['ns']=='C'&&e['url']==entry['redirect']):0,Endian.little);
    if(!redirect) header.setUint32(12,entry['blob'] as int,Endian.little);
    dirs.add(Uint8List.fromList([...header.buffer.asUint8List(),...utf8.encode(entry['url'] as String),0,
      ...utf8.encode(entry['title'] as String),0]));
  }
  final mime=Uint8List.fromList(utf8.encode('text/html\x00text/plain\x00\x00'));
  final pieces=<int,Uint8List>{80:mime};
  var pos=80+mime.length;
  final dirPositions=<int>[];
  for(final dir in dirs) { dirPositions.add(pos); pieces[pos]=dir; pos+=dir.length; }
  final urlTable=pos; pieces[pos]=numbers(dirPositions,8); pos+=entries.length*8;
  final clusterTable=pos; pos+=8;
  final clusterStart=large?(1<<32)+4096:pos;
  pieces[clusterTable]=numbers([clusterStart],8);
  pieces[clusterStart]=Uint8List.fromList([0x11]);
  pieces[clusterStart+1]=numbers(offsets,8);
  for(var i=0;i<blobs.length;i++) { pieces[clusterStart+1+offsets[i]]=blobs[i]; }
  final checksum=clusterStart+1+at;
  final h=ByteData(80)..setUint32(0,72173914,Endian.little)..setUint16(4,6,Endian.little)
    ..setUint16(6,3,Endian.little)..setUint32(24,entries.length,Endian.little)..setUint32(28,1,Endian.little)
    ..setUint64(32,urlTable,Endian.little)..setUint64(40,0,Endian.little)..setUint64(48,clusterTable,Endian.little)
    ..setUint64(56,80,Endian.little)..setUint32(64,0xffffffff,Endian.little)..setUint32(68,0xffffffff,Endian.little)
    ..setUint64(72,checksum,Endian.little);
  h.setUint8(8,large?2:1);
  pieces[0]=h.buffer.asUint8List();
  return SparseZimSource(pieces,checksum+16);
}
