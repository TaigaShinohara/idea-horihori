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

const _question = {
  'text': '返品期限を最初にどこで確認したい？',
  'choices': ['注文メール', '購入履歴', '店舗への問い合わせ'],
  'axis': 'approach',
  'anchor': '注文メールを探した',
};

Idea _idea() => Idea(
  id: 'test',
  title: '返品期限メモ',
  note: 'レシート画像は端末外へ送らない。',
  createdAt: DateTime(2026),
);

void main() {
  test('質問の軸と、同じプロンプトで見える回答の引用を検証する', () {
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
    expect(parse(_question)?.id, 'guided_2_approach');
    expect(parse({..._question, 'axis': 'scene'}), isNull);
    expect(parse({..._question, 'anchor': '店頭で購入した'}), isNull);
    expect(parse({..._question, 'text': ' どんな場面で使う!? '}), isNull);
    expect(
      parse({
        ..._question,
        'choices': ['メール', ' メール。', '店舗'],
      }),
      isNull,
    );
    expect(
      parse({
        ..._question,
        'choices': ['メール', '店舗'],
      }),
      isNull,
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
      'nextStep': '注文メールに期限が書いてあるか確かめる',
      'openQuestions': '期限が案内される場所',
      'ease': 3,
      'spark': 3,
    };
    final memo = Prompts.parseMemo(
      jsonEncode(draft),
      version: 1,
      reviewDraft: true,
    );
    expect(memo?.openQuestions, '期限が案内される場所');
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

  test('Geminiの初回質問は型付き出力を使い、応答の引用を検証する', () async {
    var calls = 0;
    final backend = GeminiBackend(
      apiKey: 'test-only',
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body);
        expect(
          body['generationConfig']['responseJsonSchema']['required'],
          containsAll(['text', 'choices', 'axis', 'anchor']),
        );
        expect(
          body['generationConfig']['responseJsonSchema']['properties']['anchor']['enum'],
          contains('注文メールを探した'),
        );
        expect(request.body, contains(_answer.answer));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': jsonEncode(_question)},
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
    expect(question.axis, 'approach');
  });
}
