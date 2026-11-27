import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/chatgpt_auth_service.dart';
import 'package:horihori/chatgpt_backend.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeAuth extends ChatGptAuthService {
  @override
  Future<String?> getValidAccessToken() async => 'fake-token';
  @override
  Future<String?> getAccountId() async => 'acc-1';
}

class _WaitingAuth extends _FakeAuth {
  final requested = Completer<void>();
  final token = Completer<String?>();

  @override
  Future<String?> getValidAccessToken() {
    requested.complete();
    return token.future;
  }
}

Idea _fixtureIdea() =>
    Idea(id: 'fixture', title: '試作を記録するアプリ', createdAt: DateTime(2026));

String _codexResponse(String text) => jsonEncode({
  'output': [
    {
      'type': 'message',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    },
  ],
});

/// 日本語ボディは latin1 制約を避けるため bytes で返す。
http.Response _jsonResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('ChatGPT 認証 (PKCE / JWT / トークン)', () {
    test('PKCE: RFC 7636 のテストベクタと一致する', () {
      expect(
        ChatGptAuthService.computeCodeChallenge(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('JWT から ChatGPT アカウント ID を取り出す', () {
      String seg(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final jwt =
          '${seg({'alg': 'none'})}.${seg({
            'https://api.openai.com/auth': {'chatgpt_account_id': 'acc-xyz'},
          })}.sig';
      expect(ChatGptAuthService.extractAccountId(jwt), 'acc-xyz');
      expect(ChatGptAuthService.extractAccountId('not-a-jwt'), isNull);
      expect(ChatGptAuthService.extractAccountId(null), isNull);
    });

    test('トークン応答のパース（有効期限とアカウントID）', () {
      String seg(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final idToken =
          '${seg({'alg': 'none'})}.${seg({
            'https://api.openai.com/auth': {'chatgpt_account_id': 'acc-9'},
          })}.sig';
      final tokens = ChatGptAuthService.parseTokenResponse(
        {
          'access_token': 'at',
          'refresh_token': 'rt',
          'id_token': idToken,
          'expires_in': 3600,
        },
        now: DateTime(2026, 1, 1),
      );
      expect(tokens.accessToken, 'at');
      expect(tokens.refreshToken, 'rt');
      expect(tokens.accountId, 'acc-9');
      expect(tokens.expiresAt, DateTime(2026, 1, 1, 1));
    });
  });

  group('ChatGPT バックエンド', () {
    test('認証待ちの取消後は生成を送信しない', () async {
      final auth = _WaitingAuth();
      var sends = 0;
      final backend = ResilientBackend(
        null,
        chatGpt: ChatGptBackend(
          authService: auth,
          client: MockClient((_) async {
            sends++;
            return _jsonResponse(_codexResponse('Invalid JSON'));
          }),
        ),
      );
      final pending = backend.nextQuestion(idea: _fixtureIdea(), history: []);
      final cancelled = expectLater(pending, throwsA(isA<AiCancelled>()));
      await auth.requested.future;
      backend.cancelPending();
      await cancelled;
      auth.token.complete('fake-token');
      await Future<void>.delayed(Duration.zero);
      expect(sends, 0);
    });

    test('送信済みの応答が取消後に戻っても再試行しない', () async {
      final dispatched = Completer<void>();
      final response = Completer<http.Response>();
      var sends = 0;
      final backend = ResilientBackend(
        null,
        chatGpt: ChatGptBackend(
          authService: _FakeAuth(),
          client: MockClient((_) {
            sends++;
            if (!dispatched.isCompleted) dispatched.complete();
            return response.future;
          }),
        ),
      );
      final pending = backend.nextQuestion(idea: _fixtureIdea(), history: []);
      final cancelled = expectLater(pending, throwsA(isA<AiCancelled>()));
      await dispatched.future;
      backend.cancelPending();
      await cancelled;
      response.complete(_jsonResponse(_codexResponse('Invalid JSON')));
      await Future<void>.delayed(Duration.zero);
      expect(sends, 1);
      expect(backend.lastSource, isNull);
    });

    test('認証後にサインアウトすると生成を送信しない', () async {
      final auth = _WaitingAuth();
      var maySend = true;
      var sends = 0;
      final backend = ChatGptBackend(
        authService: auth,
        maySend: () => maySend,
        client: MockClient((_) async {
          sends++;
          return _jsonResponse(_codexResponse('Invalid JSON'));
        }),
      );
      final pending = backend.nextQuestion(idea: _fixtureIdea(), history: []);
      final revoked = expectLater(pending, throwsA(isA<ChatGptException>()));
      await auth.requested.future;
      maySend = false;
      auth.token.complete('fake-token');
      await revoked;
      expect(sends, 0);
    });

    test('Responses API の output からテキストを取り出す', () {
      final text = ChatGptBackend.extractOutputText({
        'output': [
          {
            'type': 'reasoning',
            'content': [],
          },
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'こんにちは'},
              {'type': 'output_text', 'text': '世界'},
            ],
          },
        ],
      });
      expect(text, 'こんにちは世界');
    });

    test('nextQuestion が Codex 応答をパースして返す', () async {
      final backend = ChatGptBackend(
        authService: _FakeAuth(),
        client: MockClient((req) async {
          expect(req.url.toString(), ChatGptBackend.endpoint);
          expect(req.followRedirects, isFalse);
          expect(req.headers['Authorization'], 'Bearer fake-token');
          expect(req.headers['chatgpt-account-id'], 'acc-1');
          return _jsonResponse(
            _codexResponse('{"id": "q1", "text": "誰に届けたい？", "choices": ["個人", "チーム", "企業"]}'),
          );
        }),
      );
      expect(ChatGptBackend.generateTimeout, const Duration(seconds: 25));
      final idea = Idea(id: '1', title: 'アイデア', note: '', createdAt: DateTime(2026));
      final q = await backend.nextQuestion(idea: idea, history: const []);
      expect(q.text, '誰に届けたい？');
      expect(q.choices, hasLength(3));
    });

    test('未サインイン（トークンなし）では失敗して理由が残る', () async {
      final backend = ChatGptBackend(
        authService: ChatGptAuthService(
          store: _MemoryTokenStore(),
        ),
        client: MockClient((_) async => _jsonResponse('{}')),
      );
      final idea = Idea(id: '1', title: 'x', note: '', createdAt: DateTime(2026));
      await expectLater(
        backend.nextQuestion(idea: idea, history: const []),
        throwsA(isA<ChatGptException>()),
      );
      expect(backend.lastError, contains('サインイン'));
    });

    test('予期しない例外で生エラー文字列を露出しない', () async {
      final backend = ChatGptBackend(
        authService: _FakeAuth(),
        client: MockClient((_) async => throw StateError('secret-internal-detail')),
      );
      await expectLater(
        backend.nextQuestion(idea: _fixtureIdea(), history: const []),
        throwsA(
          isA<ChatGptException>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret-internal-detail')),
          ),
        ),
      );
      expect(backend.lastError, isNot(contains('secret-internal-detail')));
    });

    test('signOut で保存削除が失敗したら例外を投げる', () async {
      final auth = ChatGptAuthService(store: _FailingDeleteTokenStore());
      await expectLater(
        auth.signOut(),
        throwsA(isA<ChatGptAuthException>()),
      );
    });
  });

  group('チェーン: オンデバイス失敗 → ChatGPT → Gemini → ローカル', () {
    test('ChatGPT が応答元になり、モードは chatGpt・フェーズは chatGpt になる', () async {
      final phases = <AiPhase>[];
      final backend = ResilientBackend(
        null,
        onDevice: _ThrowingBackend(),
        chatGpt: ChatGptBackend(
          authService: _FakeAuth(),
          client: MockClient((_) async => _jsonResponse(
                _codexResponse('{"id": "q1", "text": "質問？", "choices": ["a", "b", "c"]}'),
              )),
        ),
      )..onPhase = phases.add;
      final idea = Idea(id: '1', title: 'x', note: '', createdAt: DateTime(2026));
      final q = await backend.nextQuestion(idea: idea, history: const []);
      expect(q.text, '質問？');
      expect(phases, [AiPhase.onDevice, AiPhase.chatGpt]);
      expect(backend.lastSource, AnswerSource.chatGpt);
      expect(backend.lastOnDeviceFailed, isTrue);
      expect(backend.lastChatGptFailed, isFalse);
      expect(backend.currentModeKind, DigModeKind.chatGpt);
      expect(DigModeKind.chatGpt.label, 'ChatGPTで深掘り中');
      expect(DigModeKind.chatGpt.isAi, isTrue);
    });

    test('3段フォールバック: オンデバイス失敗 → ChatGPT失敗 → Gemini成功時は lastChatGptFailed が false', () async {
      final phases = <AiPhase>[];
      final backend = ResilientBackend(
        GeminiBackend(
          apiKey: 'fixture-key',
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'candidates': [
                    {
                      'finishReason': 'STOP',
                      'content': {
                        'parts': [
                          {
                            'text':
                                '{"id":"g1","text":"Gemini質問？","choices":["1","2","3"]}',
                          },
                        ],
                      },
                    },
                  ],
                }),
              ),
              200,
            ),
          ),
        ),
        onDevice: _ThrowingBackend(),
        chatGpt: ChatGptBackend(
          authService: _FakeAuth(),
          client: MockClient((_) async => http.Response('error', 503)),
        ),
      )..onPhase = phases.add;

      final q = await backend.nextQuestion(idea: _fixtureIdea(), history: const []);
      expect(q.text, 'Gemini質問？');
      expect(phases, [AiPhase.onDevice, AiPhase.chatGpt, AiPhase.cloud]);
      expect(backend.lastSource, AnswerSource.remote);
      expect(backend.lastChatGptFailed, isFalse);
      expect(backend.lastChatGptError, isNull);
    });

    test('fallbackReasonFor が ChatGPT 同意オフ・失敗を正しく判定する', () {
      expect(
        fallbackReasonFor(
          isLocalSource: true,
          hasRemoteKey: false,
          remoteConsent: false,
          lastRemoteFailed: false,
          hasChatGpt: true,
          chatGptConsent: false,
        ),
        FallbackReason.remoteConsentOff,
      );
      expect(
        fallbackReasonFor(
          isLocalSource: true,
          hasRemoteKey: false,
          remoteConsent: false,
          lastRemoteFailed: false,
          hasChatGpt: true,
          chatGptConsent: true,
          lastChatGptFailed: true,
        ),
        FallbackReason.remoteFailed,
      );
    });
  });
}

class _FailingDeleteTokenStore extends _MemoryTokenStore {
  @override
  Future<void> delete(String key) async {
    throw Exception('delete failed');
  }
}

class _ThrowingBackend implements AiBackend {
  @override
  bool get isRemote => false;
  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
  }) async =>
      throw Exception('on-device unavailable');
  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
  }) async =>
      throw Exception('on-device unavailable');
  @override
  Future<List<String>> nameCandidates({required Idea idea}) async =>
      throw Exception('on-device unavailable');
}

class _MemoryTokenStore implements TokenStore {
  final Map<String, String> _data = {};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async => _data[key] = value;
  @override
  Future<void> delete(String key) async => _data.remove(key);
}
