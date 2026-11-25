import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dev_brief.dart';
import '../models.dart';
import '../widgets/glass.dart';

/// 開発指示書のプレビュー画面（v0.2 項目5）。
/// 企画メモから組み立てた指示文を確認し、クリップボードへコピーできる。
/// 共有シートは新規依存を増やさない範囲では用意せず、コピーを必須とする。
class DevBriefScreen extends StatelessWidget {
  final Idea idea;
  final PlanMemo? memo;
  const DevBriefScreen({super.key, required this.idea, this.memo});

  @override
  Widget build(BuildContext context) {
    final brief = buildDevBrief(idea, memo: memo);
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('開発指示書'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: ReadingGlass(
                  child: SelectableText(
                    brief,
                    style: const TextStyle(fontSize: 14, height: 1.7),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: kButtonFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: () async {
                    var message = '指示書をコピーしました';
                    try {
                      await Clipboard.setData(ClipboardData(text: brief));
                    } catch (_) {
                      message = 'コピーできませんでした。本文を選択してコピーできます。';
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message)));
                    }
                  },
                  icon: const Icon(Icons.copy, size: 19),
                  label: const Text('コピー'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
