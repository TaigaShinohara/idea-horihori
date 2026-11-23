import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/main.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/screens/settings_screen.dart';
import 'package:horihori/store.dart';
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
    final store = IdeaStore(secrets: FakeSecretStore());
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB34E14)),
        scaffoldBackgroundColor: Colors.transparent,
      );

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

    testWidgets('設定（v0.3.1で作り替えた画面）', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      expect(find.text('オンデバイスAI'), findsOneWidget);
      expect(find.text('状態を確認する'), findsOneWidget);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/settings.png'));
    });

    testWidgets('深掘り（質問表示）', (tester) async {
      setSurface(tester);
      final store = await loadedStore(ideaCount: 1);
      final idea = store.visibleIdeas.first;
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: DigScreen(store: store, idea: idea),
      ));
      // オンデバイス/リモートはテスト環境では失敗し、定型へ落ちる。
      // その経路でも画面が成立することを確認する。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
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

    testWidgets('設定の診断ボタンで状態表示が出る', (tester) async {
      setSurface(tester);
      final store = await loadedStore();
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      await tester.ensureVisible(find.text('状態を確認する'));
      await tester.tap(find.text('状態を確認する'));
      // 診断はタイムアウト15秒を持つため、フェイク時間を十分に進める。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      // プラグインのないテスト環境は、機種非対応ではなく確認失敗になる。
      expect(find.textContaining('AICoreの状態を確認できませんでした'),
          findsOneWidget);
    });

    testWidgets('Nanoの試用で生成したサンプル質問を表示する', (tester) async {
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
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: SettingsScreen(store: store),
      ));
      await tester.pump();
      await tester.ensureVisible(find.text('Nanoで質問を試す'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nanoで質問を試す'));
      await tester.pumpAndSettle();

      expect(find.text('Gemini Nanoで生成できました'), findsOneWidget);
      expect(find.text('どこを歩く？'), findsOneWidget);
      expect(store.ideas, isEmpty);
    });
  });
}
