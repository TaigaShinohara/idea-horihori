import 'package:flutter/material.dart';

import '../models.dart';
import 'glass.dart';

/// 企画メモを作ったときの入力を、確認と履歴の両方で表示する。
class MemoInputView extends StatelessWidget {
  final MemoInput input;
  final Idea idea;

  const MemoInputView({super.key, required this.input, required this.idea});

  @override
  Widget build(BuildContext context) {
    final answers = input.answersFor(idea);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          title: Text(
            '元メモと回答',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: accentTextColor(context),
            ),
          ),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          expandedAlignment: Alignment.centerLeft,
          children: [
            SelectableText(
              input.title,
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
            if (input.note.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                input.note,
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ],
            for (final answer in answers) ...[
              const SizedBox(height: 12),
              SelectableText(
                'Q: ${answer.question}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                'A: ${answer.answer}',
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
