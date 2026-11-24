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
          expect(req.headers['Authorization'], 'Bearer fake-token');
          expect(req.headers['chatgpt-account-id'], 'acc-1');
          return _jsonResponse(
            _codexResponse('{"id": "q1", "text": "誰に届けたい？", "choices": ["個人", "チーム", "企業"]}'),
          );
        }),
      );
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
  });

  group('チェーン: オンデバイス失敗 → ChatGPT', () {
    test('ChatGPT が応答元になり、モードは chatGpt になる', () async {
      final backend = ResilientBackend(
        null,
        onDevice: _ThrowingBackend(),
        chatGpt: ChatGptBackend(
          authService: _FakeAuth(),
          client: MockClient((_) async => _jsonResponse(
                _codexResponse('{"id": "q1", "text": "質問？", "choices": ["a", "b", "c"]}'),
              )),
        ),
      );
      final idea = Idea(id: '1', title: 'x', note: '', createdAt: DateTime(2026));
      final q = await backend.nextQuestion(idea: idea, history: const []);
      expect(q.text, '質問？');
      expect(backend.lastSource, AnswerSource.chatGpt);
      expect(backend.lastOnDeviceFailed, isTrue);
      expect(backend.currentModeKind, DigModeKind.chatGpt);
      expect(DigModeKind.chatGpt.label, 'ChatGPTで深掘り中');
      expect(DigModeKind.chatGpt.isAi, isTrue);
    });
  });
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
