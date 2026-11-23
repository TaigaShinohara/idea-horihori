import 'models.dart';

/// 深掘りセッションの純ロジック（v0.2 項目3・7）。UIから分離してテスト可能に保つ。

/// 逆張り質問を出すべきタイミングか（項目3）。
/// 5問セッションの4問目＝回答が3件のとき、かつ未出の場合だけ true。
bool contrarianDue(DigSession session) =>
    !session.contrarianAsked && session.answers.length == 3;

/// 「1問もどる」が使えるか（項目7）。
/// 回答が1件以上あり、最新の回答に選択肢の記録がある場合だけ可。
/// 旧データの回答（choices 無し）は復元できないので対象外。
bool canUndoLastAnswer(DigSession session) =>
    session.answers.isNotEmpty && session.answers.last.choices != null;

/// 最後の回答を取り消し、その質問を pendingQuestion に復元する（項目7）。
/// 取り消せた場合は取り消した回答を返し、取り消せない場合は null を返す。
/// 逆張り質問の回答を取り消した場合は contrarianAsked も false に戻す。
QaEntry? undoLastAnswer(DigSession session) {
  if (!canUndoLastAnswer(session)) return null;
  final last = session.answers.removeLast();
  session.pendingQuestion = DigQuestion(
    id: last.questionId,
    text: last.question,
    choices: last.choices!,
    isContrarian: last.contrarian,
    source: last.source,
  );
  session.contrarianAsked = session.answers.any((answer) => answer.contrarian);
  return last;
}
