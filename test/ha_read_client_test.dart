import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/ha_read_client.dart';

void main() {
  test('GET-only state and bounded history against mock; token and private attributes absent from evidence',() async {
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    addTearDown(()=>server.close(force:true));
    final methods=<String>[], paths=<Uri>[];
    server.listen((req) async {
      methods.add(req.method); paths.add(req.uri);
      expect(req.headers.value('authorization'),'Bearer private-token');
      req.response.headers.contentType=ContentType.json;
      if(req.uri.path.startsWith('/api/states/')) {
        req.response.write(jsonEncode({'entity_id':'sensor.garden','state':'19.5','last_updated':'2026-11-13T10:00:00Z','attributes':{'unit_of_measurement':'C','secret':'private-attribute'}}));
      } else {
        req.response.write(jsonEncode([[{'entity_id':'sensor.garden','state':'10','last_changed':'2026-11-13T10:00:00Z'},
          {'entity_id':'sensor.garden','state':'20','last_changed':'2026-11-13T10:05:00Z'},
          {'entity_id':'sensor.garden','state':'unavailable','last_changed':'2026-11-13T10:10:00Z'}]]));
      }
      await req.response.close();
    });
    final client=HaReadClient(base:Uri.parse('http://127.0.0.1:${server.port}'),token:'private-token',entities:{'sensor.garden'});
    final state=await client.state('sensor.garden');
    expect(state['state'],'19.5');
    final start=DateTime.parse('2026-11-13T10:00:00Z'),end=DateTime.parse('2026-11-13T10:20:00Z');
    final history=await client.history('sensor.garden',start,end);
    expect(history['min'],10); expect(history['max'],20); expect(history['sample_mean'],15);
    expect(history['unavailable_samples'],1); expect(history['gaps_over_5min_seconds'],900);
    expect(methods,['GET','GET']);
    expect(paths.last.queryParameters['filter_entity_id'],'sensor.garden');
    expect(paths.last.queryParameters['significant_changes_only'],'0');
    final evidence=HaReadClient.evidence('garden',state).pageText!;
    expect(evidence,isNot(contains('private-token'))); expect(evidence,isNot(contains('private-attribute')));
    await expectLater(client.state('switch.forbidden'),throwsFormatException);
    await expectLater(client.history('sensor.garden',start,end.add(const Duration(days:1))),throwsFormatException);
    expect(methods,hasLength(2));
  });
  test('no public network, credentials in URL or command entity accepted',() {
    for(final url in ['http://example.com','http://8.8.8.8','http://user:secret@192.168.1.2','http://192.168.1.2/api/services']) {
      expect(()=>HaReadClient(base:Uri.parse(url),token:'x',entities:{'sensor.ok'}),throwsFormatException);
    }
    expect(()=>HaReadClient(base:Uri.parse('http://192.168.1.2'),token:'x',entities:{'switch.pump'}),throwsFormatException);
  });
  test('redirect refused, no credential forwarding',() async {
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    addTearDown(()=>server.close(force:true));
    var hits=0;
    server.listen((r)async { hits++; r.response.statusCode=302; r.response.headers.set('location','http://127.0.0.1:${server.port}/other'); await r.response.close(); });
    final client=HaReadClient(base:Uri.parse('http://127.0.0.1:${server.port}'),token:'x',entities:{'sensor.ok'});
    await expectLater(client.state('sensor.ok'),throwsA(isA<HttpException>()));
    expect(hits,1);
  });
  test('empty history never fills missing measurements with zero',() {
    final start=DateTime.utc(2026),end=DateTime.utc(2026).add(const Duration(hours:1));
    final data=HaReadClient.summarize([],'sensor.garden',start,end);
    expect(data['sample_mean'],isNull); expect(data['min'],isNull); expect(data['gaps_over_5min_seconds'],3600);
  });
}
