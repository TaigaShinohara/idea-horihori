import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_device_ai/flutter_device_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/fallback.dart';
import 'package:horihori/models.dart';
import 'package:horihori/name_candidates.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/prompts.dart';
import 'package:horihori/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecrets implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _SlowOnDeviceClient implements OnDeviceTextClient {
  final Completer<OnDeviceCheck> statusCompleter = Completer<OnDeviceCheck>();
  int generateCalls = 0;

  @override
  Future<OnDeviceCheck> checkStatus() => statusCompleter.future;

  @override
  Future<void> downloadModel() async {}

  @override
  Future<String> generate(String prompt) async {
    generateCalls++;
    return '{"id":"q1","text":"質問","choices":["A","B","C"]}';
  }
}

class _StubSession implements OnDeviceAiSession {
  final Future<int> Function(String text) onCountTokens;
  final Future<String> Function(String prompt) onAsk;
  bool closed = false;

  _StubSession({required this.onCountTokens, required this.onAsk});

  @override
  Future<AiResponse> ask(String prompt, {GenerationConfig? config}) async {
    final text = await onAsk(prompt);
    return AiResponse(text: text);
  }

  @override
  Stream<String> askStream(String prompt, {GenerationConfig? config}) =>
      const Stream.empty();

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<int> countTokens({String? text}) => onCountTokens(text ?? '');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubFlutterDeviceAi implements FlutterDeviceAi {
  final OnDeviceAiSession Function() createSessionFn;
  int createdSessions = 0;

  _StubFlutterDeviceAi(this.createSessionFn);

  @override
  Future<OnDeviceAiAvailability> availability() async =>
      OnDeviceAiAvailability(
        status: ModelFeatureStatus.available,
        reason: AvailabilityReason.values.first,
        message: '',
      );

  @override
  Future<OnDeviceAiSession> createSession({
    String? systemInstruction,
    List<OnDeviceAiTool>? tools,
    GenerationConfig? config,
    int maxToolRounds = 5,
  }) async {
    createdSessions++;
    return createSessionFn();
  }

  @override
  Stream<ModelDownloadStatus> downloadModel() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('models / prompts / name_candidates', () {
    test('PlanMemo.fromJson accepts double version', () {
      final memo = PlanMemo.fromJson({
        'what': 'w',
        'who': 'u',
        'why': 'y',
        'how': 'h',
        'nextStep': 'n',
        'version': 2.0,
      });
      expect(memo.version, 2);
    });

    test('Prompts.extractJson handles prose braces and string braces', () {
      const raw =
          '解説 {ここは無視} です。\n{"id":"q1","text":"{波括弧}を含む質問","choices":["A","B","C"]}\n補足 {終わり}';
      final parsed = Prompts.extractJson(raw);
      expect(parsed, isNotNull);
      expect(parsed!['id'], 'q1');
      expect(parsed['text'], '{波括弧}を含む質問');
    });

    test('LocalNameCandidates.generate does not split surrogate pairs', () {
      final candidates = LocalNameCandidates.generate(
        title: '🚀🌟🔥💡🎯🎨📱',
        memo: PlanMemo(
          what: '😀😃😄😁😆😅😂🤣',
          who: '',
          why: '',
          how: '',
          nextStep: '',
          createdAt: DateTime(2026),
          version: 1,
        ),
      );
      expect(candidates, hasLength(3));
      for (final c in candidates) {
        // UTF-16 unpaired surrogates would fail Utf8Encoder/decoding check.
        expect(() => utf8.decode(utf8.encode(c)), returnsNormally);
      }
    });
  });

  group('IdeaStore stability', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('addIdea throws before load() completes', () async {
      final store = IdeaStore(secrets: _MemorySecrets());
      await expectLater(
        store.addIdea('未ロード', ''),
        throwsA(isA<StoreFailure>()),
      );
      expect(store.ideas, isEmpty);
    });

    test('addIdea produces unique IDs on consecutive calls', () async {
      final store = IdeaStore(
        secrets: _MemorySecrets(),
        now: () => DateTime(2026, 1, 1, 12, 0, 0),
      );
      await store.load();
      final a = await store.addIdea('A', '');
      final b = await store.addIdea('B', '');
      expect(a.id, isNot(equals(b.id)));
    });

    test('updateIdea / archiveIdea / deleteIdea match by id', () async {
      final store = IdeaStore(secrets: _MemorySecrets());
      await store.load();
      final created = await store.addIdea('元タイトル', '');
      final copy = Idea.fromJson(created.toJson())..title = '更新タイトル';

      await store.updateIdea(copy);
      expect(store.ideas.single.title, '更新タイトル');

      await store.archiveIdea(Idea.fromJson(copy.toJson()));
      expect(store.ideas.single.archived, isTrue);

      await store.deleteIdea(Idea.fromJson(copy.toJson()));
      expect(store.ideas, isEmpty);
    });

    test('cachedOnDeviceStatus expires unavailable/needsDownload and available after TTL', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final store = IdeaStore(secrets: _MemorySecrets(), now: () => now);

      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.needsDownload),
      );
      expect(store.cachedOnDeviceStatus?.status, OnDeviceStatus.needsDownload);

      now = now.add(IdeaStore.onDeviceCacheTtl);
      expect(store.cachedOnDeviceStatus, isNull);

      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.available),
      );
      now = now.add(const Duration(minutes: 4));
      expect(store.cachedOnDeviceStatus?.status, OnDeviceStatus.available);
      now = now.add(const Duration(minutes: 1));
      expect(store.cachedOnDeviceStatus, isNull);
    });
  });

  group('OnDeviceBackend & GeminiBackend & ResilientBackend', () {
    test('OnDeviceBackend cancels active FlutterOnDeviceClient on overlap', () async {
      final session1Cancelled = Completer<void>();
      var callCount = 0;
      final ai = _StubFlutterDeviceAi(() {
        callCount++;
        final current = callCount;
        return _StubSession(
          onCountTokens: (_) async => 10,
          onAsk: (_) async {
            if (current == 1) {
              await session1Cancelled.future;
            }
            return '{"id":"q2","text":"新しい質問","choices":["A","B","C"]}';
          },
        );
      });
      final client = FlutterOnDeviceClient(ai: ai);
      final backend = OnDeviceBackend(client: client);
      final idea = Idea(
        id: '1',
        title: 'テスト',
        createdAt: DateTime(2026),
      );

      final first = expectLater(
        backend.nextQuestion(idea: idea, history: const []),
        throwsA(isA<AiCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      final second = await backend.nextQuestion(idea: idea, history: const []);
      expect(second.id, 'q2');
      session1Cancelled.complete();
      await first;
    });

    test('FlutterOnDeviceClient rune fallback avoids false inputTooLong for Japanese', () async {
      final ai = _StubFlutterDeviceAi(
        () => _StubSession(
          onCountTokens: (_) async => throw const OnDeviceAiException(
            'count failed',
            code: 'error',
          ),
          onAsk: (_) async =>
              '{"id":"q1","text":"日本語の質問","choices":["A","B","C"]}',
        ),
      );
      final backend = OnDeviceBackend(client: FlutterOnDeviceClient(ai: ai));
      // 1500 Japanese chars (~4500 UTF-8 bytes > 3400, but 1800 estimated tokens <= 3400).
      final idea = Idea(
        id: '1',
        title: 'あ' * 1500,
        createdAt: DateTime(2026),
      );
      final q = await backend.nextQuestion(idea: idea, history: const []);
      expect(q.id, 'q1');
    });

    test('GeminiBackend classifies 400 errors and SocketException', () async {
      final bad400 = GeminiBackend(
        apiKey: 'key',
        client: MockClient((_) async => http.Response('<html>Bad</html>', 400)),
      );
      await expectLater(
        bad400.verifyConnection(),
        throwsA(GeminiFailure.invalidResponse),
      );

      final precondition = GeminiBackend(
        apiKey: 'key',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'status': 'FAILED_PRECONDITION',
                'message': 'User location is not supported',
              },
            }),
            400,
          ),
        ),
      );
      await expectLater(
        precondition.verifyConnection(),
        throwsA(GeminiFailure.unavailable),
      );

      final badModel = GeminiBackend(
        apiKey: 'key',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'status': 'INVALID_ARGUMENT',
                'message': 'Invalid model name',
              },
            }),
            400,
          ),
        ),
      );
      await expectLater(
        badModel.verifyConnection(),
        throwsA(GeminiFailure.invalidModel),
      );

      final badKey = GeminiBackend(
        apiKey: 'key',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'details': [
                  {'reason': 'API_KEY_INVALID'},
                ],
              },
            }),
            400,
          ),
        ),
      );
      await expectLater(
        badKey.verifyConnection(),
        throwsA(GeminiFailure.invalidKey),
      );

      final sock = GeminiBackend(
        apiKey: 'key',
        client: MockClient(
          (_) async => throw const SocketException('unreachable'),
        ),
      );
      await expectLater(
        sock.verifyConnection(),
        throwsA(GeminiFailure.network),
      );
    });

    test('ResilientBackend cancelled _resolve does not clobber subsequent run', () async {
      final device = _SlowOnDeviceClient();
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(client: device),
      );
      final idea = Idea(id: '1', title: 'テスト', createdAt: DateTime(2026));

      final first = expectLater(
        backend.nextQuestion(idea: idea, history: const []),
        throwsA(isA<AiCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);

      final second = await backend.nextQuestion(
        idea: idea,
        history: const [],
        templateOnly: true,
      );
      expect(second.source, AnswerSource.local);

      // Complete the cancelled first call with an error; it must not overwrite lastSource/lastOnDeviceFailed.
      device.statusCompleter.completeError(Exception('late failure'));
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastOnDeviceFailed, isFalse);
      expect(backend.lastManualTemplate, isTrue);
    });

    test('LocalBackend.nextQuestion avoids extra\$n ID collisions', () async {
      final base = [
        for (final q in FallbackQuestions.questions)
          QaEntry(questionId: q.id, question: 'q', answer: 'a'),
        for (final q in FallbackQuestions.deepeningQuestions)
          QaEntry(questionId: q.id, question: 'q', answer: 'a'),
      ];
      final collidingId = 'extra${base.length + 2}';
      final idea = Idea(
        id: '1',
        title: 'テスト',
        createdAt: DateTime(2026),
        sessions: [
          DigSession(
            id: 's1',
            startedAt: DateTime(2026),
            finished: true,
            answers: [
              ...base,
              QaEntry(questionId: collidingId, question: 'q', answer: 'a'),
            ],
          ),
        ],
      );
      final q = await LocalBackend().nextQuestion(
        idea: idea,
        history: const [],
      );
      expect(q.id, 'extra${base.length + 3}');
    });
  });
}
