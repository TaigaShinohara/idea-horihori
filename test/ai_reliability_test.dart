import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/app_config.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/prompts.dart';
import 'package:horihori/screens/dig_screen.dart';
import 'package:horihori/screens/detail_screen.dart';
import 'package:horihori/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ondevice_test.dart' show FakeOnDeviceClient;
import 'store_test.dart' show FakeSecretStore;

const _exampleQuestion = '{"id":"q1","text":"試しに聞く質問","choices":["A","B","C"]}';
Idea _idea() =>
    Idea(id: 'example', title: 'Synthetic example', createdAt: DateTime(2026));

class _PendingDevice extends FakeOnDeviceClient {
  final pending = Completer<OnDeviceCheck>();

  @override
  Future<OnDeviceCheck> checkStatus() => pending.future;
}

class _AbortClient extends http.BaseClient {
  final started = Completer<void>();
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cancellable = request as http.AbortableRequest;
    started.complete();
    await cancellable.abortTrigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }
}

class _FailingSecrets extends FakeSecretStore {
  bool failWrite = false;
  bool failDelete = false;
  bool loseWrite = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw PlatformException(code: 'WRITE_FAILED');
    if (!loseWrite) await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw PlatformException(code: 'DELETE_FAILED');
    await super.delete(key);
  }
}

class _ScreenStore extends IdeaStore {
  final ResilientBackend ai;
  _ScreenStore(this.ai) : super(secrets: FakeSecretStore());
  @override
  ResilientBackend backend() => ai;
}

String _response(String text) => jsonEncode({
  'candidates': [
    {
      'finishReason': 'STOP',
      'content': {
        'parts': [
          {'thought': true, 'text': 'not the answer'},
          {'text': text},
        ],
      },
    },
  ],
});

http.Response _questionResponse() =>
    http.Response.bytes(utf8.encode(_response(_exampleQuestion)), 200);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  Future<IdeaStore> cloudStore() async {
    final store = IdeaStore(secrets: FakeSecretStore());
    await store.load();
    await store.saveApiKey('fixture-key');
    await store.saveRemoteConsent(true);
    return store;
  }

  test('終了済みモデルのみ移行し、利用者指定のモデルを保持する', () async {
    SharedPreferences.setMockInitialValues({
      AppConfig.prefsModelKey: 'models/gemini-2.0-flash-001',
    });

    final store = IdeaStore(secrets: FakeSecretStore());
    await store.load();
    expect(store.model, AppConfig.defaultGeminiModel);
    expect(
      (await SharedPreferences.getInstance()).getString(
        AppConfig.prefsModelKey,
      ),
      AppConfig.defaultGeminiModel,
    );
    await store.saveModel('models/gemini-3.8-flash');
    final reloaded = IdeaStore(secrets: FakeSecretStore());
    await reloaded.load();
    expect(reloaded.model, 'gemini-3.8-flash');
  });

  test('キー移行は書込みと読み戻しを確認してから行う', () async {
    SharedPreferences.setMockInitialValues({
      AppConfig.prefsApiKeyKey: 'fixture-key',
      AppConfig.prefsRemoteConsentKey: true,
    });
    final secrets = _FailingSecrets()..loseWrite = true;
    final store = IdeaStore(secrets: secrets);
    await store.load();
    expect(store.loaded, isTrue);
    expect(store.apiKey, isEmpty);
    expect(store.remoteConsent, isFalse);
    expect(store.keyStorageError, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConfig.prefsApiKeyKey), 'fixture-key');
    secrets.loseWrite = false;
    await store.load();
    expect(store.apiKey, 'fixture-key');
    expect(prefs.getString(AppConfig.prefsApiKeyKey), isNull);
  });

  test('削除失敗を報告し、残ったキーで再起動後も送信しない', () async {
    final secrets = _FailingSecrets();
    final store = IdeaStore(secrets: secrets);
    await store.load();
    await store.saveApiKey('fixture-key');
    await store.saveRemoteConsent(true);
    secrets.failDelete = true;
    await expectLater(store.deleteApiKey(), throwsA(isA<StoreFailure>()));
    expect(store.remoteConsent, isFalse);
    final restarted = IdeaStore(secrets: secrets);
    await restarted.load();
    expect(restarted.backend().remote, isNull);
    expect(restarted.hasRemoteKey, isTrue);
  });

  test('キー保存失敗を成功扱いせず、設定の再試行ができる', () async {
    final secrets = _FailingSecrets()..failWrite = true;
    final store = IdeaStore(secrets: secrets);
    await store.load();
    await expectLater(
      store.saveApiKey('fixture-key'),
      throwsA(isA<StoreFailure>()),
    );
    expect(store.hasRemoteKey, isFalse);
    expect(store.keyStorageError, isNotNull);
    secrets.failWrite = false;
    await store.saveApiKey('fixture-key');
    expect(store.hasRemoteKey, isTrue);
    expect(store.keyStorageError, isNull);
  });

  test('破損した1件を退避し正常なアイデアを読み込む', () async {
    final raw = jsonEncode([
      _idea().toJson(),
      <String, dynamic>{'id': 7},
    ]);
    SharedPreferences.setMockInitialValues({AppConfig.prefsIdeasKey: raw});
    final store = IdeaStore(secrets: FakeSecretStore());
    await store.load();
    expect(store.visibleIdeas.single.id, 'example');
    expect(store.ideasRecoveryNotice, isNotNull);
    expect(
      (await SharedPreferences.getInstance()).getString(
        AppConfig.prefsIdeasBackupKey,
      ),
      raw,
    );
  });

  test('オンデバイス待機中に同意を撤回すると送信しない', () async {
    final store = await cloudStore();
    final client = _PendingDevice();
    var requests = 0;
    await http.runWithClient(
      () async {
        final ai = ResilientBackend(
          null,
          onDevice: OnDeviceBackend(client: client),
          remoteFactory: () => store.backend().remote,
        );
        final pending = ai.nextQuestion(idea: _idea(), history: const []);
        await store.saveRemoteConsent(false);
        client.pending.complete(
          const OnDeviceCheck(OnDeviceStatus.unavailable),
        );
        expect((await pending).source, AnswerSource.local);
      },
      () => MockClient((_) async {
        requests++;
        return _questionResponse();
      }),
    );
    expect(requests, 0);
  });

  test('開始済みHTTPは同意撤回で中止し、結果を採用しない', () async {
    final store = await cloudStore();
    final client = _AbortClient();
    await http.runWithClient(() async {
      final ai = store.backend().remote!;
      final pending = ai.nextQuestion(idea: _idea(), history: const []);
      final outcome = expectLater(pending, throwsA(GeminiFailure.revoked));
      await client.started.future;
      await store.saveRemoteConsent(false);
      await client.aborted.future;
      await outcome;
    }, () => client);
  });

  test('キャンセル後の遅延結果を保存せず、その後の定型生成は進む', () async {
    final client = _PendingDevice();
    var requests = 0;
    final cloud = GeminiBackend(
      apiKey: 'fixture-key',
      client: MockClient((_) async {
        requests++;
        return _questionResponse();
      }),
    );
    final ai = ResilientBackend(
      cloud,
      onDevice: OnDeviceBackend(client: client),
    );
    final pending = ai.nextQuestion(idea: _idea(), history: const []);
    final outcome = expectLater(pending, throwsA(isA<AiCancelled>()));
    ai.cancelPending();
    expect(
      (await ai.nextQuestion(
        idea: _idea(),
        history: const [],
        templateOnly: true,
      )).source,
      AnswerSource.local,
    );
    client.pending.complete(const OnDeviceCheck(OnDeviceStatus.unavailable));
    await outcome;
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
    expect(ai.lastSource, AnswerSource.local);
  });

  test('Geminiの接続確認はGETで、生成では型付きJSONと表示候補だけを使う', () async {
    final requests = <http.Request>[];
    final api = GeminiBackend(
      apiKey: 'fixture-key',
      client: MockClient((request) async {
        requests.add(request);
        return request.method == 'GET'
            ? http.Response(
                '{"supportedGenerationMethods":["generateContent"]}',
                200,
              )
            : _questionResponse();
      }),
    );
    await api.verifyConnection();
    expect(requests.first.body, isEmpty);
    expect(requests.first.url.query, isEmpty);
    final q = await api.nextQuestion(idea: _idea(), history: const []);
    expect(q.text, '試しに聞く質問');
    final json = jsonDecode(requests.last.body) as Map;
    expect(json['generationConfig']['responseMimeType'], 'application/json');
    expect(json['generationConfig']['responseJsonSchema']['type'], 'object');
  });

  test('GeminiのHTTP失敗と制限を区別する', () async {
    for (final (status, expected) in [
      (403, GeminiFailure.invalidKey),
      (404, GeminiFailure.invalidModel),
      (429, GeminiFailure.quota),
      (503, GeminiFailure.unavailable),
    ]) {
      final api = GeminiBackend(
        apiKey: 'fixture-key',
        client: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(api.verifyConnection(), throwsA(expected));
    }
  });

  test('巨大な履歴は最近の回答を残して縮め、型違いは安全に拒否する', () {
    final history = [
      for (var index = 0; index < 200; index++)
        QaEntry(
          questionId: '$index',
          question: '質問$index',
          answer: '回答$index ${'長文' * 1400}',
        ),
    ];
    final prompt = Prompts.summarize(
      title: 'あ' * 12000,
      history: history,
      budget: Prompts.nanoBudget,
    );
    expect(prompt.runes.length, lessThan(2000));
    expect(prompt, contains('回答199'));
    expect(prompt, isNot(contains('回答0 ')));
    expect(Prompts.parseMemo('{"what":1,"who":"x"}', version: 1), isNull);
    expect(Prompts.parseNameCandidates('{"candidates":4}'), isEmpty);
    expect(Prompts.parseNameCandidates('{"candidates":["A","A",7,"B","C"]}'), [
      'A',
      'B',
      'C',
    ]);
  });

  testWidgets('5問回答済みの再開は6問目を出さず、企画メモを保存する', (tester) async {
    final ai = ResilientBackend(null);
    final store = _ScreenStore(ai);
    await store.load();
    final idea = await store.addIdea('再開のテスト', '');
    idea.sessions.add(
      DigSession(
        id: 'saved',
        startedAt: DateTime(2026),
        answers: List.generate(
          5,
          (i) => QaEntry(questionId: '$i', question: 'Q', answer: 'A'),
        ),
      ),
    );
    await store.updateIdea(idea);
    await tester.pumpWidget(
      MaterialApp(
        home: DigScreen(store: store, idea: idea),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(idea.sessions.single.answers, hasLength(5));
    expect(idea.sessions.single.finished, isTrue);
    expect(idea.memos.single.source, AnswerSource.local);
    expect(
      PlanMemo.fromJson(idea.memos.single.toJson()).source,
      AnswerSource.local,
    );
  });

  testWidgets('深掘りを退出すると遅れて戻る生成結果を保存しない', (tester) async {
    final client = _PendingDevice();
    final store = _ScreenStore(
      ResilientBackend(null, onDevice: OnDeviceBackend(client: client)),
    );
    await store.load();
    final idea = await store.addIdea('退出のテスト', '');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DigScreen(store: store, idea: idea),
                  ),
                ),
                child: const Text('開く'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pageBack();
    await tester.pump();
    client.pending.complete(const OnDeviceCheck(OnDeviceStatus.unavailable));
    await tester.pumpAndSettle();
    expect(idea.sessions, isEmpty);
  });
}
