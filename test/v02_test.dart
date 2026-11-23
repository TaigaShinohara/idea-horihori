import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/app_config.dart';
import 'package:horihori/dev_brief.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/fallback.dart';
import 'package:horihori/models.dart';
import 'package:horihori/name_candidates.dart';
import 'package:horihori/prompts.dart';
import 'package:horihori/session_logic.dart';
import 'package:horihori/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Idea _idea({List<DigSession>? sessions, List<PlanMemo>? memos}) => Idea(
      id: '1',
      title: '天気で服を決めるアプリ',
      createdAt: DateTime(2026, 11, 21),
      sessions: sessions,
      memos: memos,
    );

PlanMemo _memo({int? ease, int? spark}) => PlanMemo(
      what: '天気で服を提案する',
      who: '朝忙しい人',
      why: '服選びに迷う',
      how: '通知で知らせる',
      nextStep: '自分で試す',
      createdAt: DateTime(2026, 11, 21),
      version: 1,
      ease: ease,
      spark: spark,
    );

DigSession _session(List<QaEntry> answers) => DigSession(
      id: 's1',
      startedAt: DateTime(2026, 11, 21),
      answers: answers,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('旧データ互換（v0.2 共通ルール）', () {
    test('旧形式JSON（新キーなし）がそのまま読める', () {
      final oldJson = <String, dynamic>{
        'id': 'old1',
        'title': '旧アイデア',
        'note': '',
        'createdAt': '2026-11-20T00:00:00.000',
        'sessions': [
          {
            'id': 's1',
            'startedAt': '2026-11-20T00:00:00.000',
            'answers': [
              {'questionId': 'who', 'question': '誰の？', 'answer': '個人'},
            ],
            'pendingQuestion': null,
            'finished': false,
          },
        ],
        'memos': [
          {
            'what': 'w',
            'who': 'u',
            'why': 'y',
            'how': 'h',
            'nextStep': 'n',
            'createdAt': '2026-11-20T00:00:00.000',
            'version': 1,
          },
        ],
        'archived': false,
      };
      final idea = Idea.fromJson(oldJson);
      final session = idea.sessions.single;
      // 新項目はすべて既定値に倒れる
      expect(session.viewpoint, DigViewpoint.none);
      expect(session.contrarianAsked, isFalse);
      expect(session.answers.single.choices, isNull);
      expect(session.answers.single.contrarian, isFalse);
      expect(idea.memos.single.ease, isNull);
      expect(idea.memos.single.spark, isNull);
      expect(idea.memos.single.hasFitness, isFalse);
    });

    test('新形式は往復で保持される', () {
      final session = _session([
        const QaEntry(
          questionId: 'contrarian',
          question: '失敗するとしたら？',
          answer: '需要がない',
          choices: ['需要がない', '作りきれない', '続けられない'],
          contrarian: true,
        ),
      ])
        ..viewpoint = DigViewpoint.money
        ..contrarianAsked = true;
      final idea = _idea(sessions: [session], memos: [_memo(ease: 2, spark: 3)]);
      final restored = Idea.fromJson(idea.toJson());
      final s = restored.sessions.single;
      expect(s.viewpoint, DigViewpoint.money);
      expect(s.contrarianAsked, isTrue);
      expect(s.answers.single.choices, hasLength(3));
      expect(s.answers.single.contrarian, isTrue);
      expect(restored.memos.single.ease, 2);
      expect(restored.memos.single.spark, 3);
    });
  });

  group('項目1 掘り方モード', () {
    test('スタイルで質問プロンプトのペルソナが変わる', () {
      final friend = Prompts.nextQuestion(
        title: 't',
        history: const [],
        style: DigStyle.friend,
      );
      final boss = Prompts.nextQuestion(
        title: 't',
        history: const [],
        style: DigStyle.boss,
      );
      expect(friend, contains('友達として並走する'));
      expect(boss, contains('上司として的確に指摘する'));
      expect(friend, isNot(boss));
    });

    test('スタイルで要約プロンプトも変わる', () {
      final boss = Prompts.summarize(
        title: 't',
        history: const [],
        style: DigStyle.boss,
      );
      expect(boss, contains('上司として的確に指摘する'));
    });

    test('定型質問は boss のときだけ前置きが付く', () {
      final q = FallbackQuestions.questions.first;
      expect(FallbackQuestions.styled(q, DigStyle.friend).text, q.text);
      final bossed = FallbackQuestions.styled(q, DigStyle.boss);
      expect(bossed.text, isNot(q.text));
      expect(bossed.text, contains(q.text));
      expect(bossed.id, q.id);
      expect(bossed.choices, q.choices);
    });

    test('DigStyle の保存文字列は往復する（未知は friend）', () {
      expect(DigStyleX.fromStorage('boss'), DigStyle.boss);
      expect(DigStyleX.fromStorage('friend'), DigStyle.friend);
      expect(DigStyleX.fromStorage(null), DigStyle.friend);
      expect(DigStyleX.fromStorage('???'), DigStyle.friend);
    });

    test('スタイルは保存され再読込でも保持される', () async {
      SharedPreferences.setMockInitialValues({});
      final store = IdeaStore();
      await store.load();
      expect(store.digStyle, DigStyle.friend); // 既定は友達
      await store.saveDigStyle(DigStyle.boss);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.prefsDigStyleKey), 'boss');
      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.digStyle, DigStyle.boss);
    });
  });

  group('項目2 視点掘り', () {
    test('視点がプロンプトに反映される', () {
      final money = Prompts.nextQuestion(
        title: 't',
        history: const [],
        viewpoint: DigViewpoint.money,
      );
      expect(money, contains('お金の視点'));
      final tech = Prompts.nextQuestion(
        title: 't',
        history: const [],
        viewpoint: DigViewpoint.tech,
      );
      expect(tech, contains('技術の視点'));
      final user = Prompts.nextQuestion(
        title: 't',
        history: const [],
        viewpoint: DigViewpoint.user,
      );
      expect(user, contains('使う人の視点'));
      final none = Prompts.nextQuestion(title: 't', history: const []);
      expect(none, isNot(contains('お金の視点')));
    });

    test('DigViewpoint の保存文字列は往復する（未知は none）', () {
      for (final v in DigViewpoint.values) {
        expect(DigViewpointX.fromStorage(v.storageValue), v);
      }
      expect(DigViewpointX.fromStorage(null), DigViewpoint.none);
      expect(DigViewpointX.fromStorage('???'), DigViewpoint.none);
    });
  });

  group('項目3 逆張り質問', () {
    test('due 判定は「回答3件・未出」のときだけ', () {
      QaEntry a(int i) =>
          QaEntry(questionId: 'q$i', question: 'Q$i', answer: 'A$i');
      expect(contrarianDue(_session([a(1), a(2)])), isFalse);
      expect(contrarianDue(_session([a(1), a(2), a(3)])), isTrue);
      final asked = _session([a(1), a(2), a(3)])..contrarianAsked = true;
      expect(contrarianDue(asked), isFalse);
    });

    test('AIプロンプトに逆張り指示が入る', () {
      final p = Prompts.nextQuestion(
        title: 't',
        history: const [],
        contrarian: true,
      );
      expect(p, contains('逆張り'));
      expect(p, contains('失敗するとしたら'));
    });

    test('定型経路では due のとき固定文が出て、回答後は二度出ない', () async {
      final backend = LocalBackend();
      final history = [
        const QaEntry(questionId: 'who', question: '', answer: 'x'),
        const QaEntry(questionId: 'why', question: '', answer: 'x'),
        const QaEntry(questionId: 'what', question: '', answer: 'x'),
      ];
      final q = await backend.nextQuestion(
        idea: _idea(),
        history: history,
        contrarianDue: true,
      );
      expect(q.id, 'contrarian');
      expect(q.isContrarian, isTrue);
      expect(q.text, contains('失敗するとしたら'));
      expect(q.choices, ['需要がない', '作りきれない', '続けられない']);

      // 逆張りに答えた後の履歴では、due 指定でも定型に戻る
      final after = [
        ...history,
        QaEntry(
          questionId: q.id,
          question: q.text,
          answer: '需要がない',
          choices: q.choices,
          contrarian: true,
        ),
      ];
      final q2 = await backend.nextQuestion(
        idea: _idea(),
        history: after,
        contrarianDue: true,
      );
      expect(q2.id, isNot('contrarian'));
      expect(q2.isContrarian, isFalse);
    });
  });

  group('項目4 体力測定', () {
    test('AI応答の ease/spark を取り込む（範囲外・欠落は null）', () {
      final m = Prompts.parseMemo(
        '{"what":"W","who":"U","why":"Y","how":"H","nextStep":"N","ease":2,"spark":3}',
        version: 1,
      );
      expect(m!.ease, 2);
      expect(m.spark, 3);
      final bad = Prompts.parseMemo(
        '{"what":"W","who":"U","why":"Y","how":"H","nextStep":"N","ease":9}',
        version: 1,
      );
      expect(bad!.ease, isNull);
      expect(bad.spark, isNull);
    });

    test('ローカル整形でも値が入る（全欄埋まれば ease3/spark3）', () {
      final answers = FallbackQuestions.questions
          .map((q) => QaEntry(
              questionId: q.id, question: q.text, answer: q.choices.first))
          .toList();
      final memo =
          LocalMemoBuilder.build(title: 'x', answers: answers, version: 1);
      expect(memo.ease, 3);
      expect(memo.spark, 3);
      final empty =
          LocalMemoBuilder.build(title: 'x', answers: const [], version: 1);
      expect(empty.ease, 1);
      expect(empty.spark, 1);
    });

    test('ドット表示は3段階', () {
      expect(fitnessDots(1), '●○○');
      expect(fitnessDots(2), '●●○');
      expect(fitnessDots(3), '●●●');
    });
  });

  group('項目5 開発指示書', () {
    test('見出し・5項目・Q&A・締め文が含まれる', () {
      final session = _session([
        const QaEntry(questionId: 'who', question: '誰の？', answer: '朝忙しい人'),
      ]);
      final idea = _idea(sessions: [session], memos: [_memo(ease: 2, spark: 3)]);
      final brief = buildDevBrief(idea);
      expect(brief, contains('アプリ開発の指示書: 天気で服を決めるアプリ'));
      expect(brief, contains('天気で服を提案する'));
      expect(brief, contains('朝忙しい人'));
      expect(brief, contains('服選びに迷う'));
      expect(brief, contains('通知で知らせる'));
      expect(brief, contains('自分で試す'));
      expect(brief, contains('作りやすさ ●●○'));
      expect(brief, contains('ワクワク度 ●●●'));
      expect(brief, contains('Q: 誰の？ → A: 朝忙しい人'));
      expect(brief, contains('この企画でアプリを作ってください'));
    });

    test('体力測定が無いメモでは行自体が出ない', () {
      final idea = _idea(memos: [_memo()]);
      expect(buildDevBrief(idea), isNot(contains('体力測定')));
    });
  });

  group('項目6 名前決めアシスト', () {
    test('ローカル候補は必ず3件・重複なし', () {
      final names = LocalNameCandidates.generate(
        title: '天気で服を決めるアプリ',
        memo: _memo(),
      );
      expect(names, hasLength(3));
      expect(names.toSet(), hasLength(3));
      final backend = LocalBackend();
      expectLater(
        backend.nameCandidates(idea: _idea(memos: [_memo()])),
        completion(hasLength(3)),
      );
    });

    test('AI応答の候補JSONを解釈できる', () {
      expect(
        Prompts.parseNameCandidates('{"candidates":["a","b","c","d"]}'),
        ['a', 'b', 'c'],
      );
      expect(Prompts.parseNameCandidates('だめ'), isEmpty);
      final p = Prompts.nameCandidates(title: 't', memo: _memo());
      expect(p, contains('ちょうど3つ'));
    });
  });

  group('項目7 回答履歴＋1問もどる', () {
    test('取り消すと質問が復元され、再回答できる状態になる', () {
      final session = _session([
        const QaEntry(
          questionId: 'who',
          question: '誰の？',
          answer: '個人',
          choices: ['個人', '仕事の人', 'みんな'],
        ),
      ]);
      expect(canUndoLastAnswer(session), isTrue);
      final removed = undoLastAnswer(session);
      expect(removed?.answer, '個人');
      expect(session.answers, isEmpty);
      expect(session.pendingQuestion?.text, '誰の？');
      expect(session.pendingQuestion?.choices, ['個人', '仕事の人', 'みんな']);
      // 往復保存しても一致する
      final restored = DigSession.fromJson(session.toJson());
      expect(restored.pendingQuestion?.id, 'who');
      expect(restored.answers, isEmpty);
    });

    test('逆張りの取り消しでは contrarianAsked が戻る', () {
      final session = _session([
        const QaEntry(
          questionId: 'contrarian',
          question: '失敗するとしたら？',
          answer: '需要がない',
          choices: ['需要がない', '作りきれない', '続けられない'],
          contrarian: true,
        ),
      ])..contrarianAsked = true;
      undoLastAnswer(session);
      expect(session.contrarianAsked, isFalse);
      expect(session.pendingQuestion?.isContrarian, isTrue);
    });

    test('旧データ（choices無し）や回答0件では取り消せない', () {
      final old = _session([
        const QaEntry(questionId: 'who', question: '誰の？', answer: '個人'),
      ]);
      expect(canUndoLastAnswer(old), isFalse);
      expect(undoLastAnswer(old), isNull);
      expect(old.answers, hasLength(1)); // 壊さない
      expect(canUndoLastAnswer(_session([])), isFalse);
    });
  });
}
