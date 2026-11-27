import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/google_workspace.dart';
import 'package:horihori/google_workspace_config.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/plan_document.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/screens/settings_screen.dart';
import 'package:horihori/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store_test.dart' show FakeSecretStore;

class _FakeGateway implements GoogleAccountGateway {
  GoogleAccountInfo? restored;
  GoogleAccountInfo signInResult = const GoogleAccountInfo(
    id: 'u1',
    email: 'taiga@example.com',
    displayName: 'Taiga',
  );
  Object? signInError;
  String? silentToken;
  String? interactiveToken;
  int restoreCalls = 0;
  int signInCalls = 0;
  int signOutCalls = 0;
  final List<bool> tokenCalls = [];

  @override
  Future<GoogleAccountInfo?> restoreAccount() async {
    restoreCalls++;
    return restored;
  }

  @override
  Future<GoogleAccountInfo> signIn() async {
    signInCalls++;
    final error = signInError;
    if (error != null) throw error;
    restored = signInResult;
    return signInResult;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    restored = null;
  }

  @override
  Future<String?> accessToken({required bool interactive}) async {
    tokenCalls.add(interactive);
    return interactive ? interactiveToken : silentToken;
  }
}

Idea _ideaWithMemo() {
  final session = DigSession(
    id: 's1',
    startedAt: DateTime(2026, 11, 20),
    answers: const [
      QaEntry(questionId: 'q1', question: '誰に届けたい？', answer: '個人開発者'),
    ],
    finished: true,
  );
  final memo = PlanMemo(
    what: '思いつきを企画に育てるアプリ',
    who: '個人開発者',
    why: '思いつきが流れてしまうから',
    how: 'AIの質問で深掘りする',
    nextStep: '試作を作る',
    createdAt: DateTime(2026, 11, 21),
    version: 2,
    ease: 2,
    spark: 3,
    input: const MemoInput(
      title: 'アイデアホリホリ',
      note: '1行メモから育てたい',
      sessionId: 's1',
      answerCount: 1,
    ),
  );
  return Idea(
    id: 'i1',
    title: 'アイデアホリホリ',
    createdAt: DateTime(2026, 11, 20),
    sessions: [session],
    memos: [memo],
  );
}

const _configured = GoogleWorkspaceConfig(webClientId: 'web-client-id');

/// 日本語を含む JSON 応答（http.Response の文字列ボディは Latin-1 化する
/// ため、bytes で作る）。
http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('GoogleWorkspaceConfig', () {
    test('未設定では isConfigured が false、ID があれば true', () {
      expect(const GoogleWorkspaceConfig().isConfigured, isFalse);
      expect(_configured.isConfigured, isTrue);
      expect(
        const GoogleWorkspaceConfig(iosClientId: 'ios-id').isConfigured,
        isTrue,
      );
    });

    test('スコープは drive.file のみ', () {
      expect(GoogleWorkspaceConfig.scopes, [
        'https://www.googleapis.com/auth/drive.file',
      ]);
    });

    test('テスト環境の fromEnvironment は未設定（dart-define なし）', () {
      expect(GoogleWorkspaceConfig.fromEnvironment.isConfigured, isFalse);
    });
  });

  group('buildPlanDocument', () {
    test('5欄・元メモ・Q&A を含み、指示書の指示文は含めない', () {
      final doc = buildPlanDocument(_ideaWithMemo());
      expect(doc, contains('企画書: アイデアホリホリ'));
      expect(doc, contains('- 何を作る: 思いつきを企画に育てるアプリ'));
      expect(doc, contains('- 誰に: 個人開発者'));
      expect(doc, contains('- なぜ: 思いつきが流れてしまうから'));
      expect(doc, contains('- どうやって: AIの質問で深掘りする'));
      expect(doc, contains('- 次の一歩: 試作を作る'));
      expect(doc, contains('体力測定'));
      expect(doc, contains('## 元メモ'));
      expect(doc, contains('1行メモから育てたい'));
      expect(doc, contains('Q: 誰に届けたい？ → A: 個人開発者'));
      expect(doc, isNot(contains('作ってください')));
    });

    test('確認済みメモは「決めたこと／未確認のこと／次に試すこと」で整形する', () {
      final idea = _ideaWithMemo();
      final reviewed = PlanMemo(
        what: '作るもの',
        who: '',
        why: '',
        how: '',
        nextStep: '検証する',
        createdAt: DateTime(2026, 11, 22),
        version: 3,
        openQuestions: '料金は未定',
      );
      final doc = buildPlanDocument(idea, memo: reviewed);
      expect(doc, contains('## 決めたこと'));
      expect(doc, contains('## 未確認のこと'));
      expect(doc, contains('料金は未定'));
      expect(doc, contains('## 次に試すこと'));
    });

    test('ドキュメント名はタイトル＋企画書＋版数', () {
      expect(planDocumentName(_ideaWithMemo()), 'アイデアホリホリ 企画書 v2');
    });
  });

  group('GoogleDriveUploader', () {
    test('multipart ボディにメタデータ（Googleドキュメント変換）と本文が入る', () {
      const boundary = 'test-boundary-123';
      final body = GoogleDriveUploader.buildMultipartBody(
        name: 'テスト 企画書',
        content: '本文です',
        boundary: boundary,
      );
      expect(body, startsWith('--$boundary'));
      expect(body, contains('"mimeType":"application/vnd.google-apps.document"'));
      expect(body, contains('"name":"テスト 企画書"'));
      expect(body, contains('本文です'));
      expect(body, endsWith('--$boundary--\r\n'));

      final b1 = GoogleDriveUploader.generateBoundary();
      final b2 = GoogleDriveUploader.generateBoundary();
      expect(b1, isNot(equals(b2)));
    });

    test('アップロード要求の宛先・ヘッダ・応答パース', () async {
      http.BaseRequest? captured;
      final uploader = GoogleDriveUploader(
        httpClient: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'id': 'doc-1',
            'name': 'アイデアホリホリ 企画書 v2',
            'webViewLink': 'https://docs.google.com/document/d/doc-1/edit',
          });
        }),
      );
      final doc = await uploader.uploadAsGoogleDoc(
        accessToken: 'secret-token',
        name: 'アイデアホリホリ 企画書 v2',
        content: '本文',
      );
      final request = captured as http.Request;
      expect(request.followRedirects, isFalse);
      expect(request.url.host, 'www.googleapis.com');
      expect(request.url.path, '/upload/drive/v3/files');
      expect(request.url.queryParameters['uploadType'], 'multipart');
      expect(request.headers['Authorization'], 'Bearer secret-token');
      expect(
        request.headers['Content-Type'],
        contains('multipart/related; boundary='),
      );
      expect(request.body, contains('application/vnd.google-apps.document'));
      expect(doc.id, 'doc-1');
      expect(doc.name, 'アイデアホリホリ 企画書 v2');
      expect(doc.webViewLink, 'https://docs.google.com/document/d/doc-1/edit');
    });

    test('非200ではユーザー向け例外（トークンは含めない）', () async {
      final uploader = GoogleDriveUploader(
        httpClient: MockClient(
          (_) async => http.Response('{"error":"bad"}', 403),
        ),
      );
      await expectLater(
        uploader.uploadAsGoogleDoc(
          accessToken: 'secret-token',
          name: 'x',
          content: 'y',
        ),
        throwsA(
          isA<GoogleWorkspaceException>()
              .having((e) => e.message, 'message', contains('403'))
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
    });

    test('応答形式が不正なら例外', () {
      expect(
        () => GoogleDriveUploader.parseUploadResponse('{"name":"x"}'),
        throwsA(isA<GoogleWorkspaceException>()),
      );
    });
  });

  group('GoogleWorkspaceService', () {
    test('未設定ではゲートウェイに触れず、正直に未設定を返す', () async {
      final gateway = _FakeGateway();
      final service = GoogleWorkspaceService(
        config: const GoogleWorkspaceConfig(),
        gateway: gateway,
      );
      expect(service.isConfigured, isFalse);
      expect(await service.currentAccount(), isNull);
      await expectLater(
        service.signIn(),
        throwsA(
          isA<GoogleWorkspaceException>().having(
            (e) => e.message,
            'message',
            contains('未設定（セットアップ待ち）'),
          ),
        ),
      );
      await expectLater(
        service.sendPlanToDrive(_ideaWithMemo()),
        throwsA(isA<GoogleWorkspaceException>()),
      );
      await service.signOut();
      expect(gateway.restoreCalls, 0);
      expect(gateway.signInCalls, 0);
      expect(gateway.tokenCalls, isEmpty);
    });

    test('認可済みトークンがあればサインインせずそのまま送る', () async {
      final gateway = _FakeGateway()..silentToken = 'tok-silent';
      String? sentBody;
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
        httpClient: MockClient((request) async {
          sentBody = request.body;
          return _jsonResponse({
            'id': 'doc-9',
            'name': 'アイデアホリホリ 企画書 v2',
            'webViewLink': 'https://docs.google.com/document/d/doc-9/edit',
          });
        }),
      );
      final doc = await service.sendPlanToDrive(_ideaWithMemo());
      expect(doc.id, 'doc-9');
      expect(gateway.signInCalls, 0);
      expect(gateway.tokenCalls, [false]);
      expect(sentBody, contains('思いつきを企画に育てるアプリ'));
    });

    test('トークンが無ければサインイン→対話的認可へ進む', () async {
      final gateway = _FakeGateway()..interactiveToken = 'tok-interactive';
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
        httpClient: MockClient(
          (_) async => _jsonResponse({'id': 'doc-2', 'name': 'n'}),
        ),
      );
      final doc = await service.sendPlanToDrive(_ideaWithMemo());
      expect(doc.id, 'doc-2');
      expect(gateway.signInCalls, 1);
      expect(gateway.tokenCalls, [false, true]);
    });

    test('サインインのキャンセルはそのまま伝わる', () async {
      final gateway = _FakeGateway()
        ..signInError = const GoogleWorkspaceException(
          'Google サインインがキャンセルされました。',
        );
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
        httpClient: MockClient(
          (_) async => http.Response('{}', 200),
        ),
      );
      await expectLater(
        service.sendPlanToDrive(_ideaWithMemo()),
        throwsA(
          isA<GoogleWorkspaceException>().having(
            (e) => e.message,
            'message',
            contains('キャンセル'),
          ),
        ),
      );
    });

    test('メモが無いアイデアは送れない', () async {
      final gateway = _FakeGateway()..silentToken = 'tok';
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
      );
      final bare = Idea(
        id: 'bare',
        title: 'メモなし',
        createdAt: DateTime(2026),
      );
      await expectLater(
        service.sendPlanToDrive(bare),
        throwsA(
          isA<GoogleWorkspaceException>().having(
            (e) => e.message,
            'message',
            contains('企画メモがまだありません'),
          ),
        ),
      );
    });
    test('isAllowedExternalUrl が許可された Google URL のみを通す', () {
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('https://docs.google.com/document/d/doc-1/edit'),
        ),
        isTrue,
      );
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('https://drive.google.com/file/d/file-1/view'),
        ),
        isTrue,
      );
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('http://docs.google.com/document/d/doc-1/edit'),
        ),
        isFalse,
      );
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('https://evil.example/document'),
        ),
        isFalse,
      );
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('https://docs.google.com.evil.example/doc'),
        ),
        isFalse,
      );
      expect(
        GoogleWorkspaceService.isAllowedExternalUrl(
          Uri.parse('https://user@docs.google.com/doc'),
        ),
        isFalse,
      );
    });
  });

  group('Google Workspace UI', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    IdeaStore newStore() {
      final store = IdeaStore(secrets: FakeSecretStore());
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable),
      );
      return store;
    }

    testWidgets('設定: 未設定カードが正直に表示される', (tester) async {
      final service = GoogleWorkspaceService(
        config: const GoogleWorkspaceConfig(),
        gateway: _FakeGateway(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(store: newStore(), googleService: service),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Google Workspace'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      expect(find.text('Google Workspace'), findsOneWidget);
      expect(find.textContaining('未設定（セットアップ待ち）'), findsOneWidget);
      expect(find.text('Googleでサインイン'), findsNothing);
    });

    testWidgets('設定: サインイン済みならメールアドレスとサインアウトが出る', (
      tester,
    ) async {
      final gateway = _FakeGateway()
        ..restored = const GoogleAccountInfo(
          id: 'u1',
          email: 'taiga@example.com',
        );
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(store: newStore(), googleService: service),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Google Workspace'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.pump();
      expect(find.textContaining('taiga@example.com'), findsOneWidget);
      expect(find.text('サインアウト'), findsWidgets);
    });

    testWidgets('設定: 未サインインからサインインできる', (tester) async {
      final gateway = _FakeGateway();
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(store: newStore(), googleService: service),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Googleでサインイン'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.ensureVisible(find.text('Googleでサインイン'));
      await tester.pump();
      await tester.tap(find.text('Googleでサインイン'));
      await tester.pump();
      await tester.pump();
      expect(gateway.signInCalls, 1);
      expect(find.text('サインインしました'), findsOneWidget);
      expect(find.textContaining('taiga@example.com'), findsOneWidget);
    });

    testWidgets('詳細: 未設定ではボタンから未設定が伝わる', (tester) async {
      final service = GoogleWorkspaceService(
        config: const GoogleWorkspaceConfig(),
        gateway: _FakeGateway(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            store: newStore(),
            idea: _ideaWithMemo(),
            googleService: service,
          ),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Googleドキュメントで開く'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.tap(find.text('Googleドキュメントで開く'));
      await tester.pump();
      expect(
        find.text('Google連携は未設定（セットアップ待ち）です。'),
        findsOneWidget,
      );
    });

    testWidgets('詳細: 送信が成功すると完了ダイアログが出る', (tester) async {
      final gateway = _FakeGateway()..silentToken = 'tok';
      final service = GoogleWorkspaceService(
        config: _configured,
        gateway: gateway,
        httpClient: MockClient(
          (_) async => _jsonResponse({
            'id': 'doc-1',
            'name': 'アイデアホリホリ 企画書 v2',
            'webViewLink': 'https://docs.google.com/document/d/doc-1/edit',
          }),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            store: newStore(),
            idea: _ideaWithMemo(),
            googleService: service,
          ),
        ),
      );
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Googleドキュメントで開く'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.tap(find.text('Googleドキュメントで開く'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Googleドキュメントを作成しました'), findsOneWidget);
      expect(find.textContaining('アイデアホリホリ 企画書 v2'), findsWidgets);
      expect(find.text('開く'), findsOneWidget);
    });
  });
}
