import 'models.dart';

/// 企画書の整形（v0.5.0）。完成した企画メモを、Google ドキュメント化や
/// 外部共有に使うプレーンテキストへ変換する純関数。
///
/// 既存の書き出し整形である開発指示書（buildDevBrief）と欄構成
/// （5欄＋元メモ＋Q&A）を揃えて正とするが、指示書末尾の
/// 「この企画でアプリを作ってください」等の指示文は企画書には不要なため
/// 含めない。メモが無い場合は呼び出し側で弾くこと（ここでは
/// buildDevBrief と同様に「（まだ企画メモがない）」として組み立てる）。
String buildPlanDocument(Idea idea, {PlanMemo? memo}) {
  memo ??= idea.memos.isEmpty ? null : idea.memos.last;
  final input = memo?.input;
  final reviewed = memo?.openQuestions != null;
  final buf = StringBuffer();
  buf.writeln('企画書: ${input?.title ?? idea.title}');
  if (memo != null) {
    final d = memo.createdAt;
    buf.writeln('（メモ v${memo.version}／${d.year}/${d.month}/${d.day}）');
  }
  buf.writeln();

  if (memo == null) {
    buf.writeln('（まだ企画メモがない）');
    return buf.toString();
  }

  if (reviewed) {
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
    buf.writeln(input == null ? '## 深掘りQ&A' : '## この版の質問と回答');
    for (final a in answers) {
      buf.writeln('- Q: ${a.question} → A: ${a.answer}');
    }
  }
  return buf.toString();
}

/// ドライブ上に作る Google ドキュメントの名前。
String planDocumentName(Idea idea, {PlanMemo? memo}) {
  memo ??= idea.memos.isEmpty ? null : idea.memos.last;
  final title = memo?.input?.title ?? idea.title;
  return memo == null ? '$title 企画書' : '$title 企画書 v${memo.version}';
}
