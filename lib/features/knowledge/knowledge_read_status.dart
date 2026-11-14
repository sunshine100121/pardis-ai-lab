import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'knowledge_read_report.dart';

/// Separate from model prose and source chips; retained in the turn's runJson.
class KnowledgeReadStatus extends StatelessWidget {
  final Map<String,dynamic> report;
  final bool showSummary;
  const KnowledgeReadStatus({super.key,required this.report,this.showSummary=true});
  @override
  Widget build(BuildContext context) {
    final checks=(report['checks'] as List? ?? []).cast<Map<String,dynamic>>();
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      if(showSummary) Text(KnowledgeReadReport.summary(report),key:const Key('knowledge-source-status')),
      ExpansionTile(title:const Text('جزئیات خواندن دانشنامه'),children:[
        if(checks.isEmpty) const Text('دانشنامهٔ فعال و قابل بررسی در پوشه انتخاب نشده است.'),
        for(final check in checks) ListTile(title:Text(KnowledgeReadReport.checkLabel(check)),
          subtitle:Text('${KnowledgeReadReport.stageLabel('${check['stage']}')} · ${check['elapsedMs'] ?? 0} ms\n'
            '${check['readCalls'] ?? 0} خواندن · ${check['readBytes'] ?? 0} بایت · offset ${check['highestOffset'] ?? 0}')),
        TextButton.icon(onPressed:() async {
          await Clipboard.setData(ClipboardData(text:const JsonEncoder.withIndent('  ').convert(report)));
          if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('گزارش خواندن کپی شد')));
        },icon:const Icon(Icons.copy),label:const Text('کپی گزارش خواندن')),
      ]),
    ]);
  }
}
