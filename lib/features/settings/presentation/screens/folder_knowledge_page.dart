import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../knowledge/folder_library.dart';
import '../../../knowledge/ha_read_client.dart';
import '../../../knowledge/offline_knowledge.dart';

class FolderKnowledgePage extends ConsumerStatefulWidget {
  const FolderKnowledgePage({super.key});
  @override
  ConsumerState<FolderKnowledgePage> createState()=>_FolderKnowledgePageState();
}
class _FolderKnowledgePageState extends ConsumerState<FolderKnowledgePage> {
  Map<String,dynamic> _data={'files':<dynamic>[]};
  int _bytes=0;
  bool _busy=false;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final library=ref.read(folderLibraryProvider);
    final value=await library.state(); final bytes=await library.indexBytes();
    if(mounted) setState(() { _data=value; _bytes=bytes; });
  }
  Future<void> _refresh(bool pick) async {
    setState(() { _busy=true; _error=null; });
    try { await ref.read(folderLibraryProvider).refresh(pick:pick); await _load(); }
    catch(_) { if(mounted) setState(()=>_error='پوشه خوانده نشد؛ دسترسی یا محدودیت حجم/تعداد منابع را بررسی کنید.'); }
    finally { if(mounted) setState(()=>_busy=false); }
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('پوشه دانش')),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      const Text('پوشه موجود AI Knowledge را یک‌بار انتخاب کنید. مدل GGUF وارد نمایه نمی‌شود و فایل اصلی تغییر نمی‌کند.'),
      Wrap(spacing:12,children:[
        FilledButton(onPressed:_busy?null:()=>_refresh(true),child:const Text('انتخاب پوشه دانش')),
        OutlinedButton(onPressed:_busy?null:()=>_refresh(false),child:const Text('بازخوانی منابع')),
      ]),
      if(_busy) const LinearProgressIndicator(),
      if(_error!=null) Text(_error!),
      Text('حجم نمایهٔ مشتق‌شده: $_bytes بایت از ${FolderLibrary.maxIndexBytes}'),
      const Text('نمایهٔ اسناد حداکثر ۲۴ قطعه از ابتدای هر سند است؛ نبود نتیجه به معنی نبود مطلب در کل کتاب نیست. PDF اسکن‌شده در این مسیر OCR نمی‌شود.'),
      for(final f in _data['files'] as List) SwitchListTile(
        title:Text(f['name'] as String),subtitle:Text('${f['status']} · ${f['size']} بایت'),value:f['enabled']==true,
        onChanged:_busy?null:(v) async { await ref.read(folderLibraryProvider).setEnabled(f['uri'] as String,v); await _load(); },
      ),
      ExpansionTile(title:const Text('پیشرفته'),children:[
        SelectableText(_data['tree']?.toString() ?? 'هنوز پوشه انتخاب نشده است'),
        const Text('یک مجوز فقط‌خواندنی پوشه؛ در صورت جابه‌جایی فایل یا لغو مجوز دوباره بازخوانی کنید. سقف سند ۸ MiB، PDF صد صفحه، نمایه ۲ MiB است. برای ZIM خواندن انتخابی انجام می‌شود.'),
        ListTile(title:const Text('Home Assistant · فقط خواندن'),trailing:const Icon(Icons.chevron_right),
          onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const HaReadSettingsPage()))),
      ]),
    ]),
  );
}

class HaReadSettingsPage extends StatefulWidget {
  const HaReadSettingsPage({super.key});
  @override
  State<HaReadSettingsPage> createState()=>_HaReadSettingsPageState();
}
class _HaReadSettingsPageState extends State<HaReadSettingsPage> {
  final _base=TextEditingController(),_entities=TextEditingController(),_token=TextEditingController();
  bool _enabled=false,_ack=false,_saving=false;
  String? _status;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final raw=(await SharedPreferences.getInstance()).getString(OfflineKnowledge.configKey);
    if(!mounted || raw==null) return;
    final data=jsonDecode(raw) as Map<String,dynamic>;
    _base.text=data['base'] as String;
    _entities.text=(data['entities'] as Map).entries.map((e)=>'${e.key}=${e.value}').join('\n');
    setState(()=>_enabled=data['enabled']==true);
  }
  @override
  void dispose() { _base.dispose(); _entities.dispose(); _token.dispose(); super.dispose(); }
  Future<void> _save() async {
    setState(()=>_saving=true);
    try {
      if(!_ack) throw const FormatException('محدودیت اختیار توکن را تأیید کنید.');
      final map=<String,String>{};
      for(final line in _entities.text.split('\n').where((s)=>s.trim().isNotEmpty)) {
        final at=line.indexOf('=');
        if(at<1 || line.substring(at+1).trim().length<3) throw const FormatException('هر حسگر باید نام فارسی حداقل سه‌حرفی داشته باشد.');
        map[line.substring(0,at).trim()]=line.substring(at+1).trim();
      }
      final previous=await OfflineKnowledge.secure.read(key:OfflineKnowledge.tokenKey);
      final token=_token.text.trim().isEmpty ? previous ?? '' : _token.text.trim();
      final base=Uri.parse(_base.text.trim());
      HaReadClient(base:base,token:token,entities:map.keys.toSet());
      await OfflineKnowledge.secure.write(key:OfflineKnowledge.tokenKey,value:token);
      await (await SharedPreferences.getInstance()).setString(OfflineKnowledge.configKey,jsonEncode({'base':base.toString(),'entities':map,'enabled':_enabled}));
      _token.clear();
      if(mounted) setState(()=>_status='ذخیره شد؛ درخواست شبکه فقط هنگام پرسش مرتبط انجام می‌شود.');
    } catch(e) { if(mounted) setState(()=>_status=e is FormatException?e.message:'ذخیره امن اتصال ممکن نشد.'); }
    finally { if(mounted) setState(()=>_saving=false); }
  }
  @override
  Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Home Assistant · خواندنی')),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      const Text('این برنامه فقط GET حسگر و تاریخچه یک ساعت اخیر را درخواست می‌کند. توکن HA ذاتاً فقط‌خواندنی نیست؛ از حساب اختصاصی غیرمدیر با حداقل اختیار موجود استفاده کنید. توکن مدیر را وارد نکنید. HTTP محلی رمزگذاری ندارد؛ در شبکه نامطمئن از HTTPS معتبر استفاده کنید. هیچ تنظیم HA خودکار تغییر نمی‌کند.'),
      TextField(controller:_base,decoration:const InputDecoration(labelText:'نشانی LAN با IP ثابت؛ مانند http://192.168.1.2:8123')),
      TextField(controller:_entities,maxLines:5,decoration:const InputDecoration(labelText:'حسگرهای مجاز؛ هر خط sensor.example=دمای باغ')),
      TextField(controller:_token,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'توکن؛ خالی یعنی حفظ مقدار قبلی')),
      SwitchListTile(title:const Text('خواندن هنگام پرسش'),value:_enabled,onChanged:_saving?null:(v)=>setState(()=>_enabled=v)),
      CheckboxListTile(title:const Text('می‌دانم محدودیت GET در برنامه، اختیار سرورِ توکن را کاهش نمی‌دهد.'),value:_ack,onChanged:_saving?null:(v)=>setState(()=>_ack=v==true)),
      FilledButton(onPressed:_saving?null:_save,child:const Text('ذخیره اتصال')),
      const Text('نام فارسی حسگر را در پرسش بیاورید. «تاریخچه دمای باغ» فقط یک ساعت اخیر را می‌خواند. داده پنج‌دقیقه‌ای یا دوره نگهداری Recorder مفروض نیست. HA Doctor فقط پیشنهاد می‌دهد.'),
      if(_status!=null) Text(_status!),
    ]));
}
