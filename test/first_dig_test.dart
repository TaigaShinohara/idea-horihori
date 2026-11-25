import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/fallback.dart';
import 'package:horihori/first_dig.dart';
import 'package:horihori/models.dart';
import 'package:horihori/prompts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _answer = QaEntry(
  questionId: 'guided_1_scene',
  question: 'どんな場面で使う？',
  answer: '通販で期限を知らず、注文メールを探した。',
  axis: 'scene',
);

const _firstQuestion = {'choice': 'scene'};

Idea _idea() => Idea(
  id: 'test',
  title: '返品期限メモ',
  note: 'レシート画像は端末外へ送らない。',
  createdAt: DateTime(2026),
);

void main() {
  test('1問目はアプリの候補から選び、別の質問では同じ観点を再利用しない', () {
    DigQuestion? parse(
      Map<String, Object> response, [
      FirstDigContext context = const FirstDigContext(),
    ]) => Prompts.parseFirstDigQuestion(
      jsonEncode(response),
      context: context,
      anchorSource: '',
    );
    final first = parse({
      'choice': 'scene',
      'choices': ['使ってみますか？'],
    })!;
    expect(first.id, 'guided_1_scene');
    expect(first.choices, OpeningFocus.scene.choices);
    expect(parse({'choice': 'unknown'}), isNull);
    final context = FirstDigContext(excludedQuestion: first);
    expect(parse(_firstQuestion, context), isNull);
    expect(parse({'choice': 'obstacle'}, context)?.axis, 'obstacle');
  });

  test('2問目は分類だけを使い、本人の文を途中で切らず質問を組み立てる', () {
    const context = FirstDigContext(firstAnswer: _answer);
    final input = Prompts.firstDigQuestion(
      title: _idea().title,
      note: _idea().note,
      context: context,
      budget: Prompts.compactNanoBudget,
    );
    DigQuestion? parse(Map<String, Object> response) =>
        Prompts.parseFirstDigQuestion(
          jsonEncode(response),
          context: context,
          anchorSource: input.anchorSource,
        );
    expect(input.prompt, contains(_answer.answer));
    expect(input.prompt, contains(_idea().note));
    final question = parse({
      'choice': 'findInformation:1',
      'text': 'クラウドへ画像を保存する？',
      'choices': ['アップロードする'],
    });
    expect(question?.id, FollowUpFocus.findInformation.questionId);
    expect(question?.text, contains(_answer.answer));
    expect(question?.text, isNot(contains('クラウド')));
    expect(question?.choices, FollowUpFocus.findInformation.choices);
    expect(question?.axis, isNot(_answer.axis));
    expect(parse({'choice': 'rememberInTime:1'}), isNull);
    expect(parse({'choice': 'reviewOrder:1'}), isNull);
    expect(parse({'choice': 'noticeChange:1'}), isNull);
    expect(parse({'choice': 'findInformation:9'}), isNull);
    expect(parse(_firstQuestion), isNull);
  });

  test('覚えていたか不明な文や、否定された失念は思い出す観点に分類できない', () {
    for (final answer in ['予約の手順が分からない。', '忘れたわけではない。']) {
      final context = FirstDigContext(
        firstAnswer: QaEntry(
          questionId: 'q1',
          question: 'いつ困った？',
          answer: answer,
        ),
      );
      expect(
        context.followUpChoices(answer),
        isNot(contains('rememberInTime:1')),
      );
    }
    const known = '予約の場所は知っていたけれど、当日に忘れた。';
    final context = FirstDigContext(
      firstAnswer: const QaEntry(
        questionId: 'q1',
        question: 'いつ困った？',
        answer: known,
      ),
    );
    expect(
      context.followUpQuestion('rememberInTime:1', known)?.text,
      contains(known),
    );
    expect(
      context.followUpQuestion('rememberInTime:1', known)?.choices,
      contains('必要になる少し前'),
    );
  });

  test('未決の回答の後は元メモ、次にタイトルから引用する', () {
    const context = FirstDigContext(
      firstAnswer: QaEntry(
        questionId: 'guided_1_scene',
        question: 'どんな場面で使う？',
        answer: 'はい。',
        axis: 'scene',
      ),
    );
    final withNote = Prompts.firstDigQuestion(
      title: _idea().title,
      note: _idea().note,
      context: context,
    );
    final withoutNote = Prompts.firstDigQuestion(
      title: _idea().title,
      note: '',
      context: context,
    );
    expect(withNote.anchorSource, _idea().note);
    expect(withoutNote.anchorSource, _idea().title);
  });

  test('否定した観点を出さず、同じ軸を別の軸として扱わない', () {
    const answer = '制作順には並べない。予定は忘れていない。';
    const context = FirstDigContext(
      firstAnswer: QaEntry(
        questionId: 'q1',
        question: '今のやり方で、どの段階が難しい？',
        answer: answer,
        axis: 'obstacle',
      ),
    );
    final candidates = context.followUpChoices(answer);
    expect(candidates.keys, ['observeOnce:1', 'observeOnce:2']);
    final fallback = context.followUpQuestion('observeOnce:1', answer)!;
    expect(fallback.axis, 'test');
    expect(fallback.text, contains('今のやり方を一度試すなら'));
    expect(fallback.choices, contains('今の手順にかかる時間'));
  });

  test('定型の代案は前の質問と表示中の質問の軸を避ける', () async {
    final backend = ResilientBackend(null);
    final first = await backend.nextQuestion(
      idea: _idea(),
      history: const [],
      firstDig: const FirstDigContext(),
    );
    expect(first.axis, 'scene');
    expect(first.source, AnswerSource.local);
    final second = await backend.nextQuestion(
      idea: _idea(),
      history: const [_answer],
      firstDig: const FirstDigContext(firstAnswer: _answer),
    );
    expect(second.axis, 'test');
    final alternative = await backend.nextQuestion(
      idea: _idea(),
      history: const [_answer],
      firstDig: FirstDigContext(firstAnswer: _answer, excludedQuestion: second),
    );
    expect(alternative.axis, 'obstacle');
    expect(alternative.text, isNot(second.text));
    final obstacle = await backend.nextQuestion(
      idea: _idea(),
      history: const [],
      firstDig: const FirstDigContext(
        firstAnswer: QaEntry(
          questionId: 'guided_1_test',
          question: 'どんな方法を試す？',
          answer: '紙で記録する',
          axis: 'test',
        ),
      ),
    );
    expect(obstacle.axis, 'obstacle');
  });

  test('視点の定型で答えた質問は3問目以降でも既出扱いになる', () async {
    final backend = ResilientBackend(null);
    final first = await backend.nextQuestion(
      idea: _idea(),
      history: const [],
      firstDig: const FirstDigContext(),
      viewpoint: DigViewpoint.money,
    );
    expect(first.id, 'money_1');
    expect(first.axis, 'audience');
    final history = [
      QaEntry(
        questionId: first.id,
        question: first.text,
        answer: '使う本人',
        axis: first.axis,
        source: first.source,
      ),
    ];
    final next = await backend.nextQuestion(
      idea: _idea(),
      history: history,
      viewpoint: DigViewpoint.money,
    );
    expect(next.id, 'money_2');
    expect(next.text, isNot(first.text));
  });

  test('未確定の下書きは空欄を許容して点数を採用しない', () {
    const draft = {
      'what': '',
      'who': '',
      'why': '',
      'how': '',
      'nextStep': 'a1',
      'openQuestions': 'a2',
      'ease': 3,
      'spark': 3,
    };
    final memo = Prompts.parseMemo(
      jsonEncode(draft),
      version: 1,
      reviewDraft: true,
      history: const [
        QaEntry(
          questionId: 'next',
          question: '最初の一歩はどれ？',
          answer: 'まず注文メールに期限が書いてあるか確かめる。',
          source: AnswerSource.local,
        ),
        QaEntry(questionId: 'q2', question: '何が未定？', answer: '期限が案内される場所は未確認。'),
      ],
    );
    expect(memo?.nextStep, 'まず注文メールに期限が書いてあるか確かめる。');
    expect(memo?.openQuestions, '期限が案内される場所は未確認。');
    expect(memo?.what, '');
    expect(memo?.hasFitness, false);
    expect(Prompts.parseMemo(jsonEncode(draft), version: 1), isNull);
    final fallback = LocalMemoBuilder.build(
      title: _idea().title,
      answers: const [_answer],
      version: 1,
      reviewDraft: true,
    );
    expect(fallback.openQuestions, '');
    expect(fallback.nextStep, '');
    expect(fallback.hasFitness, false);
  });

  test('Geminiの2問目は型付きの選択を使い、アプリが質問を組み立てる', () async {
    var calls = 0;
    final backend = GeminiBackend(
      apiKey: 'test-only',
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body);
        expect(body['generationConfig']['responseJsonSchema']['required'], [
          'choice',
        ]);
        expect(
          body['generationConfig']['responseJsonSchema']['properties']['choice']['enum'],
          contains('findInformation:1'),
        );
        expect(request.body, contains(_answer.answer));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode({'choice': 'findInformation:1'}),
                      },
                    ],
                  },
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
    final question = await backend.nextQuestion(
      idea: _idea(),
      history: const [_answer],
      firstDig: const FirstDigContext(firstAnswer: _answer),
    );
    expect(calls, 1);
    expect(question.axis, 'test');
    expect(question.text, contains(_answer.answer));
  });
}
