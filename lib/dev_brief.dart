import 'models.dart';

/// 開発指示書の書き出し（v0.2 項目5）。
/// 育った企画メモを「アプリを作って」と他のAI／開発者へ渡せる指示文に変換する純関数。
/// メモが無いアイデアでは呼び出し側でボタンを無効化すること（ここでは
/// メモ欄を「（まだ企画メモがない）」として組み立てる）。
String buildDevBrief(Idea idea) {
  final buf = StringBuffer();
  buf.writeln('アプリ開発の指示書: ${idea.title}');
  buf.writeln();

  final memo = idea.memos.isEmpty ? null : idea.memos.last;
  if (memo == null) {
    buf.writeln('（まだ企画メモがない）');
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

  final allAnswers = [for (final s in idea.sessions) ...s.answers];
  if (allAnswers.isNotEmpty) {
    buf.writeln();
    buf.writeln('## 深掘りQ&Aの要点');
    for (final a in allAnswers) {
      buf.writeln('- Q: ${a.question} → A: ${a.answer}');
    }
  }

  buf.writeln();
  buf.write('この企画でアプリを作ってください。まず設計案と画面一覧を出し、最小構成で動くところまで作ってください。');
  return buf.toString();
}
