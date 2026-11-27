import 'package:flutter/material.dart';

import '../models.dart';
import 'glass.dart';
import 'memo_input_view.dart';

typedef _ReviewField = ({TextEditingController controller, FocusNode focus});

/// 保存前に、元の入力を参照しながら下書きを直す。
/// 下書きを作り直したときは呼び出し側でキーを変える。
class MemoReviewPane extends StatefulWidget {
  const MemoReviewPane({
    super.key,
    required this.idea,
    required this.memo,
    required this.busy,
    required this.canSave,
    required this.onChanged,
    required this.onBlur,
    required this.onSave,
    this.onReturnToQuestions,
    this.onEditLastAnswer,
  });

  final Idea idea;
  final PlanMemo memo;
  final bool busy;
  final bool canSave;
  final ValueChanged<PlanMemo> onChanged;
  final VoidCallback onBlur;
  final VoidCallback onSave;
  final VoidCallback? onReturnToQuestions;
  final VoidCallback? onEditLastAnswer;

  @override
  State<MemoReviewPane> createState() => _MemoReviewPaneState();
}

class _MemoReviewPaneState extends State<MemoReviewPane> {
  late final _what = _createField(widget.memo.what);
  late final _who = _createField(widget.memo.who);
  late final _why = _createField(widget.memo.why);
  late final _how = _createField(widget.memo.how);
  late final _openQuestions = _createField(widget.memo.openQuestions ?? '');
  late final _nextStep = _createField(widget.memo.nextStep);

  _ReviewField _createField(String text) {
    final focus = FocusNode();
    var hadFocus = false;
    focus.addListener(() {
      final hasFocus = focus.hasFocus;
      final blurred = hadFocus && !hasFocus;
      hadFocus = hasFocus;
      if (blurred && mounted) widget.onBlur();
    });
    return (controller: TextEditingController(text: text), focus: focus);
  }

  @override
  void dispose() {
    for (final field in [_what, _who, _why, _how, _openQuestions, _nextStep]) {
      field.focus.dispose();
      field.controller.dispose();
    }
    super.dispose();
  }

  void _emitChanges() {
    widget.onChanged(
      widget.memo.copyWith(
        what: _what.controller.text,
        who: _who.controller.text,
        why: _why.controller.text,
        how: _how.controller.text,
        openQuestions: _openQuestions.controller.text,
        nextStep: _nextStep.controller.text,
      ),
    );
  }

  Widget _input(String label, _ReviewField field) {
    return TextField(
      controller: field.controller,
      focusNode: field.focus,
      enabled: !widget.busy,
      minLines: 1,
      maxLines: 4,
      onChanged: (_) => _emitChanges(),
      onTapOutside: (_) => field.focus.unfocus(),
      decoration: glassInputDecoration(context, labelText: label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final returnToQuestions = widget.onReturnToQuestions;
    final editLastAnswer = widget.onEditLastAnswer;
    final intro = switch (widget.memo.source) {
      AnswerSource.local || null => '下書きを確認して、必要な箇所を直せます。',
      _ => 'AIがまとめた下書きです。必要な箇所を直せます。',
    };
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(intro, style: theme.textTheme.bodyMedium)),
              if (widget.memo.source case final source?) ...[
                const SizedBox(width: 8),
                Text(
                  source.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          ReadingGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text('決めたこと', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(height: 10),
                _input('何を作る', _what),
                const SizedBox(height: 8),
                _input('誰に', _who),
                const SizedBox(height: 8),
                _input('なぜ', _why),
                const SizedBox(height: 8),
                _input('どうやって', _how),
                const SizedBox(height: 16),
                _input('未確認のこと', _openQuestions),
                const SizedBox(height: 16),
                _input('次に試すこと', _nextStep),
                if (widget.memo.input case final input?) ...[
                  const SizedBox(height: 8),
                  MemoInputView(input: input, idea: widget.idea),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (!widget.canSave)
            const Text('決めたことや次に試すことを書き足すと保存できます。')
          else if (!widget.memo.hasReviewContent)
            const Text('ここでは元メモと回答を保存できます。'),
          FilledButton(
            onPressed: widget.busy || !widget.canSave ? null : widget.onSave,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: kButtonFill,
              foregroundColor: Colors.white,
            ),
            child: const Text('企画メモを保存'),
          ),
          if (returnToQuestions != null)
            TextButton(
              onPressed: widget.busy ? null : returnToQuestions,
              child: const Text('質問に戻る'),
            )
          else if (editLastAnswer != null)
            TextButton(
              onPressed: widget.busy ? null : editLastAnswer,
              child: const Text('最後の回答を直す'),
            ),
        ],
      ),
    );
  }
}
