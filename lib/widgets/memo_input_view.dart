import 'package:flutter/material.dart';

import '../models.dart';

/// 企画メモを作ったときの入力を、確認と履歴の両方で表示する。
class MemoInputView extends StatelessWidget {
  final MemoInput input;
  final Idea idea;

  const MemoInputView({super.key, required this.input, required this.idea});

  @override
  Widget build(BuildContext context) {
    final answers = input.answersFor(idea);
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        title: const Text('元メモと回答'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        expandedAlignment: Alignment.centerLeft,
        children: [
          SelectableText(input.title),
          if (input.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(input.note),
          ],
          for (final answer in answers) ...[
            const SizedBox(height: 12),
            SelectableText('Q: ${answer.question}\nA: ${answer.answer}'),
          ],
        ],
      ),
    );
  }
}
