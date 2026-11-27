import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/main.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/screens/archive_screen.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/screens/dev_brief_screen.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/screens/settings_screen.dart';
import 'package:horihori/store.dart';
import 'package:horihori/widgets/glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// 交付前UI検証（実機なし検証の標準、2026-11-23 本人決定）:
/// 主要画面を JVM 上で描画し、レイアウト崩壊・はみ出し・遷移破損を
/// golden と widget テストで先に捕まえる。
///
/// カバー範囲:
/// - 起動直後の画面（ホーム：空状態／アイデアあり）
/// - その版で作り替えた画面（v0.3.1: 設定のオンデバイスAI診断）
/// - 中核フロー（深掘り／詳細）
/// ※ オンボーディングはこのアプリには存在しない。
///
/// 注意: golden はテスト用フォントで描画されるため、文字の見た目
/// そのものではなく「崩れ・はみ出し・重なり」の検出が目的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<IdeaStore> loadedStore({int ideaCount = 0}) async {
    SharedPreferences.setMockInitialValues({});
    // セキュア保存チャネルは widget テストでハングするため、両方とも差し替える。
    final store = IdeaStore(
      secrets: FakeSecretStore(),
      chatGptChecker: () async => false,
    );
    await store.load();
    for (var i = 0; i < ideaCount; i++) {
      await store.addIdea('アイデア${i + 1}：散歩メモアプリ', '思いつきメモ');
    }
    return store;
  }

  void setSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  ThemeData theme() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kAccent),
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: kButtonFill,
            foregroundColor: Colors.white,
          ),
        ),
      );

  double relativeLuminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  double contrastRatio(Color fg, Color bg) {
    final l1 = relativeLuminance(fg);
    final l2 = relativeLuminance(bg);
    return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
  }

  group('golden: 主要画面', () {
    testWidgets('ホーム（空状態）', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      await tester.pumpWidget(HorihoriApp(store: store));
      await tester.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/home_empty.png'));
    });

    testWidgets('ホーム（アイデアあり）', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 2);
      await tester.pumpWidget(HorihoriApp(store: store));
      await tester.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/home_with_ideas.png'));
    });

    testWidgets('設定（v0.3.2再設計）', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.needsDownload),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      expect(find.text('端末AI'), findsOneWidget);
      expect(find.text('モデルを準備する'), findsOneWidget);
      // v0.4.0 で ChatGPT カードが入り、詳細カードはスクロール先になった。
      // 存在確認のためスクロールしてから先頭に戻して撮影する。
      await tester.scrollUntilVisible(
        find.text('詳細・動作確認'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('詳細・動作確認'), findsOneWidget);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/settings.png'));
    });

    testWidgets('深掘り（質問表示）', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      final idea = store.visibleIdeas.first;
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DigScreen(store: store, idea: idea),
      ));
      await tester.pumpAndSettle();
      expect(find.text('0 / 5問'), findsOneWidget);
      expect(find.text('答える'), findsOneWidget);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/dig.png'));
    });

    testWidgets('詳細', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      final idea = store.visibleIdeas.first;
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DetailScreen(store: store, idea: idea),
      ));
      await tester.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/detail.png'));
    });
  });

  group('widget: 遷移と表示', () {
    test('コントラスト比: ライト・ダークのアクセント文字と主ボタンが 4.5:1 以上', () {
      expect(contrastRatio(Colors.white, kButtonFill), greaterThanOrEqualTo(4.5));
      expect(
        contrastRatio(kAccentDeep, const Color(0xFFF2F0EC)),
        greaterThanOrEqualTo(4.5),
      );
      // ダーク読み物ガラス（#17181C に白16%合成 ≒ #3C3D41）
      const darkReadingGlass = Color(0xFF3C3D41);
      expect(
        contrastRatio(kAccentOnDark, darkReadingGlass),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('アーカイブ件数があっても操作名を読み上げる', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final store = await loadedStore(ideaCount: 1);
        await store.archiveIdea(store.visibleIdeas.single);
        await tester.pumpWidget(HorihoriApp(store: store));
        expect(find.bySemanticsLabel('アーカイブ 1件'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('ホームでアイデアをタップすると詳細へ遷移する', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      await tester.pumpWidget(HorihoriApp(store: store));
      await tester.pump();
      await tester.tap(find.textContaining('アイデア1'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(DetailScreen), findsOneWidget);
    });

    testWidgets('設定の診断ボタン（詳細・動作確認内）で状態表示が出る', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('詳細・動作確認'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('状態を確認する'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('状態を確認する'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.textContaining('AICoreの状態を確認できませんでした'),
          findsOneWidget);
    });

    testWidgets('Nanoの試用（詳細・動作確認内）で生成したサンプル質問を表示する', (tester) async {
      setSurface(tester);
      const channel = MethodChannel('flutter_device_ai');
      final messenger = TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'getAvailability' => {'status': 'available', 'reason': 'ready'},
          'getPlatformInfo' => {'backend': 'androidMlKitGenAi'},
          'sessionCountTokens' => 100,
          'sessionGetResponse' => {
              'text': '{"id":"q1","text":"どこを歩く？","choices":["公園","川","街"]}',
            },
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final store = await loadedStore();
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.available),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('詳細・動作確認'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('詳細・動作確認'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Nanoで質問を試す'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nanoで質問を試す'));
      await tester.pumpAndSettle();

      expect(find.text('Gemini Nanoで生成できました'), findsOneWidget);
      expect(find.text('どこを歩く？'), findsOneWidget);
      expect(store.ideas, isEmpty);
    });

    testWidgets('設定の必須開示2要素が常時表示され、キー保存時に同意スイッチ案内が出る', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();

      expect(find.textContaining('送信内容：'), findsNWidgets(2));
      expect(find.textContaining('注意点：'), findsNWidgets(2));
      expect(find.textContaining('OpenAIへ送信します'), findsOneWidget);
      expect(find.textContaining('GoogleのGemini APIへ送信します'), findsOneWidget);
      expect(find.textContaining('Google AI Studio'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'test-api-key-123');
      await tester.ensureVisible(find.text('保存する'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存する'));
      await tester.pumpAndSettle();

      expect(store.remoteConsent, isFalse);
      expect(find.textContaining('下のスイッチをONにしてください'), findsOneWidget);
    });

    testWidgets('深掘り画面で掘り方・視点シートを開け、選択肢チップを再タップで解除できる', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      final idea = store.visibleIdeas.first;
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DigScreen(store: store, idea: idea),
      ));
      await tester.pumpAndSettle();

      // 1行ヘッダの現在値チップをタップ → ガラス調整シート
      await tester.tap(find.text('友達・通常'));
      await tester.pumpAndSettle();
      expect(find.text('変更は次の質問から反映されます。'), findsOneWidget);
      await tester.tap(find.text('お金'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('掘り方・視点'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('友達・お金'), findsOneWidget);

      // ChoiceChip の選択 → 再タップ解除
      final firstChip = find.byType(ChoiceChip).first;
      await tester.tap(firstChip);
      await tester.pump();
      expect(tester.widget<ChoiceChip>(firstChip).selected, isTrue);
      await tester.tap(firstChip);
      await tester.pump();
      expect(tester.widget<ChoiceChip>(firstChip).selected, isFalse);
    });

    testWidgets('詳細画面: 芽状態で深掘りの記録と「つづきを掘る」が出る', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      final idea = store.visibleIdeas.first;
      idea.sessions.add(
        DigSession(
          id: 's1',
          startedAt: DateTime(2026, 11, 24),
          answers: [
            const QaEntry(
              questionId: 'who',
              question: '誰が使う？',
              answer: '自分',
            ),
          ],
        ),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DetailScreen(store: store, idea: idea),
      ));
      await tester.pump();

      expect(find.text('つづきを掘る'), findsOneWidget);
      expect(find.text('深掘りの記録'), findsOneWidget);
    });

    testWidgets('詳細画面: メモありで生成元がヘッダ右端に出て体力測定にSemanticsがある', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        setSurface(tester);
        final store = await loadedStore(ideaCount: 1);
        final idea = store.visibleIdeas.first;
        idea.memos.add(
          PlanMemo(
            what: '散歩ログ',
            who: '自分',
            why: '続けたい',
            how: '1タップ記録',
            nextStep: 'プロトタイプを作る',
            createdAt: DateTime(2026, 11, 24),
            version: 1,
            ease: 2,
            spark: 3,
            source: AnswerSource.onDevice,
          ),
        );
        await tester.pumpWidget(MaterialApp(
          theme: theme(),
          home: DetailScreen(store: store, idea: idea),
        ));
        await tester.pump();

        expect(find.text('端末AI'), findsOneWidget);
        expect(find.textContaining('生成元'), findsNothing);
        expect(
          find.bySemanticsLabel('作りやすさ 3段階中2、ワクワク度 3段階中3'),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('アーカイブ空状態と開発指示書画面が崩れず表示される', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: ArchiveScreen(store: store),
      ));
      await tester.pump();
      expect(find.text('アーカイブはありません'), findsOneWidget);
      expect(find.text('📦'), findsNothing);

      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DevBriefScreen(idea: store.visibleIdeas.first),
      ));
      await tester.pump();
      expect(find.text('コピー'), findsOneWidget);
    });
  });
}
