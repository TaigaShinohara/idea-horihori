import 'package:flutter/foundation.dart';
import 'package:flutter_device_ai/flutter_device_ai.dart';
import 'package:flutter_device_ai/flutter_device_ai_platform_interface.dart';
import 'package:flutter_device_ai/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/first_dig.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/prompts.dart';

/// テスト用のオンデバイスAIクライアント。
class FakeOnDeviceClient implements OnDeviceTextClient {
  OnDeviceStatus status;
  String message;
  List<String> responses;
  Duration statusDelay;
  Duration downloadDelay;
  Duration generateDelay;
  Object? statusError;
  Object? downloadError;
  Object? generateError;

  /// 先に消費される生成エラーのキュー（「1回だけ失敗して回復」の再現用）。
  List<Object> generateErrorQueue;
  int checkStatusCalls = 0;
  int generateCalls = 0;
  int downloadCalls = 0;

  FakeOnDeviceClient({
    this.status = OnDeviceStatus.available,
    this.message = '',
    List<String>? responses,
    this.statusDelay = Duration.zero,
    this.downloadDelay = Duration.zero,
    this.generateDelay = Duration.zero,
    this.statusError,
    this.downloadError,
    this.generateError,
    List<Object>? generateErrorQueue,
  }) : responses = responses ?? [],
       generateErrorQueue = generateErrorQueue ?? [];

  @override
  Future<OnDeviceCheck> checkStatus() async {
    checkStatusCalls++;
    if (statusDelay > Duration.zero) {
      await Future<void>.delayed(statusDelay);
    }
    if (statusError != null) throw statusError!;
    return OnDeviceCheck(status, message);
  }

  @override
  Future<void> downloadModel() async {
    downloadCalls++;
    if (downloadDelay > Duration.zero) {
      await Future<void>.delayed(downloadDelay);
    }
    if (downloadError != null) throw downloadError!;
    status = OnDeviceStatus.available;
  }

  @override
  Future<String> generate(String prompt) async {
    generateCalls++;
    if (generateDelay > Duration.zero) {
      await Future<void>.delayed(generateDelay);
    }
    if (generateErrorQueue.isNotEmpty) throw generateErrorQueue.removeAt(0);
    if (generateError != null) throw generateError!;
    if (responses.isEmpty) throw Exception('no fake response');
    return responses.removeAt(0);
  }
}

class _CapturingPlatform extends FakeOnDeviceAiPlatform {
  _CapturingPlatform({
    super.responder,
    super.availability,
    this.fixedTokenCount,
  });

  final int? fixedTokenCount;
  GenerationConfig? lastCreateConfig;

  @override
  Future<String> createSession({
    String? systemInstruction,
    List<OnDeviceAiTool>? tools,
    GenerationConfig? config,
  }) {
    lastCreateConfig = config;
    return super.createSession(
      systemInstruction: systemInstruction,
      tools: tools,
      config: config,
    );
  }

  @override
  Future<int> sessionCountTokens(String sessionId, {String? text}) async {
    if (fixedTokenCount != null) return fixedTokenCount!;
    return super.sessionCountTokens(sessionId, text: text);
  }
}

Idea _idea() => Idea(
      id: 'i1',
      title: '散歩メモアプリ',
      note: '',
      createdAt: DateTime(2026, 11, 22),
    );

const _qJson =
    '{"id":"q1","text":"誰に使ってほしい？","choices":["自分","家族","みんな"]}';
const _memoJson =
    '{"what":"散歩を記録するアプリ","who":"散歩好き","why":"記録が続かない",'
    '"how":"1タップで残す","nextStep":"画面を1枚作る","ease":2,"spark":3}';

void main() {
  group('OnDeviceBackend', () {
    test('質問JSONを解釈できる', () async {
      final b = OnDeviceBackend(
          client: FakeOnDeviceClient(responses: [_qJson]));
      final q = await b.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(q.choices.length, 3);
    });

    test('パース失敗時は1回だけ再試行する', () async {
      final client = FakeOnDeviceClient(responses: ['ごめん分からない', _qJson]);
      final b = OnDeviceBackend(client: client);
      final q = await b.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(client.generateCalls, 2);
    });

    test('サンプル質問はモデルを準備し、JSONの型違いでも再試行する', () async {
      final client = FakeOnDeviceClient(
        status: OnDeviceStatus.needsDownload,
        responses: ['{"text":42,"choices":["A","B","C"]}', _qJson],
      );
      final backend = OnDeviceBackend(client: client);

      final question = await backend.verifyGeneration();

      expect(client.downloadCalls, 1);
      expect(client.generateCalls, 2);
      expect(question.text, '誰に使ってほしい？');
    });

    test('パース失敗が続いたら例外（フォールバック可能にする）', () async {
      final b = OnDeviceBackend(
          client: FakeOnDeviceClient(responses: ['x', 'y']));
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
    });

    test('まとめJSONを解釈できる（体力測定つき）', () async {
      final b = OnDeviceBackend(
          client: FakeOnDeviceClient(responses: [_memoJson]));
      final memo = await b.summarize(idea: _idea(), history: const [], version: 1);
      expect(memo.what, '散歩を記録するアプリ');
      expect(memo.ease, 2);
      expect(memo.spark, 3);
    });

    test('通常の深掘りはモデル取得で待たず、設定からなら準備できる', () async {
      final client = FakeOnDeviceClient(
        status: OnDeviceStatus.needsDownload,
        responses: [_qJson],
      );
      final b = OnDeviceBackend(client: client);
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
      expect(client.downloadCalls, 0);
      final q = await b.verifyGeneration();
      expect(q.text, '誰に使ってほしい？');
      expect(client.downloadCalls, 1);
    });

    test('状態確認が取れなくても生成を試し、成功すれば利用可に昇格する', () async {
      final client = FakeOnDeviceClient(
        status: OnDeviceStatus.checkFailed,
        message: 'Could not query AICore: null',
        responses: [_qJson],
      );
      final b = OnDeviceBackend(client: client);
      final q = await b.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(client.generateCalls, 1);
      expect(b.lastStatus, OnDeviceStatus.available);
    });

    test('状態確認が取れず生成も失敗すれば例外（フォールバック可能にする）', () async {
      final b = OnDeviceBackend(
        client: FakeOnDeviceClient(
          status: OnDeviceStatus.checkFailed,
          message: 'Could not query AICore: null',
          responses: ['x', 'y'],
        ),
      );
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
      expect(b.lastStatus, OnDeviceStatus.checkFailed);
    });

    test('状態確認が取れない端末では prepareModel は生成で確かめる案内を出す',
        () async {
      final b = OnDeviceBackend(
        client: FakeOnDeviceClient(
          status: OnDeviceStatus.checkFailed,
          message: 'Could not query AICore: null',
        ),
      );
      await expectLater(
        b.prepareModel(),
        throwsA(
          isA<OnDeviceException>().having(
            (e) => e.message,
            'message',
            contains('質問を試す'),
          ),
        ),
      );
    });

    test('利用不可の端末では例外', () async {
      final b = OnDeviceBackend(
          client: FakeOnDeviceClient(status: OnDeviceStatus.unavailable));
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
    });

    test('生成が固まったらタイムアウトで例外（固まり対策）', () async {
      final b = OnDeviceBackend(
        client: FakeOnDeviceClient(
          responses: [_qJson],
          generateDelay: const Duration(milliseconds: 500),
        ),
        generateTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
    });
  });

  group('生成エラーの詳細保全と再試行（v0.5.2）', () {
    test('生成のネイティブ例外は詳細に残り、ユーザー向け文面には露出しない', () async {
      final client = FakeOnDeviceClient(
        generateError: const OnDeviceAiGenerationException(
          'GenAI error 8: AICore internal failure',
        ),
      );
      final b = OnDeviceBackend(
        client: client,
        generationRetryDelay: Duration.zero,
      );
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(
          isA<OnDeviceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('GenAI error')),
          ),
        ),
      );
      // 初回＋再試行1回で打ち切り、それ以上は暴走しない。
      expect(client.generateCalls, 2);
      expect(b.lastError, isNot(contains('GenAI error')));
      expect(b.lastGenerationErrorDetail, contains('GENERATION_FAILED'));
      expect(
        b.lastGenerationErrorDetail,
        contains('GenAI error 8: AICore internal failure'),
      );
    });

    test('生成が1回失敗しても再試行で成功し、一時的な失敗は詳細に残る', () async {
      final client = FakeOnDeviceClient(
        generateErrorQueue: [
          const OnDeviceAiGenerationException('GenAI error 3: not ready'),
        ],
        responses: [_qJson],
      );
      final b = OnDeviceBackend(
        client: client,
        generationRetryDelay: Duration.zero,
      );
      final q = await b.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(client.generateCalls, 2);
      expect(b.lastGenerationErrorDetail, contains('GenAI error 3'));
    });

    test('再試行しても失敗すれば従来どおり次候補（定型）へ落ちる', () async {
      final client = FakeOnDeviceClient(
        generateError: const OnDeviceAiGenerationException(
          'GenAI error 8: AICore internal failure',
        ),
      );
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(
          client: client,
          generationRetryDelay: Duration.zero,
        ),
      );
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, isNotEmpty); // 定型質問が返る
      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastOnDeviceFailed, isTrue);
      expect(client.generateCalls, 2);
    });

    test('長いネイティブ message は詳細で切り詰められる', () async {
      final b = OnDeviceBackend(
        client: FakeOnDeviceClient(
          generateError: OnDeviceAiGenerationException('E' * 1000),
        ),
        generationRetryDelay: Duration.zero,
      );
      await expectLater(
        b.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
      final detail = b.lastGenerationErrorDetail;
      expect(detail, isNotNull);
      expect(detail, startsWith('GENERATION_FAILED: '));
      expect(detail!.length, 301); // 300字＋省略記号
      expect(detail, endsWith('…'));
    });
  });

  group('診断（v0.3.1）', () {
    test('diagnose は状態と理由をそのまま返す', () async {
      final b = OnDeviceBackend(
          client: FakeOnDeviceClient(
              status: OnDeviceStatus.unavailable,
              message: 'AICore is not available'));
      final check = await b.diagnose();
      expect(check.status, OnDeviceStatus.unavailable);
      expect(check.message, contains('AICore'));
    });

    test('利用不可の理由が lastError と チェーンの lastOnDeviceError に残る',
        () async {
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(
            client: FakeOnDeviceClient(
                status: OnDeviceStatus.unavailable,
                message: 'AICore is not available')),
      );
      await backend.nextQuestion(idea: _idea(), history: const []);
      expect(backend.lastOnDeviceFailed, isTrue);
      expect(backend.lastOnDeviceError, contains('AICore'));
    });
  });

  group('ResilientBackend の優先順（v0.3.0 PoC）', () {
    test('オンデバイス成功 → source=onDevice / モード=オンデバイス', () async {
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(
            client: FakeOnDeviceClient(responses: [_qJson])),
      );
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(backend.lastSource, AnswerSource.onDevice);
      expect(backend.lastOnDeviceFailed, isFalse);
      expect(backend.currentModeKind, DigModeKind.onDevice);
    });

    test('オンデバイス失敗 → 定型へ倒れ、失敗フラグとモードが残る', () async {
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(
            client:
                FakeOnDeviceClient(status: OnDeviceStatus.unavailable)),
      );
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, isNotEmpty); // 定型質問が返る
      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastOnDeviceFailed, isTrue);
      expect(backend.currentModeKind, DigModeKind.templateFailed);
    });

    test('未呼び出しの初期モードはオンデバイス（最優先候補）', () {
      final backend = ResilientBackend(
        null,
        onDevice: OnDeviceBackend(client: FakeOnDeviceClient()),
      );
      expect(backend.currentModeKind, DigModeKind.onDevice);
      expect(DigModeKind.onDevice.label, 'オンデバイスで深掘り中');
      expect(DigModeKind.onDevice.isAi, isTrue);
    });
  });

  group('モデル単独準備とキャッシュ（R-04）', () {
    test('prepareModel は生成テストなしでモデルを準備しキャッシュを更新する', () async {
      final client = FakeOnDeviceClient(status: OnDeviceStatus.needsDownload);
      OnDeviceCheck? cached;
      final backend = OnDeviceBackend(
        client: client,
        readCachedStatus: () => cached,
        writeCachedStatus: (s) => cached = s,
      );

      final result = await backend.prepareModel();
      expect(result.status, OnDeviceStatus.available);
      expect(client.downloadCalls, 1);
      expect(client.generateCalls, 0);
      expect(cached?.status, OnDeviceStatus.available);
    });

    test('非対応または未準備がキャッシュされていれば通常深掘りで checkStatus をスキップする', () async {
      final client = FakeOnDeviceClient(status: OnDeviceStatus.unavailable);
      OnDeviceCheck? cached = const OnDeviceCheck(OnDeviceStatus.unavailable);
      final backend = OnDeviceBackend(
        client: client,
        readCachedStatus: () => cached,
        writeCachedStatus: (s) => cached = s,
      );

      await expectLater(
        backend.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
      expect(client.checkStatusCalls, 0);
      expect(backend.lastStatus, OnDeviceStatus.unavailable);
    });
  });

  group('出力検査', () {
    test('過長テキストと制御文字は拒否し、プレーンテキスト前提でURLや150字質問は許容する（S-03）', () {
      final withUrl = Prompts.parseQuestion(
        '{"id":"q1","text":"参考例 https://example.com のような仕組みにしますか？","choices":["はい","いいえ"]}',
      );
      expect(withUrl, isNotNull);
      expect(withUrl!.text, contains('https://example.com'));

      final longOk = Prompts.parseQuestion(
        '{"id":"q1","text":"${'あ' * 150}","choices":["はい","いいえ"]}',
      );
      expect(longOk, isNotNull);

      expect(
        Prompts.parseQuestion(
          '{"id":"q1","text":"${'あ' * 201}","choices":["はい","いいえ"]}',
        ),
        isNull,
      );
      expect(
        Prompts.parseQuestion(
          '{"id":"q1","text":"テスト\u0000文字列","choices":["はい","いいえ"]}',
        ),
        isNull,
      );
    });

    test('未知フィールドは無視してメモ解釈し、欠落した必須欄は拒否する', () {
      final withExtra = Prompts.parseMemo(
        '{"what":"w","who":"u","why":"y","how":"h","nextStep":"n","unknown":true}',
        version: 1,
      );
      expect(withExtra, isNotNull);
      expect(withExtra!.what, 'w');
      expect(
        Prompts.parseMemo(
          '{"what":"w","who":"u","why":"y","how":"h"}',
          version: 1,
        ),
        isNull,
      );
    });

    test('キャンセル後はライフサイクルがcancelledになる', () {
      final b = OnDeviceBackend(
        client: FakeOnDeviceClient(responses: [_qJson]),
      );
      b.cancelPending();
      expect(b.lifecycle, OnDeviceLifecycle.cancelled);
    });

    test('Prompts._safeText は DEL・C1・Bidi 制御文字を拒否し、parseQuestion の id も検査する', () {
      for (final ch in ['\x7F', '\u0080', '\u009F', '\u061C', '\u200E', '\u200F', '\u202A', '\u202E', '\u2066', '\u2069']) {
        expect(
          Prompts.parseQuestion(
            '{"id":"q1","text":"テスト$ch文字列","choices":["はい","いいえ"]}',
          ),
          isNull,
          reason: 'codeUnit=0x${ch.codeUnitAt(0).toRadixString(16)}',
        );
      }
      // id の長さ64超過・制御文字を拒否
      expect(
        Prompts.parseQuestion(
          '{"id":"${'a' * 65}","text":"質問","choices":["はい","いいえ"]}',
        ),
        isNull,
      );
      expect(
        Prompts.parseQuestion(
          '{"id":"q1\u202E","text":"質問","choices":["はい","いいえ"]}',
        ),
        isNull,
      );
      expect(
        Prompts.parseQuestion(
          '{"id":"q1\\n2","text":"質問","choices":["はい","いいえ"]}',
        ),
        isNull,
      );
      // 空文字 id は既定値 ai に丸める
      final emptyId = Prompts.parseQuestion(
        '{"id":"  ","text":"質問","choices":["はい","いいえ"]}',
      );
      expect(emptyId?.id, 'ai');
    });

    test('parseFirstDigQuestion は choice を trim し、parseMemo(reviewDraft) は null を空文字として許容する', () {
      const ctx = FirstDigContext();
      final q = Prompts.parseFirstDigQuestion(
        '{"choice":"  scene  "}',
        context: ctx,
        anchorSource: '散歩メモ',
      );
      expect(q, isNotNull);

      final memo = Prompts.parseMemo(
        '{"what":null,"who":"none","why":null,"how":"none","openQuestions":null}',
        version: 1,
        reviewDraft: true,
        history: const [],
      );
      expect(memo, isNotNull);
      expect(memo!.what, '');
      expect(memo.why, '');
      expect(memo.openQuestions, '');

      final firstDigPrompt = Prompts.firstDigQuestion(
        title: '散歩メモ',
        note: '',
        context: ctx,
        structuredOutput: false,
      ).prompt;
      expect(firstDigPrompt, contains('{"choice":'));

      final reviewPrompt = Prompts.summarize(
        title: '散歩メモ',
        history: const [],
        reviewDraft: true,
        structuredOutput: false,
      );
      expect(reviewPrompt, contains('{"what":"何を作るか"'));
    });
  });

  group('プローブ・キャッシュ・タイムアウト・iOS補正・エラー丸め', () {
    late FlutterDeviceAiPlatform originalPlatform;

    setUp(() {
      originalPlatform = FlutterDeviceAiPlatform.instance;
    });

    tearDown(() {
      FlutterDeviceAiPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = null;
    });

    test('probeOnCheckFailed は availability 失敗時もプラットフォーム層で生成し available キャッシュへ昇格する', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _CapturingPlatform(
        availability: const OnDeviceAiAvailability(
          status: ModelFeatureStatus.unavailable,
          reason: AvailabilityReason.unknown,
          message: 'Could not query AICore: null',
        ),
        responder: (prompt, history) => _qJson,
      );
      FlutterDeviceAiPlatform.instance = platform;

      final written = <OnDeviceCheck>[];
      final backend = OnDeviceBackend(
        client: FlutterOnDeviceClient(),
        writeCachedStatus: written.add,
      );

      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.text, '誰に使ってほしい？');
      expect(backend.lastStatus, OnDeviceStatus.available);
      expect(written.last.status, OnDeviceStatus.available);
      expect(platform.sessions, isEmpty);
    });

    test('diagnose のタイムアウトと例外で clearCachedStatus が呼ばれ、生例外文字列を露出しない', () async {
      var cleared = 0;
      final timeoutBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          statusDelay: const Duration(milliseconds: 200),
        ),
        statusTimeout: const Duration(milliseconds: 50),
        clearCachedStatus: () => cleared++,
      );
      final timeoutCheck = await timeoutBackend.diagnose();
      expect(timeoutCheck.status, OnDeviceStatus.checkFailed);
      expect(cleared, 1);

      final errorBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          statusError: StateError('SECRET_INTERNAL_STACK_DETAIL'),
        ),
        clearCachedStatus: () => cleared++,
      );
      final errorCheck = await errorBackend.diagnose();
      expect(errorCheck.status, OnDeviceStatus.checkFailed);
      expect(errorCheck.message, isNot(contains('SECRET_INTERNAL_STACK_DETAIL')));
      expect(cleared, 2);
    });

    test('_prepare の checkStatus 失敗（タイムアウト/例外）で clearCachedStatus が呼ばれる', () async {
      var cleared = 0;
      final timeoutBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          statusDelay: const Duration(milliseconds: 200),
        ),
        statusTimeout: const Duration(milliseconds: 50),
        clearCachedStatus: () => cleared++,
      );
      await expectLater(
        timeoutBackend.nextQuestion(idea: _idea(), history: const []),
        throwsA(isA<OnDeviceException>()),
      );
      expect(timeoutBackend.lifecycle, OnDeviceLifecycle.timedOut);
      expect(cleared, 1);

      final errorBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          statusError: const OnDeviceAiGenerationException('RAW_NATIVE_ERR'),
        ),
        clearCachedStatus: () => cleared++,
      );
      await expectLater(
        errorBackend.prepareModel(),
        throwsA(
          isA<OnDeviceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('RAW_NATIVE_ERR')),
          ),
        ),
      );
      expect(cleared, 2);
    });

    test('downloadTimeout で timedOut になり、OnDeviceAiException.message をそのまま露出しない', () async {
      final dlTimeoutBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          status: OnDeviceStatus.needsDownload,
          downloadDelay: const Duration(milliseconds: 200),
        ),
        downloadTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        dlTimeoutBackend.prepareModel(),
        throwsA(isA<OnDeviceException>()),
      );
      expect(dlTimeoutBackend.lifecycle, OnDeviceLifecycle.timedOut);

      final genErrBackend = OnDeviceBackend(
        client: FakeOnDeviceClient(
          generateError: const OnDeviceAiGenerationException('NATIVE_JNI_CRASH'),
        ),
      );
      await expectLater(
        genErrBackend.nextQuestion(idea: _idea(), history: const []),
        throwsA(
          isA<OnDeviceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('NATIVE_JNI_CRASH')),
          ),
        ),
      );
    });

    test('iOS でトークン過小評価を補正し、downloadable は案内メッセージ付き unavailable になる', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final platform = _CapturingPlatform(
        availability: const OnDeviceAiAvailability(
          status: ModelFeatureStatus.downloadable,
          reason: AvailabilityReason.modelNotReady,
          message: 'Model assets not downloaded',
        ),
        fixedTokenCount: 100,
        responder: (prompt, history) => _qJson,
      );
      FlutterDeviceAiPlatform.instance = platform;

      final client = FlutterOnDeviceClient();
      final check = await client.checkStatus();
      expect(check.status, OnDeviceStatus.unavailable);
      expect(
        check.message,
        'Apple Intelligence の準備が完了していない可能性があります。端末の設定を確認してください。',
      );

      // ネイティブ countTokens が 100 を返しても、3000文字の日本語は
      // 推定 3600 > 3400 となり inputTooLong で拒否される。
      platform.availability = const OnDeviceAiAvailability(
        status: ModelFeatureStatus.available,
        reason: AvailabilityReason.ready,
        message: 'ready',
      );
      final backend = OnDeviceBackend(client: client);
      final longNote = 'あ' * 3000;
      await expectLater(
        client.generate(longNote),
        throwsA(isA<Exception>()),
      );

      // nameCandidates でも iOS ではネイティブスキーマが渡される
      platform.responder = (prompt, history) =>
          '{"candidates":["さんぽ","あるこ","みちメモ"]}';
      final ideaWithMemo = Idea(
        id: 'i1',
        title: '散歩メモアプリ',
        createdAt: DateTime(2026, 11, 22),
        memos: [
          PlanMemo(
            what: '散歩記録',
            who: '自分',
            why: '忘れる',
            how: '1タップ',
            nextStep: '試す',
            createdAt: DateTime(2026, 11, 22),
            version: 1,
          ),
        ],
      );
      final names = await backend.nameCandidates(idea: ideaWithMemo);
      expect(names, ['さんぽ', 'あるこ', 'みちメモ']);
      expect(platform.lastCreateConfig?.responseFormat, ResponseFormat.json);
      expect(platform.lastCreateConfig?.schema, Prompts.nameCandidatesSchema);
    });
  });
}
