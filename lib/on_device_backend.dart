import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_device_ai/flutter_device_ai.dart';
import 'package:flutter_device_ai/flutter_device_ai_platform_interface.dart';

import 'ai_backend.dart';
import 'dig_mode.dart';
import 'first_dig.dart';
import 'models.dart';
import 'prompts.dart';

String get onDeviceModelName => defaultTargetPlatform == TargetPlatform.iOS
    ? 'Apple Intelligence'
    : 'Gemini Nano';

String get onDeviceServiceName => defaultTargetPlatform == TargetPlatform.iOS
    ? 'Apple Intelligence'
    : 'AICore';

bool get _usesNativeSchemas =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

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

class OnDeviceCheck {
  final OnDeviceStatus status;
  final String message;
  const OnDeviceCheck(this.status, [this.message = '']);
}

abstract class OnDeviceTextClient {
  Future<OnDeviceCheck> checkStatus();
  Future<void> downloadModel();
  Future<String> generate(String prompt);
}

class FlutterOnDeviceClient implements OnDeviceTextClient {
  final FlutterDeviceAi _ai;
  final bool _useCustomAi;
  final void Function(double?)? onDownloadProgress;
  StreamIterator<ModelDownloadStatus>? _download;
  Future<void> Function()? _closeActiveSession;
  int _revision = 0;

  FlutterOnDeviceClient({FlutterDeviceAi? ai, this.onDownloadProgress})
    : _ai = ai ?? FlutterDeviceAi.withFallback(),
      _useCustomAi = ai != null;

  void _checkCurrent(int revision) {
    if (revision != _revision) throw const AiCancelled();
  }

  @override
  Future<OnDeviceCheck> checkStatus() async {
    final availability = await _ai.availability();
    final isIosNotReady =
        defaultTargetPlatform == TargetPlatform.iOS &&
        (availability.status == ModelFeatureStatus.downloadable ||
            availability.status == ModelFeatureStatus.downloading);
    final status = switch (availability.status) {
      ModelFeatureStatus.available => OnDeviceStatus.available,
      ModelFeatureStatus.downloadable || ModelFeatureStatus.downloading =>
        isIosNotReady
            ? OnDeviceStatus.unavailable
            : OnDeviceStatus.needsDownload,
      ModelFeatureStatus.unavailable
          when availability.reason == AvailabilityReason.unknown =>
        OnDeviceStatus.checkFailed,
      ModelFeatureStatus.unavailable => OnDeviceStatus.unavailable,
    };
    final message = isIosNotReady
        ? 'Apple Intelligence の準備が完了していない可能性があります。端末の設定を確認してください。'
        : availability.message;
    return OnDeviceCheck(status, message);
  }

  @override
  Future<void> downloadModel() async {
    final revision = _revision;
    final iterator = StreamIterator(_ai.downloadModel());
    _download = iterator;
    try {
      while (await iterator.moveNext()) {
        _checkCurrent(revision);
        final event = iterator.current;
        if (event.status == ModelFeatureStatus.available) return;
        if (event.status == ModelFeatureStatus.unavailable) {
          throw const OnDeviceException('モデルを取得できませんでした。');
        }
        onDownloadProgress?.call(event.progress?.clamp(0.0, 1.0));
      }
      _checkCurrent(revision);
      if ((await checkStatus()).status != OnDeviceStatus.available) {
        throw const OnDeviceException('モデルの取得が完了しませんでした。');
      }
      _checkCurrent(revision);
    } finally {
      if (identical(_download, iterator)) _download = null;
      await iterator.cancel();
      if (revision == _revision) onDownloadProgress?.call(null);
    }
  }

  @override
  Future<String> generate(
    String prompt, {
    Map<String, Object>? schema,
    bool bypassAvailabilityCheck = false,
  }) async {
    final revision = _revision;
    // 専用のシステム指示はNano V3以降で使える。指示はテキストに含める。
    final useSchema = schema != null && _usesNativeSchemas;
    final config = GenerationConfig(
      maxTokens: 512,
      temperature: 0.3,
      responseFormat: useSchema ? ResponseFormat.json : ResponseFormat.text,
      schema: useSchema ? schema : null,
      maxRepairAttempts: 0,
    );
    if (bypassAvailabilityCheck && !_useCustomAi) {
      return _generateBypassingAvailability(revision, prompt, config);
    }
    final session = await _ai.createSession(config: config);
    Future<void> closeSession() => session.close();
    try {
      _checkCurrent(revision);
      _closeActiveSession = closeSession;
      final tokens = await _countTokens(session, prompt);
      _checkCurrent(revision);
      if (tokens > 3400) throw const _OnDeviceInputTooLong();
      final response = await session.ask(prompt);
      _checkCurrent(revision);
      return response.text;
    } finally {
      if (identical(_closeActiveSession, closeSession)) {
        _closeActiveSession = null;
      }
      await _release(closeSession());
    }
  }

  Future<String> _generateBypassingAvailability(
    int revision,
    String prompt,
    GenerationConfig config,
  ) async {
    final platform = FlutterDeviceAiPlatform.instance;
    final sessionId = await platform.createSession(config: config);
    Future<void> closeSession() => platform.sessionClose(sessionId);
    try {
      _checkCurrent(revision);
      _closeActiveSession = closeSession;
      final tokens = await _countTokensWith(
        () => platform.sessionCountTokens(sessionId, text: prompt),
        prompt,
      );
      _checkCurrent(revision);
      if (tokens > 3400) throw const _OnDeviceInputTooLong();
      await platform.sessionAddQuery(sessionId, prompt);
      _checkCurrent(revision);
      final response = await platform.sessionGetResponse(
        sessionId,
        config: config,
      );
      _checkCurrent(revision);
      return response.text;
    } finally {
      if (identical(_closeActiveSession, closeSession)) {
        _closeActiveSession = null;
      }
      await _release(closeSession());
    }
  }

  static int _estimateTokens(String prompt) =>
      (prompt.runes.length * 1.2).ceil();

  Future<int> _countTokens(OnDeviceAiSession session, String prompt) =>
      _countTokensWith(() => session.countTokens(text: prompt), prompt);

  Future<int> _countTokensWith(
    Future<int> Function() count,
    String prompt,
  ) async {
    final estimated = _estimateTokens(prompt);
    try {
      final nativeCount = await count().timeout(const Duration(seconds: 2));
      if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        return nativeCount > estimated ? nativeCount : estimated;
      }
      return nativeCount;
    } on OnDeviceAiException {
      return estimated;
    } on TimeoutException {
      return estimated;
    }
  }

  void cancelPending() {
    _revision++;
    final download = _download;
    final closeSession = _closeActiveSession;
    _download = null;
    _closeActiveSession = null;
    if (download != null) unawaited(_release(download.cancel()));
    if (closeSession != null) unawaited(_release(closeSession()));
  }

  Future<void> _release(Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      // ネイティブ側の切断後も処理の取り消しは維持する。
    }
  }
}

class OnDeviceException implements Exception {
  final String message;
  const OnDeviceException(this.message);

  @override
  String toString() => message;
}

class _OnDeviceInputTooLong implements Exception {
  const _OnDeviceInputTooLong();
}

class OnDeviceBackend implements GuidedDigBackend {
  final OnDeviceTextClient _client;
  final Duration statusTimeout;
  final Duration downloadTimeout;
  final Duration generateTimeout;
  final OnDeviceCheck? Function()? readCachedStatus;
  final void Function(OnDeviceCheck)? writeCachedStatus;
  final void Function()? clearCachedStatus;
  int _revision = 0;

  String? lastError;
  OnDeviceStatus? lastStatus;
  OnDeviceLifecycle lifecycle = OnDeviceLifecycle.idle;

  OnDeviceBackend({
    OnDeviceTextClient? client,
    void Function(double?)? onDownloadProgress,
    this.readCachedStatus,
    this.writeCachedStatus,
    this.clearCachedStatus,
    this.statusTimeout = const Duration(seconds: 6),
    this.downloadTimeout = const Duration(seconds: 120),
    this.generateTimeout = const Duration(seconds: 18),
  }) : _client =
           client ??
           FlutterOnDeviceClient(onDownloadProgress: onDownloadProgress);

  @override
  bool get isRemote => false;

  void _checkCurrent(int revision) {
    if (revision != _revision) throw const AiCancelled();
  }

  void _cancelClient() {
    final client = _client;
    if (client is FlutterOnDeviceClient) client.cancelPending();
  }

  String _describeAiError(Object error, {required String fallback}) {
    if (error is OnDeviceAiUnavailableException) {
      return '$onDeviceModelNameは現在利用できません。';
    }
    if (error is OnDeviceAiUnsupportedException) {
      return 'この端末では$onDeviceModelNameを利用できません。';
    }
    if (error is OnDeviceAiSessionBusyException) {
      return '$onDeviceModelNameが別の処理を実行中です。少し待ってからもう一度お試しください。';
    }
    if (error is OnDeviceAiCancelledException) {
      return '$onDeviceModelNameの処理を中断しました。';
    }
    if (error is OnDeviceAiGenerationException ||
        error is OnDeviceAiStructuredOutputException ||
        error is OnDeviceAiSchemaException) {
      return '$onDeviceModelNameから応答を取得できませんでした。';
    }
    return fallback;
  }

  Future<void> _prepare(
    int revision, {
    required bool allowDownload,
    bool probeOnCheckFailed = false,
  }) async {
    lifecycle = OnDeviceLifecycle.checking;
    final OnDeviceCheck check;
    final cached = allowDownload ? null : readCachedStatus?.call();
    if (cached != null &&
        (cached.status == OnDeviceStatus.unavailable ||
            cached.status == OnDeviceStatus.needsDownload)) {
      check = cached;
    } else {
      try {
        check = await _client.checkStatus().timeout(statusTimeout);
      } catch (_) {
        if (revision == _revision) clearCachedStatus?.call();
        rethrow;
      }
      _checkCurrent(revision);
      writeCachedStatus?.call(check);
    }
    lastStatus = check.status;
    switch (check.status) {
      case OnDeviceStatus.available:
        break;
      case OnDeviceStatus.needsDownload:
        lifecycle = OnDeviceLifecycle.downloadable;
        if (!allowDownload) {
          throw const OnDeviceException('設定で端末AIのモデルを準備してください。');
        }
        lifecycle = OnDeviceLifecycle.downloading;
        await _client.downloadModel().timeout(downloadTimeout);
        _checkCurrent(revision);
        lastStatus = OnDeviceStatus.available;
        writeCachedStatus?.call(const OnDeviceCheck(OnDeviceStatus.available));
      case OnDeviceStatus.checkFailed:
        // 状態確認（ML Kit の checkStatus）だけが失敗し、生成そのものは
        // 通る端末がある（Pixel 10 Pro で実測: checkStatus が
        // 「Could not query AICore: null」を返す一方、別パッケージの
        // 検証版では生成が成功した。docs/ONDEVICE_POC.md 参照）。
        // プラグインの生成経路は availability() を挟まないプラットフォーム層で
        // 実際に生成を1回試して結果で判定する（probe）。
        if (!probeOnCheckFailed) {
          lifecycle = OnDeviceLifecycle.unavailable;
          throw OnDeviceException(
            '$onDeviceServiceNameの状態を確認できませんでした。'
            '状態が取れなくても生成できる場合があるため、'
            '設定の「質問を試す」ボタンで実際に生成できるか確認してください。'
            '${check.message.isEmpty ? '' : '（${check.message}）'}',
          );
        }
        break;
      case OnDeviceStatus.unavailable:
        lifecycle = OnDeviceLifecycle.unavailable;
        throw OnDeviceException(
          check.message.isEmpty ? '端末AIは現在利用できません。' : check.message,
        );
    }
    lifecycle = OnDeviceLifecycle.ready;
  }

  Future<OnDeviceCheck> diagnose() async {
    try {
      final result = await _client.checkStatus().timeout(statusTimeout);
      lastStatus = result.status;
      writeCachedStatus?.call(result);
      return result;
    } on TimeoutException {
      lastStatus = OnDeviceStatus.checkFailed;
      clearCachedStatus?.call();
      return OnDeviceCheck(
        OnDeviceStatus.checkFailed,
        '$onDeviceServiceNameから時間内に応答がありませんでした。',
      );
    } catch (_) {
      lastStatus = OnDeviceStatus.checkFailed;
      clearCachedStatus?.call();
      return OnDeviceCheck(
        OnDeviceStatus.checkFailed,
        '$onDeviceServiceNameの状態を確認できませんでした。',
      );
    }
  }

  /// 生成テストを伴わない単独のモデル準備（R-04）。
  Future<OnDeviceCheck> prepareModel() async {
    final revision = ++_revision;
    _cancelClient();
    lastError = null;
    try {
      await _prepare(revision, allowDownload: true);
      return const OnDeviceCheck(OnDeviceStatus.available);
    } on TimeoutException {
      _checkCurrent(revision);
      final phase = lifecycle;
      cancelPending();
      lifecycle = OnDeviceLifecycle.timedOut;
      lastError = switch (phase) {
        OnDeviceLifecycle.checking => '$onDeviceServiceNameから時間内に応答がありませんでした。',
        OnDeviceLifecycle.downloading => '時間内にモデルを取得できませんでした。',
        _ => '端末AIから時間内に応答がありませんでした。',
      };
      throw OnDeviceException(lastError!);
    } on AiCancelled {
      rethrow;
    } catch (error) {
      _checkCurrent(revision);
      final failure = error is OnDeviceException
          ? error
          : OnDeviceException(
              _describeAiError(error, fallback: '端末AIの準備に失敗しました。'),
            );
      lastError = failure.message;
      throw failure;
    }
  }

  Future<DigQuestion> verifyGeneration() => _nextQuestion(
    idea: Idea(
      id: 'nano-check',
      title: '近所の散歩コースを記録するアプリ',
      createdAt: DateTime.now(),
    ),
    history: const [],
    allowDownload: true,
  );

  void cancelPending() {
    _revision++;
    lifecycle = OnDeviceLifecycle.cancelled;
    _cancelClient();
  }

  Future<T> _generateParsed<T>(
    String Function(int budget) prompt,
    T? Function(String text, int budget) parse, {
    bool allowDownload = false,
    Map<String, Object> Function(int budget)? schema,
  }) async {
    final revision = ++_revision;
    _cancelClient();
    lastError = null;
    try {
      await _prepare(
        revision,
        allowDownload: allowDownload,
        probeOnCheckFailed: true,
      );
      final value = await _tryOutput(
        revision,
        prompt,
        parse,
        schema,
        bypassAvailabilityCheck: lastStatus == OnDeviceStatus.checkFailed,
      ).timeout(generateTimeout);
      if (lastStatus == OnDeviceStatus.checkFailed) {
        // 状態確認は失敗したが生成は通った。生成の成功が事実として
        // 確定なので、状態は「利用可」に昇格させてキャッシュする。
        lastStatus = OnDeviceStatus.available;
        writeCachedStatus?.call(const OnDeviceCheck(OnDeviceStatus.available));
      }
      return value;
    } on TimeoutException {
      _checkCurrent(revision);
      final phase = lifecycle;
      cancelPending();
      lifecycle = OnDeviceLifecycle.timedOut;
      lastError = switch (phase) {
        OnDeviceLifecycle.checking => '$onDeviceServiceNameから時間内に応答がありませんでした。',
        OnDeviceLifecycle.downloading => '時間内にモデルを取得できませんでした。',
        _ => '$onDeviceModelNameから時間内に応答がありませんでした。',
      };
      throw OnDeviceException(lastError!);
    } on AiCancelled {
      rethrow;
    } catch (error) {
      _checkCurrent(revision);
      final failure = error is OnDeviceException
          ? error
          : OnDeviceException(
              _describeAiError(
                error,
                fallback: '$onDeviceModelNameの処理に失敗しました。',
              ),
            );
      lastError = failure.message;
      throw failure;
    }
  }

  Future<T> _tryOutput<T>(
    int revision,
    String Function(int budget) prompt,
    T? Function(String text, int budget) parse,
    Map<String, Object> Function(int budget)? schema, {
    bool bypassAvailabilityCheck = false,
  }) async {
    var budget = Prompts.nanoBudget;
    var inputTooLong = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      _checkCurrent(revision);
      inputTooLong = false;
      try {
        final client = _client;
        final input = prompt(budget);
        final text = client is FlutterOnDeviceClient
            ? await client.generate(
                input,
                schema: schema?.call(budget),
                bypassAvailabilityCheck: bypassAvailabilityCheck,
              )
            : await client.generate(input);
        _checkCurrent(revision);
        final value = parse(text, budget);
        if (value != null) return value;
      } on _OnDeviceInputTooLong {
        inputTooLong = true;
        budget = Prompts.compactNanoBudget;
      } on OnDeviceAiStructuredOutputException {
        // SDKの補修を使わず、既存の生成回数上限でやり直す。
      }
    }
    if (inputTooLong) {
      throw OnDeviceException('入力が長すぎるため$onDeviceModelNameで処理できませんでした。');
    }
    throw OnDeviceException('$onDeviceModelNameから使える形式の応答が返りませんでした。');
  }

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    FirstDigContext? firstDig,
  }) {
    if (firstDig != null) {
      final title = idea.title;
      final note = idea.note;
      final context = firstDig;
      ({String prompt, String anchorSource, Map<String, Object> schema})
      input(int budget) => Prompts.firstDigQuestion(
        title: title,
        note: note,
        context: context,
        style: style,
        viewpoint: viewpoint,
        budget: budget,
        structuredOutput: _usesNativeSchemas,
      );
      return _generateParsed(
        (budget) => input(budget).prompt,
        (text, budget) => Prompts.parseFirstDigQuestion(
          text,
          context: context,
          anchorSource: input(budget).anchorSource,
          style: style,
        ),
        schema: (budget) => input(budget).schema,
      );
    }
    return _nextQuestion(
      idea: idea,
      history: history,
      style: style,
      viewpoint: viewpoint,
      contrarianDue: contrarianDue,
    );
  }

  Future<DigQuestion> _nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    bool allowDownload = false,
  }) async {
    final question = await _generateParsed(
      (budget) => Prompts.nextQuestion(
        title: idea.title,
        note: idea.note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        viewpoint: viewpoint,
        contrarian: contrarianDue,
        budget: budget,
      ),
      (text, _) => Prompts.parseQuestion(text),
      allowDownload: allowDownload,
    );
    return contrarianDue ? question.copyWith(isContrarian: true) : question;
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool reviewDraft = false,
  }) {
    final note = idea.note;
    return _generateParsed(
      (budget) => Prompts.summarize(
        title: idea.title,
        note: note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        budget: budget,
        reviewDraft: reviewDraft,
        structuredOutput: _usesNativeSchemas,
      ),
      (text, budget) => Prompts.parseMemo(
        text,
        version: version,
        reviewDraft: reviewDraft,
        history: history,
        budget: budget,
        note: note,
      ),
      schema: reviewDraft ? (_) => Prompts.reviewMemoSchema : null,
    );
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) {
    if (idea.memos.isEmpty) throw const OnDeviceException('企画メモがありません。');
    return _generateParsed(
      (budget) => Prompts.nameCandidates(
        title: idea.title,
        memo: idea.memos.last,
        budget: budget,
      ),
      (text, _) {
        final names = Prompts.parseNameCandidates(text);
        return names.length == 3 ? names : null;
      },
      schema: (_) => Prompts.nameCandidatesSchema,
    );
  }
}
