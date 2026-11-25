import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/models.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/prompts.dart';

/// テスト用のオンデバイスAIクライアント。
class FakeOnDeviceClient implements OnDeviceTextClient {
  OnDeviceStatus status;
  String message;
  List<String> responses;
  Duration generateDelay;
  int checkStatusCalls = 0;
  int generateCalls = 0;
  int downloadCalls = 0;

  FakeOnDeviceClient({
    this.status = OnDeviceStatus.available,
    this.message = '',
    List<String>? responses,
    this.generateDelay = Duration.zero,
  }) : responses = responses ?? [];

  @override
  Future<OnDeviceCheck> checkStatus() async {
    checkStatusCalls++;
    return OnDeviceCheck(status, message);
  }

  @override
  Future<void> downloadModel() async {
    downloadCalls++;
    status = OnDeviceStatus.available;
  }

  @override
  Future<String> generate(String prompt) async {
    generateCalls++;
    if (generateDelay > Duration.zero) {
      await Future<void>.delayed(generateDelay);
    }
    if (responses.isEmpty) throw Exception('no fake response');
    return responses.removeAt(0);
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
  });
}
