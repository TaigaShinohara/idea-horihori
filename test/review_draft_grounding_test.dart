import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/fallback.dart';
import 'package:horihori/first_dig.dart';
import 'package:horihori/models.dart';
import 'package:horihori/prompts.dart';
import 'package:horihori/review_draft_grounding.dart';

const _emptySelection = {
  'what': 'none',
  'who': 'none',
  'why': 'none',
  'how': 'none',
  'nextStep': 'none',
  'openQuestions': 'none',
};

PlanMemo _groundedMemo(
  List<QaEntry> history, {
  Map<String, String> selection = const {},
  String note = '',
}) => ReviewDraftGrounding.fromAnswers(
  history,
  budget: Prompts.standardBudget,
  note: note,
).build(version: 1, selection: selection);

void main() {
  test('reviewDraftの要約プロンプトは元メモとQ&Aを含み、6欄を日本語でまとめさせる', () {
    const history = [
      QaEntry(
        questionId: 'q1',
        question: '最初に使う場面は？',
        answer: 'きのうの出来事をサッと振り返るとき',
      ),
    ];
    final prompt = Prompts.summarize(
      title: 'めま',
      note: '日付と内容を自動で保存する',
      history: history,
      reviewDraft: true,
    );
    expect(prompt, contains('めま'));
    expect(prompt, contains('日付と内容を自動で保存する'));
    expect(prompt, contains('最初に使う場面は？'));
    expect(prompt, contains('きのうの出来事をサッと振り返るとき'));
    expect(prompt, contains('openQuestions'));
    expect(prompt, contains('nextStep'));
  });

  test('reviewDraftのparseMemoはAIがまとめた文章を受け取り、空欄やnoneを空文字に正規化する', () {
    final memo = Prompts.parseMemo(
      jsonEncode({
        'what': '日付と内容を自動で保存するメモアプリ',
        'who': '昨日の出来事を振り返りたい自分',
        'why': 'あとから見返すときに思い出せず困るため',
        'how': 'none',
        'openQuestions': '',
        'nextStep': '1日分の入力画面を作って試す',
      }),
      version: 2,
      reviewDraft: true,
    );
    expect(memo, isNotNull);
    expect(memo!.version, 2);
    expect(memo.what, '日付と内容を自動で保存するメモアプリ');
    expect(memo.who, '昨日の出来事を振り返りたい自分');
    expect(memo.why, 'あとから見返すときに思い出せず困るため');
    expect(memo.how, '');
    expect(memo.openQuestions, '');
    expect(memo.nextStep, '1日分の入力画面を作って試す');
    expect(memo.hasFitness, false);

    // 制御文字や過大長は拒否する。
    final unsafe = Prompts.parseMemo(
      jsonEncode({
        'what': 'ok\u0000bad',
        'who': '',
        'why': '',
        'how': '',
        'openQuestions': '',
        'nextStep': '',
      }),
      version: 1,
      reviewDraft: true,
    );
    expect(unsafe, isNull);
  });

  test('ReviewDraftGroundingは決定欄で選ばれた回答の全文を使う', () {
    const certain = QaEntry(
      questionId: 'one',
      question: 'AIが発案した同期',
      answer: '手段は制作順の一覧にする。作品ごとにまとめる。',
    );
    const history = [certain];
    final memo = _groundedMemo(
      history,
      selection: {
        ..._emptySelection,
        'what': '制作順に表示する',
        'how': 'a1',
        'nextStep': 'a99',
      },
    );
    expect(memo.what, '');
    expect(memo.how, certain.answer);
    expect(memo.nextStep, '');
  });

  test('留保や否定を含む全文は未確認に残し、確定欄に移さない', () {
    const caveat = QaEntry(
      questionId: 'one',
      question: 'どんな保存方法？',
      answer: '手入力で記録する。しかし今はその方法で進めない。',
    );
    const mixed = QaEntry(
      questionId: 'two',
      question: '作りたいものは？',
      answer: '写真をまとめたいわけではなく、その場で期限だけ入力する。',
    );
    final memo = _groundedMemo(
      const [caveat, mixed],
      selection: {
        ..._emptySelection,
        'what': 'a2',
        'how': 'a1',
        'openQuestions': 'a2',
      },
    );
    expect(memo.what, '');
    expect(memo.how, '');
    expect(memo.openQuestions, mixed.answer);
  });

  test('深掘り2問目の試し方は決定欄に移さず、アプリの試行へ結びつける', () {
    final answer = QaEntry(
      questionId: FollowUpFocus.tellApart.questionId,
      question: 'AIが発案したファイル名検索',
      answer: '候補の1ページ目を見比べたい',
      axis: 'approach',
    );
    final memo = _groundedMemo(
      [answer],
      selection: {..._emptySelection, 'how': 'a1'},
    );
    expect(memo.how, '');
    expect(memo.nextStep, contains(FollowUpFocus.tellApart.trial));
    expect(memo.nextStep, contains(answer.answer));
    expect(memo.nextStep, isNot(contains(answer.question)));
    final local = LocalMemoBuilder.build(
      title: '似たPDFを見分ける',
      answers: [answer],
      version: 1,
      reviewDraft: true,
    );
    expect(local.nextStep, memo.nextStep);
  });

  test('AIの自由な質問IDからアプリの試し方を推定しない', () {
    final answer = QaEntry(
      questionId: FollowUpFocus.tellApart.questionId,
      question: '次は何をする？',
      answer: '似たファイルを開いた。',
      source: AnswerSource.onDevice,
    );
    final memo = _groundedMemo([answer], selection: _emptySelection);
    expect(memo.nextStep, '');
  });

  test('明示的に次に試すと答えたときだけ通常の回答を次の一歩に使う', () {
    const history = [
      QaEntry(questionId: 'one', question: '手段は？', answer: '自分で入力する。'),
      QaEntry(
        questionId: 'two',
        question: '次にどう進める？',
        answer: 'まず手元のレシートを一枚使って入力を試す。',
      ),
    ];
    expect(
      _groundedMemo([history.first], selection: {..._emptySelection, 'nextStep': 'a1'}).nextStep,
      '',
    );
    expect(
      _groundedMemo(history, selection: {..._emptySelection, 'nextStep': 'a1'}).nextStep,
      history.last.answer,
    );
  });

  test('試したい気持ちがあっても無理だと答えた方法は提案しない', () {
    final answer = QaEntry(
      questionId: FollowUpFocus.findInformation.questionId,
      axis: FollowUpFocus.findInformation.axis,
      question: '何を確認したい？',
      answer: '期限を知りたいが、資料はもう残っていないので確認できない。',
    );
    final memo = _groundedMemo([answer], selection: _emptySelection);
    expect(memo.nextStep, '');
    expect(
      LocalMemoBuilder.build(
        title: '返品期限',
        answers: [answer],
        version: 1,
        reviewDraft: true,
      ).nextStep,
      '',
    );
  });

  test('2問目と異なる試し方を希望した自由回答に、元の試行を当てはめない', () {
    const focus = FollowUpFocus.findInformation;
    const original = '資料は調べずに、手入力にかかる時間を確認したい。';
    final answer = QaEntry(
      questionId: focus.questionId,
      question: focus.question,
      axis: focus.axis,
      answer: original,
    );
    final memo = _groundedMemo(
      [answer],
      selection: {..._emptySelection, 'openQuestions': 'a1'},
    );
    expect(memo.nextStep, '');
    expect(memo.openQuestions, original);
  });

  test('別の行為の否定を保持したまま、明示した希望を試す候補に結びつける', () {
    const focus = FollowUpFocus.rememberInTime;
    const original = '期限は印字されている。写真をまとめて見たいわけではなく、撮るついでに自分で期限を入れ、期限前に知らせてほしい。';
    PlanMemo parse(String text) => _groundedMemo(
      [
        QaEntry(
          questionId: focus.questionId,
          question: focus.question,
          answer: text,
          axis: focus.axis,
        ),
      ],
      selection: {..._emptySelection, 'how': 'a1'},
    );
    final memo = parse(original);
    expect(memo.how, '');
    expect(memo.nextStep, '試す候補：${focus.trial}\n回答原文「$original」');
    expect(parse('期限前に知らせてほしいわけではない。').nextStep, '');
    expect(parse('通知を試してみたい。とはいえ、今は試すことができない。').nextStep, '');
  });

  test('後から自分で決めた行動を2問目の試す候補より優先する', () {
    final focus = FollowUpFocus.tellApart;
    final history = [
      QaEntry(
        questionId: focus.questionId,
        question: focus.question,
        answer: focus.choices.first,
        axis: focus.axis,
      ),
      const QaEntry(
        questionId: 'q3',
        question: '最初の一歩は？',
        answer: 'まず手元のPDFを一枚開いて内容を確認する。',
      ),
      const QaEntry(
        questionId: 'q4',
        question: 'ほかに決めたことは？',
        answer: '次に手元のPDFを二枚並べて見比べる。',
      ),
    ];
    expect(
      _groundedMemo([history.first], selection: _emptySelection).nextStep,
      startsWith('試す候補：'),
    );
    expect(
      _groundedMemo(history, selection: _emptySelection).nextStep,
      history.last.answer,
    );
    expect(
      LocalMemoBuilder.build(
        title: '似たPDFを見分ける',
        answers: history,
        version: 1,
        reviewDraft: true,
      ).nextStep,
      history.last.answer,
    );
  });

  test('例や曖昧な自由入力を、本人が決めた手段として採用しない', () {
    const history = [
      QaEntry(questionId: 'q1', question: 'どう進める？', answer: '手段は、たとえば色で分ける。'),
      QaEntry(
        questionId: 'how',
        question: 'どうやって助ける？',
        answer: '何かいい感じで。',
        source: AnswerSource.local,
        choices: ['知らせて支える'],
      ),
    ];
    PlanMemo parse(String id) => _groundedMemo(
      history,
      selection: {..._emptySelection, 'how': id},
    );
    expect(parse('a1').how, '');
    expect(parse('a2').how, '');
  });

  test('元の制約と一致しない回答は確定欄へ入れない', () {
    const note = 'レシート画像は端末外へ送らない。';
    const answer = QaEntry(
      questionId: 'how',
      question: 'どうやって助ける？',
      answer: '手段はクラウドに保存する。',
      source: AnswerSource.local,
      choices: ['手段はクラウドに保存する。'],
    );
    PlanMemo parse(String original) => _groundedMemo(
      const [answer],
      selection: {..._emptySelection, 'how': 'a1'},
      note: original,
    );
    expect(parse(note).how, '');
    expect(parse(answer.answer).how, answer.answer);
    expect(
      LocalMemoBuilder.build(
        title: '返品期限',
        note: note,
        answers: const [answer],
        version: 1,
        reviewDraft: true,
      ).how,
      '',
    );
  });
}
