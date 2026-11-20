import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/fallback.dart';
import 'package:horihori/models.dart';
import 'package:horihori/prompts.dart';

Idea _idea({List<DigSession>? sessions, List<PlanMemo>? memos}) => Idea(
      id: '1',
      title: '天気で服を決めるアプリ',
      createdAt: DateTime(2026, 11, 20),
      sessions: sessions,
      memos: memos,
    );

DigSession _sessionWith(int n) => DigSession(
      id: 's$n',
      startedAt: DateTime(2026, 11, 20),
      answers: List.generate(
        n,
        (i) => QaEntry(questionId: 'q$i', question: 'Q$i', answer: 'A$i'),
      ),
    );

PlanMemo _memo(int v) => PlanMemo(
      what: 'w',
      who: 'u',
      why: 'y',
      how: 'h',
      nextStep: 'n',
      createdAt: DateTime(2026, 11, 20),
      version: v,
    );

void main() {
  group('成長段階判定', () {
    test('登録直後は種', () {
      expect(_idea().stage, GrowthStage.seed);
      expect(_idea().growthValue, closeTo(0.12, 0.001));
    });
    test('回答があれば芽', () {
      final idea = _idea(sessions: [_sessionWith(1)]);
      expect(idea.stage, GrowthStage.sprout);
      expect(idea.growthValue, greaterThan(0.12));
      expect(idea.growthValue, lessThan(0.7));
    });
    test('メモがあれば実（メモ優先）', () {
      final idea = _idea(sessions: [_sessionWith(3)], memos: [_memo(1)]);
      expect(idea.stage, GrowthStage.fruit);
      expect(idea.growthValue, closeTo(0.8, 0.01));
    });
    test('メモが積まれるほど成長値が満ちる', () {
      final one = _idea(memos: [_memo(1)]).growthValue;
      final three = _idea(memos: [_memo(1), _memo(2), _memo(3)]).growthValue;
      expect(three, greaterThan(one));
      expect(three, closeTo(1.0, 0.001));
    });
  });

  group('フォールバック質問', () {
    test('5問の定型セットがあり順に出る', () {
      expect(FallbackQuestions.questions.length, 5);
      expect(FallbackQuestions.nextAfter(0)?.id, 'who');
      expect(FallbackQuestions.nextAfter(4)?.id, 'next');
      expect(FallbackQuestions.nextAfter(5), isNull);
    });
    test('全質問に選択肢が3つある', () {
      for (final q in FallbackQuestions.questions) {
        expect(q.choices.length, 3, reason: q.id);
      }
    });
    test('LocalBackendは既出質問を飛ばす', () async {
      final backend = LocalBackend();
      final history = [
        const QaEntry(questionId: 'who', question: '', answer: '自分みたいな個人'),
      ];
      final q = await backend.nextQuestion(idea: _idea(), history: history);
      expect(q.id, 'why');
    });
    test('LocalBackendは定型を使い切ると広げ質問を出す', () async {
      final backend = LocalBackend();
      final history = FallbackQuestions.questions
          .map((q) => QaEntry(questionId: q.id, question: q.text, answer: 'x'))
          .toList();
      final q = await backend.nextQuestion(idea: _idea(), history: history);
      expect(q.id, startsWith('extra'));
      expect(q.choices.length, 3);
    });
  });

  group('ローカルメモ整形', () {
    test('回答が型の各欄に埋まる', () {
      final answers = FallbackQuestions.questions
          .map((q) => QaEntry(
              questionId: q.id, question: q.text, answer: q.choices.first))
          .toList();
      final memo = LocalMemoBuilder.build(
          title: '天気アプリ', answers: answers, version: 1);
      expect(memo.who, '自分みたいな個人');
      expect(memo.why, '面倒で手間がかかる');
      expect(memo.what, contains('天気アプリ'));
      expect(memo.what, contains('サッと記録する'));
      expect(memo.how, '自動でやってくれる');
      expect(memo.nextStep, 'まず自分が毎日使う');
      expect(memo.version, 1);
    });
    test('回答が無い欄は未掘りとして埋まる', () {
      final memo =
          LocalMemoBuilder.build(title: 'x', answers: const [], version: 2);
      expect(memo.who, contains('まだ掘れていない'));
      expect(memo.nextStep, '続きを深掘りする');
      expect(memo.version, 2);
    });
  });

  group('プロンプト生成と応答解釈', () {
    test('質問プロンプトにタイトルと履歴が入る', () {
      final p = Prompts.nextQuestion(
        title: '天気アプリ',
        history: const [QaEntry(questionId: 'who', question: '誰の？', answer: '個人')],
      );
      expect(p, contains('天気アプリ'));
      expect(p, contains('誰の？'));
      expect(p, contains('個人'));
    });
    test('要約プロンプトに型のキーが入る', () {
      final p = Prompts.summarize(title: 't', history: const []);
      for (final k in ['what', 'who', 'why', 'how', 'nextStep']) {
        expect(p, contains(k));
      }
    });
    test('質問JSONを解釈できる（フェンス付きでも）', () {
      final q = Prompts.parseQuestion(
          '```json\n{"id":"q1","text":"誰のため？","choices":["a","b","c"]}\n```');
      expect(q, isNotNull);
      expect(q!.text, '誰のため？');
      expect(q.choices, ['a', 'b', 'c']);
    });
    test('壊れた応答は null', () {
      expect(Prompts.parseQuestion('こんにちは'), isNull);
      expect(Prompts.parseMemo('{}', version: 1), isNull);
    });
    test('メモJSONを解釈できる', () {
      final m = Prompts.parseMemo(
        '{"what":"W","who":"U","why":"Y","how":"H","nextStep":"N"}',
        version: 3,
      );
      expect(m, isNotNull);
      expect(m!.what, 'W');
      expect(m.version, 3);
    });
  });

  group('ローカルメモ整形 v0.1.1', () {
    test('同じIDは最後の回答が使われる（再深掘り反映）', () {
      final memo = LocalMemoBuilder.build(
        title: 'x',
        answers: const [
          QaEntry(questionId: 'who', question: '誰の？', answer: '古い相手'),
          QaEntry(questionId: 'who', question: '誰の？', answer: '新しい相手'),
        ],
        version: 2,
      );
      expect(memo.who, '新しい相手');
    });

    test('テンプレ外IDは質問文キーワードで振り分けられる', () {
      final memo = LocalMemoBuilder.build(
        title: '天気アプリ',
        answers: const [
          QaEntry(questionId: 'q1', question: '誰のためのもの？', answer: '忙しい親'),
          QaEntry(questionId: 'q2', question: '困っていることは？', answer: '朝の服選び'),
          QaEntry(questionId: 'q3', question: 'どうやって助ける？', answer: '通知で知らせる'),
          QaEntry(questionId: 'q4', question: '最初の一歩は？', answer: '自分で試す'),
          QaEntry(questionId: 'q5', question: 'どんな形がいい？', answer: 'サッと見る道具'),
        ],
        version: 1,
      );
      expect(memo.who, '忙しい親');
      expect(memo.why, '朝の服選び');
      expect(memo.how, '通知で知らせる');
      expect(memo.nextStep, '自分で試す');
      expect(memo.what, contains('サッと見る道具'));
    });

    test('キーワードで振り分けられない回答は空き欄へ順に割り当てる', () {
      final memo = LocalMemoBuilder.build(
        title: 'x',
        answers: const [
          QaEntry(questionId: 'q1', question: '自由に教えて', answer: 'Aさん'),
          QaEntry(questionId: 'q2', question: '自由に教えて', answer: 'Bの悩み'),
        ],
        version: 1,
      );
      expect(memo.who, 'Aさん');
      expect(memo.why, 'Bの悩み');
    });

    test('全欄が埋まった後の余りだけ What の補足になる', () {
      final answers = <QaEntry>[
        ...FallbackQuestions.questions.map((q) =>
            QaEntry(questionId: q.id, question: q.text, answer: q.choices.first)),
        const QaEntry(questionId: 'q9', question: '自由に教えて', answer: '追加メモ'),
      ];
      final memo =
          LocalMemoBuilder.build(title: 'x', answers: answers, version: 1);
      expect(memo.what, contains('追加メモ'));
      expect(memo.who, '自分みたいな個人');
    });
  });

  group('ローカル深掘り2周目', () {
    test('履歴を現セッションだけに絞れば定型5問が最初から出る', () async {
      final backend = LocalBackend();
      // 1周目の全履歴では extra しか出ない（従来の不具合の再現確認）
      final fullHistory = FallbackQuestions.questions
          .map((q) => QaEntry(questionId: q.id, question: q.text, answer: 'x'))
          .toList();
      final withFull =
          await backend.nextQuestion(idea: _idea(), history: fullHistory);
      expect(withFull.id, startsWith('extra'));

      // DigScreen がローカル時に渡す「現セッションのみ」の履歴では who から
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.id, 'who');
      final q2 = await backend.nextQuestion(
        idea: _idea(),
        history: const [
          QaEntry(questionId: 'who', question: '誰の？', answer: '個人'),
        ],
      );
      expect(q2.id, 'why');
    });
  });

  group('シリアライズ往復', () {
    test('Idea の toJson/fromJson でセッションとメモが保たれる', () {
      final idea = _idea(sessions: [_sessionWith(2)], memos: [_memo(1)]);
      idea.sessions.first.pendingQuestion = FallbackQuestions.questions[2];
      final restored = Idea.fromJson(idea.toJson());
      expect(restored.title, idea.title);
      expect(restored.totalAnswers, 2);
      expect(restored.memos.length, 1);
      expect(restored.stage, GrowthStage.fruit);
      expect(restored.resumableSession?.pendingQuestion?.id, 'what');
    });
    test('未完了セッションだけ再開対象になる', () {
      final done = _sessionWith(5)..finished = true;
      final open = _sessionWith(1);
      final idea = _idea(sessions: [done, open]);
      expect(idea.resumableSession?.id, open.id);
      final allDone = _idea(sessions: [done]);
      expect(allDone.resumableSession, isNull);
    });
  });
}
