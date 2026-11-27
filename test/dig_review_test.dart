import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/app_config.dart';
import 'package:horihori/dev_brief.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/models.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test storage failure at the plugin boundary without altering the schema.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'store_test.dart' show FakeSecretStore;

class _OfflineStore extends IdeaStore {
  _OfflineStore() : super(secrets: FakeSecretStore());

  final ai = _CountingLocalBackend();

  @override
  ResilientBackend backend() => ai;
}

class _CountingLocalBackend extends ResilientBackend {
  _CountingLocalBackend() : super(null);

  var summaries = 0;

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool templateOnly = false,
    bool reviewDraft = false,
  }) {
    summaries++;
    return super.summarize(
      idea: idea,
      history: history,
      version: version,
      style: style,
      templateOnly: templateOnly,
      reviewDraft: reviewDraft,
    );
  }
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();

  bool rejectWrite = false;
  Completer<bool>? nextWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${AppConfig.prefsIdeasKey}') {
      final held = nextWrite;
      nextWrite = null;
      if (held != null) return held.future;
      if (rejectWrite) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> tapText(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('1問で確認に進み、編集と元メモを保存して再開できる', (tester) async {
    final preferences = _FailingPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    final store = _OfflineStore();
    await store.load();
    final idea = await store.addIdea('返品期限', '端末外に画像を送らない。');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DigScreen(store: store, idea: idea, fromDetail: true),
                ),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tapText(tester, '開く');
    await tester.enterText(find.byType(TextField), '店頭で期限を知っていたが忘れた。');
    await tapText(tester, '答える');
    expect(find.text('もう1問'), findsOneWidget);
    expect(idea.resumableSession!.pendingQuestion, isNull);
    await tapText(tester, 'ここまでをまとめる');
    expect(find.text('企画メモを確認'), findsOneWidget);
    expect(find.text('定型'), findsOneWidget);
    expect(idea.memos, isEmpty);
    await tapText(tester, '元メモと回答');
    expect(find.text('端末外に画像を送らない。'), findsOneWidget);
    final nextStep = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == '次に試すこと',
    );
    await tester.ensureVisible(nextStep);
    await tester.enterText(nextStep, '手入力と通知を1件試す');
    final write = Completer<bool>();
    preferences.nextWrite = write;
    preferences.rejectWrite = true;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(preferences.nextWrite, isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(find.text('企画メモを確認'), findsOneWidget);
    write.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('企画メモを確認'), findsOneWidget);
    expect(find.text('手入力と通知を1件試す'), findsOneWidget);
    preferences.rejectWrite = false;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(idea.resumableSession!.reviewDraft!.memo.nextStep, '手入力と通知を1件試す');
    expect(idea.memos, isEmpty);
    await tapText(tester, '開く');
    expect(find.text('企画メモを確認'), findsOneWidget);
    expect(find.text('手入力と通知を1件試す'), findsOneWidget);
    await tapText(tester, '企画メモを保存');
    expect(idea.memos.single.nextStep, '手入力と通知を1件試す');
    expect(idea.memos.single.hasFitness, isFalse);
    expect(idea.sessions.single.finished, isTrue);
    expect(idea.sessions.single.reviewDraft, isNull);
  });

  testWidgets('別の質問の使用と未決の回答を保持し、回答の修正で下書きを更新する', (tester) async {
    final store = _OfflineStore();
    await store.load();
    final idea = await store.addIdea('作業へ戻る', '強制中断はしない');
    await tester.pumpWidget(
      MaterialApp(
        home: DigScreen(store: store, idea: idea),
      ),
    );
    await tester.pumpAndSettle();
    final original = idea.resumableSession!.pendingQuestion!.text;
    await tapText(tester, '別の質問');
    expect(idea.resumableSession!.pendingQuestion!.text, isNot(original));
    expect(idea.resumableSession!.answers, isEmpty);
    expect(find.text('別の質問'), findsNothing);
    await tapText(tester, 'まだ分からない');
    expect(idea.resumableSession!.answers.single.undecided, isTrue);
    await tapText(tester, 'ここまでをまとめる');
    final draft = idea.resumableSession!.reviewDraft;
    await tapText(tester, '質問に戻る');
    await tapText(tester, 'ここまでをまとめる');
    expect(idea.resumableSession!.reviewDraft!.revision, draft!.revision);
    await tapText(tester, '質問に戻る');
    await tapText(tester, '1問もどる');
    expect(idea.resumableSession!.reviewDraft, isNull);
    expect(find.text('別の質問'), findsNothing);
    await tester.enterText(find.byType(TextField), '会議の後、次にすることを思い出せない');
    await tapText(tester, '答える');
    await tapText(tester, 'もう1問');
    expect(idea.resumableSession!.pendingQuestion!.axis, isNotNull);
    expect(
      idea.resumableSession!.answers.single.axis,
      isNot(idea.resumableSession!.pendingQuestion!.axis),
    );
  });

  testWidgets('回答保存中のバックグラウンド移行後も選択を表示し、下書きの保存だけ再試行する', (tester) async {
    final preferences = _FailingPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    final store = _OfflineStore();
    await store.load();
    final idea = await store.addIdea('試作', '端末内で使う');
    await tester.pumpWidget(
      MaterialApp(
        home: DigScreen(store: store, idea: idea),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '買い物から帰ったとき');
    await tester.pump();
    final answerWrite = Completer<bool>();
    preferences.nextWrite = answerWrite;
    await tester.tap(find.text('答える'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    answerWrite.complete(true);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('ここまでをまとめる'), findsOneWidget);
    expect(idea.resumableSession!.pendingQuestion, isNull);
    preferences.rejectWrite = true;
    await tapText(tester, 'ここまでをまとめる');
    expect(find.text('再開する'), findsOneWidget);
    expect(store.ai.summaries, 1);
    expect(idea.resumableSession!.reviewDraft, isNull);
    preferences.rejectWrite = false;
    await tapText(tester, '再開する');
    expect(find.text('企画メモを確認'), findsOneWidget);
    expect(store.ai.summaries, 1);
  });

  test('確定失敗はセッションを戻し、再試行と二重確定は1版だけを保存する', () async {
    final preferences = _FailingPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    final store = _OfflineStore();
    await store.load();
    final idea = await store.addIdea('写真', '端末内に保存');
    final session = DigSession(
      id: 'session',
      startedAt: DateTime(2026),
      answers: const [QaEntry(questionId: 'q1', question: '何を？', answer: '写真')],
    );
    idea.sessions.add(session);
    await store.updateIdea(idea);
    final memo = PlanMemo(
      what: '',
      who: '',
      why: '',
      how: '',
      nextStep: '',
      openQuestions: '何枚まで使いやすいか',
      createdAt: DateTime(2026),
      version: 99,
      input: const MemoInput(
        title: '写真',
        note: '端末内に保存',
        sessionId: 'session',
        answerCount: 1,
      ),
    );
    await store.saveMemoDraft(
      ideaId: idea.id,
      sessionId: session.id,
      expectedRevision: null,
      draft: MemoDraft(revision: 'draft', memo: memo),
      reviewOpen: true,
    );
    final edited = memo.copyWith(nextStep: '制作順で写真を3枚並べる');
    Future<PlanMemo> confirm() => store.confirmMemoDraft(
      ideaId: idea.id,
      sessionId: session.id,
      revision: 'draft',
      edited: edited,
    );
    preferences.rejectWrite = true;
    await expectLater(confirm(), throwsA(isA<StoreFailure>()));
    expect(idea.memos, isEmpty);
    expect(session.finished, isFalse);
    expect(session.reviewOpen, isTrue);
    expect(session.reviewDraft!.revision, 'draft');
    preferences.rejectWrite = false;
    final confirmed = await Future.wait([confirm(), confirm()]);
    expect(confirmed.map((item) => item.version), [1, 1]);
    final reloaded = _OfflineStore();
    await reloaded.load();
    final stored = reloaded.visibleIdeas.single;
    expect(stored.sessions.single.finished, isTrue);
    expect(stored.sessions.single.reviewDraft, isNull);
    expect(stored.memos.single.nextStep, '制作順で写真を3枚並べる');
    final brief = buildDevBrief(stored);
    expect(brief, contains('## 未確認のこと\n何枚まで使いやすいか'));
    expect(brief, contains('先に作るものと検証する仮説を本人に確認'));
  });
}
