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
  const DevBriefScreen({super.key, required this.idea});

  @override
  Widget build(BuildContext context) {
    final brief = buildDevBrief(idea);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('開発指示書'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GlassBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            ReadingGlass(
              child: SelectableText(
                brief,
                style: const TextStyle(fontSize: 14, height: 1.7),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: kButtonFill,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: brief));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('指示書をコピーしたよ')),
                  );
                }
              },
              icon: const Icon(Icons.copy, size: 19),
              label: const Text('コピー'),
            ),
          ],
        ),
      ),
    );
  }
}
