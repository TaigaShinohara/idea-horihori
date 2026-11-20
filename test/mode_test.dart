import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/ai_backend.dart';
import 'package:horihori/app_config.dart';
import 'package:horihori/dig_mode.dart';
import 'package:horihori/models.dart';
import 'package:horihori/store.dart';
import 'package:horihori/widgets/glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

Idea _idea() => Idea(
      id: '1',
      title: '天気で服を決めるアプリ',
      createdAt: DateTime(2026, 11, 20),
    );

/// テスト用の偽リモート。fail=true なら常に例外を投げる。
class _FakeRemote implements AiBackend {
  final bool fail;
  const _FakeRemote({this.fail = false});

  @override
  bool get isRemote => true;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
  }) async {
    if (fail) throw Exception('network down');
    return const DigQuestion(id: 'ai1', text: 'AIの質問', choices: ['a', 'b', 'c']);
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
  }) async {
    if (fail) throw Exception('network down');
    return PlanMemo(
      what: 'w',
      who: 'u',
      why: 'y',
      how: 'h',
      nextStep: 'n',
      createdAt: DateTime(2026, 11, 20),
      version: version,
    );
  }
}

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('K1 モード判定（digModeKind）', () {
    test('キーなしは定型（キー未設定）', () {
      expect(
        digModeKind(hasKey: false, remoteFailed: false),
        DigModeKind.templateNoKey,
      );
      expect(
        digModeKind(hasKey: false, remoteFailed: true),
        DigModeKind.templateNoKey,
      );
    });
    test('キーあり・失敗なしは AI', () {
      expect(
        digModeKind(hasKey: true, remoteFailed: false),
        DigModeKind.ai,
      );
      expect(DigModeKind.ai.label, 'AIで深掘り中');
      expect(DigModeKind.ai.isAi, isTrue);
    });
    test('キーあり・失敗ありは定型（失敗）', () {
      expect(
        digModeKind(hasKey: true, remoteFailed: true),
        DigModeKind.templateFailed,
      );
      expect(DigModeKind.templateFailed.isAi, isFalse);
    });
  });

  group('K1 応答元のトラッキング（ResilientBackend）', () {
    test('リモート成功時は remote が記録される', () async {
      final backend = ResilientBackend(const _FakeRemote());
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.id, 'ai1');
      expect(backend.lastSource, AnswerSource.remote);
      expect(backend.lastRemoteFailed, isFalse);
    });

    test('リモート失敗時はローカルへ倒れ、失敗が記録される', () async {
      final backend = ResilientBackend(const _FakeRemote(fail: true));
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      // ローカルの定型質問が返る
      expect(q.id, 'who');
      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastRemoteFailed, isTrue);
      // 画面のモード判定とつなげると templateFailed になる
      expect(
        digModeKind(hasKey: true, remoteFailed: backend.lastRemoteFailed),
        DigModeKind.templateFailed,
      );
    });

    test('キー未設定（remote なし）は失敗扱いにならない', () async {
      final backend = ResilientBackend(null);
      final q = await backend.nextQuestion(idea: _idea(), history: const []);
      expect(q.id, 'who');
      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastRemoteFailed, isFalse);
      expect(
        digModeKind(hasKey: false, remoteFailed: backend.lastRemoteFailed),
        DigModeKind.templateNoKey,
      );
    });

    test('まとめ失敗時もローカルへ倒れ、失敗が記録される', () async {
      final backend = ResilientBackend(const _FakeRemote(fail: true));
      final memo =
          await backend.summarize(idea: _idea(), history: const [], version: 1);
      expect(memo.version, 1);
      expect(backend.lastSource, AnswerSource.local);
      expect(backend.lastRemoteFailed, isTrue);
    });

    test('まとめ成功時は remote が記録される', () async {
      final backend = ResilientBackend(const _FakeRemote());
      final memo =
          await backend.summarize(idea: _idea(), history: const [], version: 2);
      expect(memo.what, 'w');
      expect(backend.lastSource, AnswerSource.remote);
      expect(backend.lastRemoteFailed, isFalse);
    });
  });

  group('K1/K3 1回だけ通知（OnceFlag）', () {
    test('最初だけ true、以後は false', () {
      final flag = OnceFlag();
      expect(flag.tryConsume(), isTrue);
      expect(flag.consumed, isTrue);
      expect(flag.tryConsume(), isFalse);
      expect(flag.tryConsume(), isFalse);
    });
    test('reset で再び true になる', () {
      final flag = OnceFlag();
      expect(flag.tryConsume(), isTrue);
      flag.reset();
      expect(flag.tryConsume(), isTrue);
    });
  });

  group('K3 初回案内フラグの永続化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('初期は false、markKeyGuideShown で true になり再読込でも保たれる',
        () async {
      final store = IdeaStore();
      await store.load();
      expect(store.keyGuideShown, isFalse);

      await store.markKeyGuideShown();
      expect(store.keyGuideShown, isTrue);

      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.keyGuideShown, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppConfig.prefsKeyGuideShownKey), isTrue);
    });
  });

  group('K6 成長ラベル', () {
    test('Semantics ラベルに段階名と成長度が入る', () {
      expect(growthSemanticsLabel(GrowthStage.seed, 0.12),
          contains('種'));
      expect(growthSemanticsLabel(GrowthStage.seed, 0.12),
          contains('12パーセント'));
      expect(growthSemanticsLabel(GrowthStage.fruit, 1.0),
          contains('実'));
      expect(growthSemanticsLabel(GrowthStage.sprout, 0.5),
          contains('芽'));
    });
    test('段階ラベルが種／芽／実で定義されている', () {
      expect(GrowthStage.seed.label, '種');
      expect(GrowthStage.sprout.label, '芽');
      expect(GrowthStage.fruit.label, '実');
    });
  });

  group('K7 コントラスト', () {
    test('主ボタンのベタ色は白文字で 4.5:1 以上', () {
      expect(_contrastRatio(Colors.white, kButtonFill),
          greaterThanOrEqualTo(4.5));
    });
    test('旧アクセント色は 4.5:1 未満（変更理由の確認）', () {
      expect(_contrastRatio(Colors.white, kAccent), lessThan(4.5));
    });
  });
}
