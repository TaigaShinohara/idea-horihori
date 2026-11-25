import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/dev_brief.dart';
import 'package:horihori/models.dart';

void main() {
  const cases = [
    ('返品期限', 'レシート画像は端末外へ送らない。', ['通販で期限を知らなかった', '店頭で期限を知っていたが忘れた']),
    ('コレクション', '端末内で管理し、アカウント登録なしで使う。', ['作品写真を制作順で見たい', 'PDFの先頭ページを見比べたい']),
    ('作業に戻る', '作業を強制中断させない。通知は未定。', ['脱線に気づける合図がほしい', '会議後に中断地点を確認したい']),
  ];
  final date = DateTime(2026, 11, 25);

  for (final (title, constraint, branches) in cases) {
    for (final branch in branches) {
      test('$titleの版から原文と対象の回答だけを読み戻せる（$branch）', () {
        final note = '使う場面を探している。\n${'補足。' * 500}\n$constraint';
        final input = MemoInput(
          title: title,
          note: note,
          sessionId: 'earlier',
          answerCount: 1,
        );
        final memo = PlanMemo(
          what: title,
          who: '',
          why: '',
          how: '',
          nextStep: '',
          createdAt: date,
          version: 1,
          input: input,
        ).copyWith(source: AnswerSource.local);
        final updated = Idea(
          id: 'idea',
          title: '変更後のタイトル',
          note: '変更後のメモ',
          createdAt: date,
          memos: [memo],
          sessions: [
            DigSession(
              id: 'earlier',
              startedAt: date,
              finished: true,
              answers: [
                QaEntry(questionId: 'q1', question: '使う場面は？', answer: branch),
                const QaEntry(
                  questionId: 'q2',
                  question: '続きは？',
                  answer: '追加の回答',
                ),
              ],
            ),
            DigSession(
              id: 'later',
              startedAt: date,
              answers: [
                const QaEntry(
                  questionId: 'q1',
                  question: '別の質問',
                  answer: '別の回の回答',
                ),
              ],
            ),
          ],
        );
        final restored = Idea.fromJson(updated.toJson());
        final storedMemo = restored.memos.single;
        expect(storedMemo.source, AnswerSource.local);
        expect(storedMemo.input!.note, note);
        expect(storedMemo.input!.answersFor(restored).single.answer, branch);
        final brief = buildDevBrief(restored, memo: storedMemo);
        expect(brief, contains('アプリ開発の指示書: $title'));
        expect(brief, contains(note));
        expect(brief, contains(branch));
        expect(brief, isNot(contains('変更後')));
        expect(brief, isNot(contains('追加の回答')));
        expect(brief, isNot(contains('別の回の回答')));
      });
    }
  }

  test('出典の無い旧版と不正な出典データを読み込める', () {
    final old = PlanMemo.fromJson({
      'what': '旧メモ',
      'ease': 3,
      'input': 'broken',
    });
    expect(old.what, '旧メモ');
    expect(old.ease, 3);
    expect(old.input, isNull);
    expect(old.toJson(), isNot(contains('input')));
  });
}
