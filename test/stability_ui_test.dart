import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/screens/archive_screen.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/screens/settings_screen.dart';
import 'package:horihori/store.dart';
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
  }) : super(secrets: _MemorySecretStore());

  final OnDeviceTextClient? client;
  bool failSaveDigStyle;
  Completer<void>? saveModelCompleter;

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
        find.text('AICoreの状態を確認できませんでした（使えないと確定ではありません）。下の「質問を試す」で、実際に生成できるか確かめられます。'),
        findsOneWidget,
      );
      // v0.4.0 で ChatGPT カードが増え「詳細・動作確認」が ListView の
      // 構築範囲外に出たため、ListView を明示してスクロールで出現させる
      // （Scrollable が複数あるため scrollUntilVisible の既定探索は使えない）。
      await tester.dragUntilVisible(
        find.text('詳細・動作確認'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.tap(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();

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

      await tester.ensureVisible(find.text('保存する'));
      await tester.tap(find.text('保存する'));
      await tester.pump();

      final popScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScope.canPop, isFalse);

      completer.complete();
      await tester.pumpAndSettle();

      final popScopeAfter = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScopeAfter.canPop, isTrue);
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
  });
}
