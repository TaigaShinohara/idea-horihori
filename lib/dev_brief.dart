import 'models.dart';

/// 開発指示書の書き出し（v0.2 項目5）。
/// 育った企画メモを「アプリを作って」と他のAI／開発者へ渡せる指示文に変換する純関数。
/// メモが無いアイデアでは呼び出し側でボタンを無効化すること（ここでは
/// メモ欄を「（まだ企画メモがない）」として組み立てる）。
String buildDevBrief(Idea idea, {PlanMemo? memo}) {
  memo ??= idea.memos.isEmpty ? null : idea.memos.last;
  final input = memo?.input;
  final reviewed = memo?.openQuestions != null;
  final buf = StringBuffer();
  buf.writeln('アプリ開発の指示書: ${input?.title ?? idea.title}');
  buf.writeln();

  if (memo == null) {
    buf.writeln('（まだ企画メモがない）');
  } else if (reviewed) {
    buf.writeln('## 決めたこと');
    for (final (label, value) in [
      ('何を作る', memo.what),
      ('誰に', memo.who),
      ('なぜ', memo.why),
      ('どうやって', memo.how),
    ]) {
      if (value.isNotEmpty) buf.writeln('- $label: $value');
    }
    if (!memo.hasConfirmedDetails) buf.writeln('（確認中）');
    if (memo.openQuestions!.isNotEmpty) {
      buf.writeln();
      buf.writeln('## 未確認のこと');
      buf.writeln(memo.openQuestions);
    }
    if (memo.nextStep.isNotEmpty) {
      buf.writeln();
      buf.writeln('## 次に試すこと');
      buf.writeln(memo.nextStep);
    }
  } else {
    buf.writeln('## 企画メモ');
    buf.writeln('- 何を作る: ${memo.what}');
    buf.writeln('- 誰に: ${memo.who}');
    buf.writeln('- なぜ: ${memo.why}');
    buf.writeln('- どうやって: ${memo.how}');
    buf.writeln('- 次の一歩: ${memo.nextStep}');
    if (memo.hasFitness) {
      final parts = <String>[
        if (memo.ease != null) '作りやすさ ${fitnessDots(memo.ease!)}',
        if (memo.spark != null) 'ワクワク度 ${fitnessDots(memo.spark!)}',
      ];
      buf.writeln('- 体力測定: ${parts.join(' ／ ')}');
    }
  }

  if (input != null && input.note.isNotEmpty) {
    buf.writeln();
    buf.writeln('## 元メモ');
    buf.writeln(input.note);
  }

  final answers = input?.answersFor(idea) ??
      [for (final s in idea.sessions) ...s.answers];
  if (answers.isNotEmpty) {
    buf.writeln();
    buf.writeln(input == null ? '## 深掘りQ&Aの要点' : '## この版の質問と回答');
    for (final a in answers) {
      buf.writeln('- Q: ${a.question} → A: ${a.answer}');
    }
  }

  buf.writeln();
  if (input != null) {
    buf.writeln('元メモの制約を守り、矛盾や未確認の要件は実装前に本人へ確認してください。');
  }
  if (reviewed) {
    if (memo!.what.trim().isEmpty) {
      buf.write('元メモと回答を読み、先に作るものと検証する仮説を本人に確認してください。');
    } else {
      buf.write('決めたことをもとに最小構成の設計案を作り、未確認のことは検証項目として扱ってください。');
    }
  } else {
    buf.write('この企画でアプリを作ってください。まず設計案と画面一覧を出し、最小構成で動くところまで作ってください。');
  }
  return buf.toString();
}
