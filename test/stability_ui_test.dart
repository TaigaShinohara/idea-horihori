import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/chatgpt_auth_service.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/first_dig.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/screens/archive_screen.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/screens/home_screen.dart';
import 'package:horihori/screens/settings_screen.dart';
import 'package:horihori/store.dart';
import 'package:horihori/widgets/memo_review_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  final Map<String, String> _data = {};

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

class _ThrowingOnDeviceClient implements OnDeviceTextClient {
  @override
  Future<OnDeviceCheck> checkStatus() async =>
      throw Exception('AICore service error');

  @override
  Future<void> downloadModel() async {}

  @override
  Future<String> generate(String prompt) async => '';
}

class _TestIdeaStore extends IdeaStore {
  _TestIdeaStore({
    this.client,
    this.failSaveDigStyle = false,
    this.saveModelCompleter,
    this.customBackend,
  }) : super(secrets: _MemorySecretStore());

  final OnDeviceTextClient? client;
  bool failSaveDigStyle;
  Completer<void>? saveModelCompleter;
  ResilientBackend? customBackend;

  @override
  ResilientBackend backend() => customBackend ?? super.backend();

  @override
  OnDeviceBackend onDeviceBackend({
    void Function(double? progress)? onDownloadProgress,
  }) {
    return OnDeviceBackend(
      client: client ?? _ThrowingOnDeviceClient(),
      onDownloadProgress: onDownloadProgress,
    );
  }

  @override
  Future<void> saveDigStyle(DigStyle style) async {
    if (failSaveDigStyle) {
      throw const StoreFailure('disk full');
    }
    await super.saveDigStyle(style);
  }

  @override
  Future<void> saveModel(String value) async {
    if (saveModelCompleter != null) {
      await saveModelCompleter!.future;
    }
    await super.saveModel(value);
  }
}

Idea _sampleIdea({
  String id = 'idea-1',
  String title = 'アイデアタイトル',
  bool archived = false,
  List<PlanMemo>? memos,
}) {
  return Idea(
    id: id,
    title: title,
    createdAt: DateTime(2026, 11, 24),
    archived: archived,
    memos: memos,
  );
}

Widget _wrapApp(
  Widget child, {
  double width = 390,
  double textScale = 1.0,
  EdgeInsets viewPadding = EdgeInsets.zero,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 844),
        padding: viewPadding,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsScreen stability', () {
    testWidgets('_runDiagnosis resets _checking and shows checkFailed on throw', (
      tester,
    ) async {
      final store = _TestIdeaStore(client: _ThrowingOnDeviceClient());
      await store.load();

      await tester.pumpWidget(_wrapApp(SettingsScreen(store: store)));
      await tester.pumpAndSettle();

      expect(
        find.text('AIの優先順：端末AI → ChatGPT → Gemini API → 定型'),
        findsOneWidget,
      );
      expect(
        find.text('AICoreの状態を確認できませんでした（使えないと確定ではありません）。下の「質問を試す」で、実際に生成できるか確かめられます。'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, '質問を試す'), findsOneWidget);
      expect(find.text('端末AIが使えないときにChatGPTを使う'), findsOneWidget);
      expect(find.textContaining('OpenAIへ送信します'), findsOneWidget);
      // v0.4.0 で ChatGPT カードが増え「詳細・動作確認」が ListView の
      // 構築範囲外に出たため、ListView を明示してスクロールで出現させる
      // （Scrollable が複数あるため scrollUntilVisible の既定探索は使えない）。
      await tester.dragUntilVisible(
        find.text('詳細・動作確認'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.ensureVisible(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('モデル名を保存'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      expect(
        find.widgetWithText(OutlinedButton, 'モデル名を保存'),
        findsOneWidget,
      );

      await tester.dragUntilVisible(
        find.text('状態を確認する'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '状態を確認する'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('PopScope prevents pop while _editing is in flight', (
      tester,
    ) async {
      final completer = Completer<void>();
      final store = _TestIdeaStore(saveModelCompleter: completer);
      await store.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(store: store),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('保存する'),
        find.byType(ListView),
        const Offset(0, -150),
      );
      await tester.ensureVisible(find.text('保存する'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存する'));
      await tester.pump();

      final popScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScope.canPop, isFalse);

      completer.complete();
      await tester.pumpAndSettle();

      final popScopeAfter = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScopeAfter.canPop, isTrue);
    });

    testWidgets('background lifecycle re-obscures API key field', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();

      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byTooltip('APIキーを表示'),
        find.byType(ListView),
        const Offset(0, -150),
      );
      await tester.ensureVisible(find.byTooltip('APIキーを表示'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('APIキーを表示'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('APIキーを隠す'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byTooltip('APIキーを表示'), findsOneWidget);
    });

    testWidgets('shows current AI summary and allows cancel/manual code during browser sign-in', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      final auth = _FakeChatGptAuthService();

      await tester.pumpWidget(
        _wrapApp(
          SettingsScreen(store: store, chatGptAuthService: auth),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('現在：定型モード（設定なしでも使えます）'), findsOneWidget);

      await tester.tap(find.text('ChatGPTでサインイン'));
      await tester.pump();

      expect(find.text('ブラウザでサインイン中…'), findsOneWidget);
      expect(find.text('キャンセル'), findsOneWidget);
      final popScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScope.canPop, isTrue);

      await tester.dragUntilVisible(
        find.text('ブラウザから戻れない時は'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.ensureVisible(find.text('ブラウザから戻れない時は'));
      await tester.pump();
      await tester.tap(find.text('ブラウザから戻れない時は'));
      await tester.pump(const Duration(milliseconds: 300));
      final codeField = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '認可コード',
        ),
      );
      expect(codeField.enabled, isTrue);

      await tester.dragUntilVisible(
        find.text('キャンセル'),
        find.byType(ListView),
        const Offset(0, 100),
      );
      await tester.ensureVisible(find.text('キャンセル'));
      await tester.pump();
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(auth.cancelCalls, 1);
      expect(find.text('サインインをキャンセルしました。'), findsOneWidget);
    });
  });

  group('ArchiveScreen stability', () {
    testWidgets('_ArchivedCard uses ValueKey(idea.id) and does not overflow', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      store.ideas = [
        _sampleIdea(id: 'a1', title: 'アーカイブ1', archived: true),
        _sampleIdea(id: 'a2', title: 'アーカイブ2', archived: true),
      ];

      await tester.pumpWidget(
        _wrapApp(
          ArchiveScreen(store: store),
          width: 320,
          textScale: 2.0,
          viewPadding: const EdgeInsets.only(bottom: 34),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('a2')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DigScreen stability', () {
    testWidgets('_DigOptionsSheet reverts selection and shows error on failure', (
      tester,
    ) async {
      final store = _TestIdeaStore(failSaveDigStyle: true);
      await store.load();
      final idea = _sampleIdea();
      idea.sessions.add(
        DigSession(
          id: 's1',
          startedAt: DateTime(2026, 11, 24),
          pendingQuestion: const DigQuestion(
            id: 'q1',
            text: '誰のため？',
            choices: ['自分', '友達', '家族'],
            source: AnswerSource.local,
          ),
        ),
      );

      await tester.pumpWidget(
        _wrapApp(DigScreen(store: store, idea: idea)),
      );
      await tester.pumpAndSettle();

      // Open options sheet
      await tester.tap(find.text('友達・通常'));
      await tester.pumpAndSettle();

      // Tap '上司モード' which fails to save
      await tester.tap(find.text('上司モード'));
      await tester.pumpAndSettle();

      // Reverted back to '友達モード' and error shown inside sheet
      final friendChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '友達モード'),
      );
      final bossChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '上司モード'),
      );
      expect(friendChip.selected, isTrue);
      expect(bossChip.selected, isFalse);
      expect(find.text('変更を保存できませんでした。もう一度お試しください。'), findsOneWidget);
    });

    testWidgets('DigScreen handles narrow screen + large textScale + bottom inset', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      final idea = _sampleIdea();
      idea.sessions.add(
        DigSession(
          id: 's1',
          startedAt: DateTime(2026, 11, 24),
          pendingQuestion: const DigQuestion(
            id: 'q1',
            text: '誰のため？',
            choices: ['自分', '友達', '家族'],
            source: AnswerSource.local,
          ),
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          DigScreen(store: store, idea: idea),
          width: 320,
          textScale: 2.0,
          viewPadding: const EdgeInsets.only(bottom: 34),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('DigScreen keeps settings button even after keyGuideShown and shows phase label', (
      tester,
    ) async {
      final completer = Completer<DigQuestion>();
      final backend = _PhaseTestBackend(completer);
      final store = _TestIdeaStore(customBackend: backend);
      await store.load();
      await store.markKeyGuideShown();
      final idea = await store.addIdea('アイデアタイトル', '');

      await tester.pumpWidget(
        _wrapApp(DigScreen(store: store, idea: idea)),
      );
      await tester.pump();

      backend.onPhase?.call(AiPhase.chatGpt);
      await tester.pump();
      expect(find.text('ChatGPTで考えています…'), findsOneWidget);

      backend.onPhase?.call(AiPhase.cloud);
      await tester.pump();
      expect(find.text('Geminiで考えています…'), findsOneWidget);

      backend.lastSource = AnswerSource.local;
      completer.complete(
        const DigQuestion(
          id: 'q1',
          text: '誰のため？',
          choices: ['自分', '友達', '家族'],
          source: AnswerSource.local,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('設定を開く'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        final chipFinder = find.bySemanticsLabel('掘り方と視点を変更。現在：友達・通常');
        expect(chipFinder, findsOneWidget);
        expect(tester.getSize(chipFinder).height, greaterThanOrEqualTo(48));
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('DigScreen shows ChatGPT auth error with settings button and checkpoint answer preview', (
      tester,
    ) async {
      final backend = _ChatGptErrorTestBackend();
      final store = _TestIdeaStore(customBackend: backend);
      await store.load();
      final idea = await store.addIdea('散歩メモ', '');

      await tester.pumpWidget(
        _wrapApp(DigScreen(store: store, idea: idea)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('ChatGPTの認証が切れています。設定画面からサインインし直してください。'),
        findsOneWidget,
      );
      expect(find.text('設定を開く'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '朝の散歩で使いたい');
      await tester.pump();
      await tester.ensureVisible(find.text('答える'));
      await tester.pump();
      await tester.tap(find.text('答える'));
      await tester.pumpAndSettle();

      expect(find.text('ここまでの回答を保存しました'), findsOneWidget);
      expect(find.text('A: 朝の散歩で使いたい'), findsOneWidget);
      expect(find.text('もう1問'), findsOneWidget);
      expect(find.text('ここまでをまとめる'), findsOneWidget);
    });
  });

  group('HomeScreen & MemoReviewPane stability', () {
    testWidgets('HomeScreen shows 3-step guide on empty state and review action for open draft', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();

      await tester.pumpWidget(_wrapApp(HomeScreen(store: store)));
      await tester.pumpAndSettle();

      expect(find.text('1行メモ'), findsOneWidget);
      expect(find.text('質問に答える'), findsOneWidget);
      expect(find.text('企画メモ'), findsOneWidget);

      final idea = await store.addIdea('テスト企画', 'メモ');
      idea.sessions.add(
        DigSession(
          id: 's1',
          startedAt: DateTime(2026, 11, 27),
          reviewOpen: true,
          reviewDraft: MemoDraft(
            revision: 'rev1',
            memo: PlanMemo(
              what: 'テスト',
              who: '',
              why: '',
              how: '',
              nextStep: '',
              openQuestions: '',
              createdAt: DateTime(2026, 11, 27),
              version: 1,
              input: MemoInput(
                title: 'テスト企画',
                note: 'メモ',
                sessionId: 's1',
                answerCount: 0,
              ),
            ),
          ),
        ),
      );
      await store.updateIdea(idea);
      await tester.pumpAndSettle();

      expect(find.text('下書きを確認'), findsOneWidget);
    });

    testWidgets('MemoReviewPane keeps save button visible without scrolling', (
      tester,
    ) async {
      final idea = _sampleIdea();
      final memo = PlanMemo(
        what: '長い内容\n' * 10,
        who: '自分',
        why: '忘れるから',
        how: 'メモする',
        nextStep: '試す',
        openQuestions: '',
        createdAt: DateTime(2026, 11, 27),
        version: 1,
      );

      await tester.pumpWidget(
        _wrapApp(
          Scaffold(
            body: MemoReviewPane(
              idea: idea,
              memo: memo,
              busy: false,
              canSave: true,
              onChanged: (_) {},
              onBlur: () {},
              onSave: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveButton = find.text('企画メモを保存');
      expect(saveButton, findsOneWidget);
      final rect = tester.getRect(saveButton);
      expect(rect.bottom, lessThanOrEqualTo(844));
    });
  });

  group('DetailScreen stability', () {
    testWidgets('DetailScreen handles narrow screen + large textScale without overflow', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      final idea = _sampleIdea(
        memos: [
          PlanMemo(
            what: '何を作る',
            who: '誰に',
            why: 'なぜ',
            how: 'どうやって',
            nextStep: '次の一歩',
            createdAt: DateTime(2026, 11, 24),
            version: 1,
            source: AnswerSource.local,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrapApp(
          DetailScreen(store: store, idea: idea),
          width: 320,
          textScale: 2.0,
          viewPadding: const EdgeInsets.only(bottom: 34),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('_NameCandidatesSheet applies title and shows SnackBar safely', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      final idea = _sampleIdea(
        memos: [
          PlanMemo(
            what: '朝の支度',
            who: '忙しい人',
            why: '迷わないため',
            how: '通知する',
            nextStep: '試す',
            createdAt: DateTime(2026, 11, 24),
            version: 1,
            source: AnswerSource.local,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrapApp(DetailScreen(store: store, idea: idea)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('名前候補'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('タイトルにする').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('変更する'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('_NameCandidatesSheet shows paused notice on AiCancelled and copy notice inside sheet', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') return null;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final namesCompleter = Completer<List<String>>();
      final backend = _NameSheetTestBackend(namesCompleter);
      final store = _TestIdeaStore(customBackend: backend);
      await store.load();
      final idea = _sampleIdea(
        memos: [
          PlanMemo(
            what: '朝の支度',
            who: '忙しい人',
            why: '迷わないため',
            how: '通知する',
            nextStep: '試す',
            createdAt: DateTime(2026, 11, 24),
            version: 1,
            ease: 2,
            spark: 3,
            source: AnswerSource.local,
          ),
          PlanMemo(
            what: '朝の支度v2',
            who: '忙しい人',
            why: '迷わないため',
            how: '通知する',
            nextStep: '試す',
            createdAt: DateTime(2026, 11, 25),
            version: 2,
            source: AnswerSource.local,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrapApp(DetailScreen(store: store, idea: idea)),
      );
      await tester.pumpAndSettle();

      // 旧メモの Semantics チェック
      await tester.dragUntilVisible(
        find.text('メモ v1'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.tap(find.text('メモ v1'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('作りやすさ 3段階中2'), findsOneWidget);
      expect(find.bySemanticsLabel('ワクワク度 3段階中3'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('名前候補'),
        find.byType(ListView),
        const Offset(0, 100),
      );
      await tester.tap(find.text('名前候補'));
      await tester.pump();
      await tester.pump();

      backend.onPhase?.call(AiPhase.chatGpt);
      await tester.pump();
      expect(find.text('ChatGPTで名前の候補を考えています…'), findsOneWidget);

      namesCompleter.completeError(const AiCancelled());
      await tester.pumpAndSettle();
      expect(find.text('生成を中断しました。再開できます。'), findsOneWidget);
      expect(find.text('再開する'), findsOneWidget);

      backend.nextNames = Future.value(['アサラク', 'モニアプ', 'シタクン']);
      await tester.tap(find.text('再開する'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('アサラクをコピー'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('「アサラク」をコピーしました'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('DetailScreen hides duplicate session history for latest memo and avoids empty dashes', (
      tester,
    ) async {
      final store = _TestIdeaStore();
      await store.load();
      final idea = Idea(
        id: 'dup-test',
        title: '重複確認',
        createdAt: DateTime(2026, 11, 27),
        sessions: [
          DigSession(
            id: 's1',
            startedAt: DateTime(2026, 11, 27),
            finished: true,
            answers: const [
              QaEntry(questionId: 'q1', question: '場面は？', answer: '朝'),
            ],
          ),
        ],
        memos: [
          PlanMemo(
            what: '',
            who: '',
            why: '',
            how: '',
            nextStep: '',
            openQuestions: '',
            createdAt: DateTime(2026, 11, 27),
            version: 1,
            source: AnswerSource.local,
            input: const MemoInput(
              title: '重複確認',
              note: '元のメモ',
              sessionId: 's1',
              answerCount: 1,
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        _wrapApp(DetailScreen(store: store, idea: idea)),
      );
      await tester.pumpAndSettle();

      expect(find.text('深掘りの記録'), findsNothing);
      expect(
        find.text('まだ整理中のメモです。「元メモと回答」に記録が残っています。'),
        findsOneWidget,
      );
      expect(find.text('—'), findsNothing);
    });
  });
}

class _PhaseTestBackend extends ResilientBackend {
  _PhaseTestBackend(this._completer) : super(null);
  final Completer<DigQuestion> _completer;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    bool templateOnly = false,
    List<QaEntry>? templateHistory,
    FirstDigContext? firstDig,
  }) => _completer.future;
}

class _NameSheetTestBackend extends ResilientBackend {
  _NameSheetTestBackend(this.firstCompleter) : super(null);
  final Completer<List<String>> firstCompleter;
  Future<List<String>>? nextNames;

  @override
  Future<List<String>> nameCandidates({
    required Idea idea,
    bool templateOnly = false,
  }) {
    if (nextNames != null) {
      lastSource = AnswerSource.local;
      return nextNames!;
    }
    return firstCompleter.future;
  }
}

class _FakeChatGptAuthService extends ChatGptAuthService {
  Completer<void>? _pendingSignIn;
  int cancelCalls = 0;

  @override
  Future<void> signIn() async {
    _pendingSignIn = Completer<void>();
    await _pendingSignIn!.future;
  }

  @override
  Future<void> cancelSignIn({bool preserveVerifier = false}) async {
    cancelCalls++;
    final pending = _pendingSignIn;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const ChatGptAuthException('ChatGPT のサインインがキャンセルされました。'),
      );
    }
  }
}

class _ChatGptErrorTestBackend extends ResilientBackend {
  _ChatGptErrorTestBackend() : super(null);

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    bool templateOnly = false,
    List<QaEntry>? templateHistory,
    FirstDigContext? firstDig,
  }) async {
    lastSource = AnswerSource.local;
    lastChatGptFailed = true;
    lastChatGptError = 'ChatGPTの認証が切れています。設定画面からサインインし直してください。';
    return const DigQuestion(
      id: 'guided_1_scene',
      text: '最初にこのアプリを使うのはどんな場面？',
      choices: ['困ったそのとき', '後で思い出すとき', '楽しみとして始めるとき'],
      source: AnswerSource.local,
      axis: 'scene',
    );
  }
}
