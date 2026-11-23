import 'dart:async';

import 'package:flutter_device_ai/flutter_device_ai.dart';

import 'ai_backend.dart';
import 'dig_mode.dart';
import 'models.dart';
import 'prompts.dart';

/// オンデバイスAI（Android: Gemini Nano / ML Kit GenAI Prompt API）の
/// 状態。プラグインの型をアプリ側の言葉に寄せたもの（テスト差し替え用）。
enum OnDeviceStatus { available, needsDownload, unavailable, checkFailed }

enum OnDeviceLifecycle {
  idle,
  checking,
  ready,
  downloadable,
  downloading,
  unavailable,
  timedOut,
  cancelled,
}

/// 状態確認の結果（プラグインが返す理由メッセージつき）。
class OnDeviceCheck {
  final OnDeviceStatus status;
  final String message;
  const OnDeviceCheck(this.status, [this.message = '']);
}

/// オンデバイスAIクライアントの抽象化（実機: [FlutterOnDeviceClient]、
/// テスト: Fake）。profileMaker PoC と同じ分離パターン。
abstract class OnDeviceTextClient {
  Future<OnDeviceCheck> checkStatus();

  /// モデルのダウンロード完了まで待つ。失敗・タイムアウトは例外。
  Future<void> downloadModel();

  Future<String> generate(String prompt);
}

/// flutter_device_ai の実クライアント。
class FlutterOnDeviceClient implements OnDeviceTextClient {
  final FlutterDeviceAi _ai;
  FlutterOnDeviceClient({FlutterDeviceAi? ai}) : _ai = ai ?? FlutterDeviceAi();

  @override
  Future<OnDeviceCheck> checkStatus() async {
    final a = await _ai.availability();
    final status = switch (a.status) {
      ModelFeatureStatus.available => OnDeviceStatus.available,
      ModelFeatureStatus.downloadable ||
      ModelFeatureStatus.downloading =>
        OnDeviceStatus.needsDownload,
      ModelFeatureStatus.unavailable when a.reason == AvailabilityReason.unknown =>
        OnDeviceStatus.checkFailed,
      ModelFeatureStatus.unavailable => OnDeviceStatus.unavailable,
    };
    return OnDeviceCheck(status, a.message);
  }

  @override
  Future<void> downloadModel() async {
    await for (final event in _ai.downloadModel()) {
      if (event.status == ModelFeatureStatus.available) return;
      if (event.status == ModelFeatureStatus.unavailable) {
        throw Exception(
            'on-device model download failed: ${event.errorMessage ?? ''}');
      }
    }
    if ((await checkStatus()).status == OnDeviceStatus.available) return;
    throw Exception('on-device model download ended unexpectedly');
  }

  @override
  Future<String> generate(String prompt) async {
    final res = await _ai.generateText(
      // プロンプト内に役割と出力形式がある。専用の systemInstruction は
      // Nano V3 以降でしか使えないため、ここでは指定しない。
      prompt: prompt,
      config: const GenerationConfig(maxTokens: 512, temperature: 0.3),
    );
    return res.text;
  }
}

/// オンデバイスAIが使えない／応答しない場合の例外。
/// 呼び出し側（ResilientBackend）が次の候補へ倒すために使う。
class OnDeviceException implements Exception {
  final String message;
  OnDeviceException(this.message);
  @override
  String toString() => 'OnDeviceException: $message';
}

/// オンデバイスAIバックエンド（v0.3.0 PoC）。
///
/// profileMaker PoC の教訓を最初から入れる:
/// - 全呼び出しにタイムアウト（実機で応答が返らず固まる事象への対策）。
///   固まったら例外にして、ResilientBackend が次の候補へ倒す。
/// - パース失敗時のみ1回再試行する。
/// - モデルのダウンロードが必要な端末では、初回だけ待ってから推論する。
class OnDeviceBackend implements AiBackend {
  final OnDeviceTextClient _client;
  final Duration statusTimeout;
  final Duration downloadTimeout;
  final Duration generateTimeout;

  Future<void>? _readyFuture;

  /// 直近の失敗理由（診断表示用）。成功したら消える。
  String? lastError;
  OnDeviceLifecycle lifecycle = OnDeviceLifecycle.idle;

  OnDeviceBackend({
    OnDeviceTextClient? client,
    this.statusTimeout = const Duration(seconds: 15),
    this.downloadTimeout = const Duration(seconds: 120),
    this.generateTimeout = const Duration(seconds: 60),
  }) : _client = client ?? FlutterOnDeviceClient();

  @override
  bool get isRemote => false;

  /// 利用可能になるまで（必要ならダウンロード含む）進める。結果は保持し、
  /// セッション中は再確認しない。失敗したら例外。
  Future<void> _ensureReady() {
    return _readyFuture ??= _prepare();
  }

  Future<void> _prepare() async {
    lifecycle = OnDeviceLifecycle.checking;
    try {
      final check = await _client.checkStatus().timeout(
            statusTimeout,
            onTimeout: () =>
                throw OnDeviceException('status check timed out'),
          );
      lastError = null;
      switch (check.status) {
        case OnDeviceStatus.available:
          lifecycle = OnDeviceLifecycle.ready;
          lastError = null;
          return;
        case OnDeviceStatus.needsDownload:
          lifecycle = OnDeviceLifecycle.downloading;
          await _client.downloadModel().timeout(
                downloadTimeout,
                onTimeout: () {
                  lifecycle = OnDeviceLifecycle.timedOut;
                  throw OnDeviceException('model download timed out');
                },
              );
          lifecycle = OnDeviceLifecycle.ready;
          lastError = null;
          return;
        case OnDeviceStatus.unavailable:
        case OnDeviceStatus.checkFailed:
          lifecycle = OnDeviceLifecycle.unavailable;
          throw OnDeviceException(check.message.isEmpty
              ? 'on-device AI unavailable on this device'
              : 'on-device AI unavailable: ${check.message}');
      }
    } catch (e) {
      // 失敗を保持すると再試行できなくなるので、次回呼び出しでやり直せる
      // ようにキャッシュを捨てる。
      _readyFuture = null;
      lastError = e.toString();
      if (e is OnDeviceException &&
          (e.message.contains('timed out') ||
              e.message.contains('timeout'))) {
        lifecycle = OnDeviceLifecycle.timedOut;
      } else {
        lifecycle = OnDeviceLifecycle.unavailable;
      }
      if (e is OnDeviceException) rethrow;
      throw OnDeviceException('on-device AI preparation failed: $e');
    }
  }

  /// 設定画面の診断用：状態と理由をそのまま返す（例外にしない）。
  Future<OnDeviceCheck> diagnose() async {
    try {
      return await _client.checkStatus().timeout(statusTimeout);
    } catch (e) {
      return OnDeviceCheck(OnDeviceStatus.checkFailed, e.toString());
    }
  }

  /// 実際の質問生成を、利用者のアイデアに触れず端末AIだけで確認する。
  Future<DigQuestion> verifyGeneration() => nextQuestion(
        idea: Idea(
          id: 'nano-check',
          title: '近所の散歩コースを記録するアプリ',
          createdAt: DateTime.now(),
        ),
        history: const [],
      );

  void cancelPending() {
    lifecycle = OnDeviceLifecycle.cancelled;
    _readyFuture = null;
  }

  Future<String> _generate(String prompt) async {
    await _ensureReady();
    try {
      final text = await _client.generate(prompt).timeout(
            generateTimeout,
            onTimeout: () => throw OnDeviceException('generation timed out'),
          );
      if (text.trim().isEmpty) throw OnDeviceException('empty response');
      return text;
    } on OnDeviceException catch (e) {
      lastError = e.toString();
      if (e.message.contains('timed out')) {
        lifecycle = OnDeviceLifecycle.timedOut;
      }
      rethrow;
    } catch (e) {
      lastError = 'generation failed: $e';
      throw OnDeviceException('generation failed: $e');
    }
  }

  /// パース失敗時のみ1回だけ生成し直す（profileMaker PoC と同じ型）。
  Future<T> _generateParsed<T>(
    String prompt,
    T? Function(String text) parse,
    String what,
  ) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      final text = await _generate(prompt);
      final parsed = parse(text);
      if (parsed != null) return parsed;
    }
    throw OnDeviceException('unparsable $what (after retry)');
  }

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
  }) async {
    final q = await _generateParsed(
      Prompts.nextQuestion(
        title: idea.title,
        note: idea.note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        viewpoint: viewpoint,
        contrarian: contrarianDue,
      ),
      Prompts.parseQuestion,
      'question',
    );
    return contrarianDue ? q.copyWith(isContrarian: true) : q;
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
  }) async {
    return _generateParsed(
      Prompts.summarize(
        title: idea.title,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
      ),
      (text) => Prompts.parseMemo(text, version: version),
      'memo',
    );
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) async {
    if (idea.memos.isEmpty) throw OnDeviceException('no memo');
    final names = await _generateParsed(
      Prompts.nameCandidates(title: idea.title, memo: idea.memos.last),
      (text) {
        final list = Prompts.parseNameCandidates(text);
        return list.length >= 3 ? list : null;
      },
      'name candidates',
    );
    return names;
  }
}
