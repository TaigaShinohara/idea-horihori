import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show Listenable;
import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'dig_mode.dart';
import 'chatgpt_backend.dart';
import 'on_device_backend.dart';
import 'fallback.dart';
import 'first_dig.dart';
import 'models.dart';
import 'name_candidates.dart';
import 'prompts.dart';
import 'session_logic.dart';

/// 応答がどこから来たか（K1: モード開示のために画面へ伝える）。
/// 本体は models.dart（v0.4.0 で chatGpt を追加）。
export 'models.dart' show AnswerSource;

class AiCancelled implements Exception {
  const AiCancelled();
}

enum AiPhase { onDevice, cloud }

enum GeminiFailure implements Exception {
  invalidKey('APIキーが拒否されました。Google AI Studioでキーとアクセス権を確認してください。'),
  invalidModel('このモデルを利用できません。モデル名と利用権を確認してください。'),
  quota('利用上限に達しました。時間を置くか、Google AI Studioで利用枠を確認してください。'),
  network('Geminiに接続できませんでした。通信状況を確認してください。'),
  timeout('Geminiから時間内に応答がありませんでした。'),
  unavailable('Geminiで一時的な障害が発生しています。少し待って再試行してください。'),
  invalidResponse('Geminiからこの機能で使える応答が返りませんでした。'),
  revoked('クラウド送信を停止しました。');

  const GeminiFailure(this.message);
  final String message;
}

/// AIバックエンドの抽象化。v1の既定は Gemini、差し替え口だけ用意する。
/// v0.2: 掘り方スタイル／視点／逆張り指定と、名前候補の取得口を追加。
abstract class AiBackend {
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
  });
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
  });

  /// 名前候補を必ず3件返す（項目6）。
  Future<List<String>> nameCandidates({required Idea idea});
  bool get isRemote;
}

/// 初回の質問と確認用の下書きに対応する生成経路。
abstract interface class GuidedDigBackend implements AiBackend {
  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    FirstDigContext? firstDig,
  });

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool reviewDraft = false,
  });
}

/// Gemini REST (generateContent) 実装。キーはログに出さない。
class GeminiBackend implements GuidedDigBackend {
  final String apiKey;
  final String model;
  final http.Client? _client;
  http.Client? _ownedClient;
  final Listenable? consentChanges;
  final bool Function()? maySend;
  final Duration timeout;
  Completer<void>? _activeRequest;

  GeminiBackend({
    required this.apiKey,
    String? model,
    this._client,
    this.consentChanges,
    this.maySend,
    this.timeout = const Duration(seconds: 12),
  }) : model = AppConfig.geminiModel(model);

  @override
  bool get isRemote => true;

  void cancelPending() {
    final request = _activeRequest;
    if (request != null && !request.isCompleted) request.complete();
  }

  void dispose() {
    cancelPending();
    _ownedClient?.close();
    _ownedClient = null;
  }

  Future<Map<String, dynamic>> _request({Map<String, Object>? body}) async {
    if (apiKey.trim().isEmpty) throw GeminiFailure.invalidKey;
    if (!AppConfig.validGeminiModel(model)) throw GeminiFailure.invalidModel;
    if (maySend?.call() == false) throw GeminiFailure.revoked;

    cancelPending();
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    _activeRequest = abort;
    final request =
        http.AbortableRequest(
            body == null ? 'GET' : 'POST',
            Uri.parse(
              '${AppConfig.geminiEndpoint}/$model'
              '${body == null ? '' : ':generateContent'}',
            ),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['x-goog-api-key'] = apiKey.trim();
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final client = _client ?? (_ownedClient ??= http.Client());
    consentChanges?.addListener(stop);
    try {
      final res = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      if (abort.isCompleted || maySend?.call() == false) {
        throw GeminiFailure.revoked;
      }
      switch (res.statusCode) {
        case 200:
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is Map<String, dynamic>) return decoded;
          throw GeminiFailure.invalidResponse;
        case 401 || 403:
          throw GeminiFailure.invalidKey;
        case 400:
          try {
            final error = jsonDecode(utf8.decode(res.bodyBytes));
            final details = error is Map ? error['error'] : null;
            final items = details is Map ? details['details'] : null;
            if (items is List &&
                items.whereType<Map>().any(
                  (e) => e['reason'] == 'API_KEY_INVALID',
                )) {
              throw GeminiFailure.invalidKey;
            }
          } on FormatException {
            // 非JSONの400応答はモデル/リクエスト不正として扱う。
          }
          throw GeminiFailure.invalidModel;
        case 404:
          throw GeminiFailure.invalidModel;
        case 429:
          throw GeminiFailure.quota;
        case >= 500:
          throw GeminiFailure.unavailable;
        default:
          throw GeminiFailure.invalidResponse;
      }
    } on TimeoutException {
      throw GeminiFailure.timeout;
    } on http.RequestAbortedException {
      throw GeminiFailure.revoked;
    } on http.ClientException {
      throw GeminiFailure.network;
    } on SocketException {
      throw GeminiFailure.network;
    } on FormatException {
      throw GeminiFailure.invalidResponse;
    } finally {
      consentChanges?.removeListener(stop);
      stop();
      if (identical(_activeRequest, abort)) _activeRequest = null;
    }
  }

  /// キーとモデルを検査する。アイデアの内容や生成リクエストは送らない。
  Future<void> verifyConnection() async {
    final modelInfo = await _request();
    final methods = modelInfo['supportedGenerationMethods'];
    if (methods is! List || !methods.contains('generateContent')) {
      throw GeminiFailure.invalidModel;
    }
  }

  Future<String> _generate(String prompt, Map<String, Object> schema) async {
    final decoded = await _request(
      body: {
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.5,
          'maxOutputTokens': 2048,
          'responseMimeType': 'application/json',
          'responseJsonSchema': schema,
        },
      },
    );
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      throw GeminiFailure.invalidResponse;
    }
    final candidate = candidates.first as Map;
    if (candidate['finishReason'] != null &&
        candidate['finishReason'] != 'STOP') {
      throw GeminiFailure.invalidResponse;
    }
    final content = candidate['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) throw GeminiFailure.invalidResponse;
    final text = parts
        .whereType<Map>()
        .where((part) => part['thought'] != true)
        .map((part) => part['text'])
        .whereType<String>()
        .join();
    if (text.trim().isEmpty) throw GeminiFailure.invalidResponse;
    return text;
  }

  static const _text = {'type': 'string'};
  static const _choices = {
    'type': 'array',
    'items': _text,
    'minItems': 3,
    'maxItems': 3,
  };
  static const _score = {'type': 'integer', 'minimum': 1, 'maximum': 3};
  static const _questionSchema = {
    'type': 'object',
    'properties': {'id': _text, 'text': _text, 'choices': _choices},
    'required': ['id', 'text', 'choices'],
  };
  static const _memoSchema = {
    'type': 'object',
    'properties': {
      'what': _text,
      'who': _text,
      'why': _text,
      'how': _text,
      'nextStep': _text,
      'ease': _score,
      'spark': _score,
    },
    'required': ['what', 'who', 'why', 'how', 'nextStep', 'ease', 'spark'],
  };
  static const _namesSchema = {
    'type': 'object',
    'properties': {'candidates': _choices},
    'required': ['candidates'],
  };

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    FirstDigContext? firstDig,
  }) async {
    if (firstDig != null) {
      final input = Prompts.firstDigQuestion(
        title: idea.title,
        note: idea.note,
        context: firstDig,
        style: style,
        viewpoint: viewpoint,
        structuredOutput: true,
      );
      final text = await _generate(input.prompt, input.schema);
      final question = Prompts.parseFirstDigQuestion(
        text,
        context: firstDig,
        anchorSource: input.anchorSource,
        style: style,
      );
      if (question == null) throw GeminiFailure.invalidResponse;
      return question;
    }
    final text = await _generate(
      Prompts.nextQuestion(
        title: idea.title,
        note: idea.note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        viewpoint: viewpoint,
        contrarian: contrarianDue,
      ),
      _questionSchema,
    );
    final q = Prompts.parseQuestion(text);
    if (q == null) throw GeminiFailure.invalidResponse;
    // 逆張りとして出させた質問には印を付けて返す（取り消し時の復元用）。
    return contrarianDue ? q.copyWith(isContrarian: true) : q;
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool reviewDraft = false,
  }) async {
    final note = idea.note;
    final text = await _generate(
      Prompts.summarize(
        title: idea.title,
        note: note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        reviewDraft: reviewDraft,
        structuredOutput: true,
      ),
      reviewDraft ? Prompts.reviewMemoSchema : _memoSchema,
    );
    final memo = Prompts.parseMemo(
      text,
      version: version,
      reviewDraft: reviewDraft,
      history: history,
      note: note,
    );
    if (memo == null) throw GeminiFailure.invalidResponse;
    return memo;
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) async {
    if (idea.memos.isEmpty) throw GeminiFailure.invalidResponse;
    final text = await _generate(
      Prompts.nameCandidates(title: idea.title, memo: idea.memos.last),
      _namesSchema,
    );
    final names = Prompts.parseNameCandidates(text);
    if (names.length < 3) throw GeminiFailure.invalidResponse;
    return names;
  }
}

/// ローカルフォールバック実装（キー未設定／オフライン／API失敗時）。
/// 定型質問＋ローカル整形で、ネットなしでも深掘りが完結する。
class LocalBackend implements GuidedDigBackend {
  @override
  bool get isRemote => false;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    FirstDigContext? firstDig,
  }) async {
    if (firstDig != null) {
      return FallbackQuestions.firstDig(firstDig, style, viewpoint);
    }
    final priorRound = hasCompletedPriorRound(idea);
    final allAskedIds = <String>{
      for (final s in idea.sessions)
        for (final a in s.answers) a.questionId,
      for (final a in history) a.questionId,
    };

    // R-01: 定型モード1周目は基本5スロット完走を優先し、逆張りは2周目以降に発火する。
    if (priorRound && contrarianDue && !history.any((a) => a.contrarian)) {
      return FallbackQuestions.styled(
        FallbackQuestions.contrarianQuestion,
        style,
      );
    }

    // R-03: 視点が明示選択されている場合、その視点の未出題質問を出題する。
    if (viewpoint != DigViewpoint.none) {
      final pool = FallbackQuestions.viewpointQuestions[viewpoint] ?? const [];
      for (final q in pool) {
        if (!allAskedIds.contains(q.id)) {
          return FallbackQuestions.styled(q, style);
        }
      }
    }

    // 基本5問のうち未出題のものを順に出す（2周目以降は過去セッションも既出とみなす）。
    final basicAskedIds = priorRound
        ? allAskedIds
        : history.map((a) => a.questionId).toSet();
    for (final q in FallbackQuestions.questions) {
      if (!basicAskedIds.contains(q.id)) {
        return FallbackQuestions.styled(q, style);
      }
    }

    // 2周目以降で基本5問をすべて回答済みなら、2周目用の深掘り質問を出す（ループ防止）。
    if (priorRound) {
      for (final q in FallbackQuestions.deepeningQuestions) {
        if (!allAskedIds.contains(q.id)) {
          return FallbackQuestions.styled(q, style);
        }
      }
    }

    // 定型を使い切ったら汎用の広げ質問を出す。
    var n = (priorRound ? allAskedIds.length : history.length) + 1;
    while (allAskedIds.contains('extra$n')) {
      n++;
    }
    return FallbackQuestions.styled(
      DigQuestion(
        id: 'extra$n',
        text: '「${idea.title}」で、まだ決まっていない大事なことは？',
        choices: ['使う場面をもっと具体的に', '一番の売りを決める', '似たものとの違いを決める'],
      ),
      style,
    );
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool reviewDraft = false,
  }) async {
    return LocalMemoBuilder.build(
      title: idea.title,
      note: idea.note,
      answers: history,
      version: version,
      reviewDraft: reviewDraft,
    );
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) async {
    return LocalNameCandidates.generate(
      title: idea.title,
      memo: idea.memos.isEmpty ? null : idea.memos.last,
    );
  }
}

/// リモート優先・失敗時はローカルに倒す合成バックエンド。
///
/// K1（v0.1.2）: 失敗を無言で吸収せず、直近の応答元と失敗有無を
/// [lastSource] / [lastRemoteFailed] として公開する。画面側はセッション中
/// 同じインスタンスを保持し、呼び出しのたびにこの値でモード表示を更新する。
class ResilientBackend implements GuidedDigBackend {
  final AiBackend? _fixedRemote;
  final AiBackend? Function()? remoteFactory;
  AiBackend? get remote =>
      remoteFactory == null ? _fixedRemote : remoteFactory!();

  /// v0.3.0 PoC: オンデバイスAI。最優先で試し、失敗したら次へ倒す。
  final AiBackend? onDevice;

  /// v0.4.0: ChatGPT（サインイン済みのときだけ非 null）。オンデバイスの次。
  final AiBackend? chatGpt;
  final LocalBackend local = LocalBackend();
  ResilientBackend(
    this._fixedRemote, {
    this.onDevice,
    this.chatGpt,
    this.remoteFactory,
  });

  void Function(AiPhase)? onPhase;
  Completer<void>? _active;
  GeminiBackend? _activeRemote;
  ChatGptBackend? _activeChatGpt;

  /// 直近の呼び出し（質問・まとめ共通）の応答元。未呼び出しなら null。
  AnswerSource? lastSource;

  /// 直近の呼び出しでリモートが失敗しローカルへ倒れたか。
  /// キー未設定で最初からローカルの場合は false。
  bool lastRemoteFailed = false;
  GeminiFailure? lastRemoteError;

  /// 直近の呼び出しでオンデバイスが失敗し次へ倒れたか（v0.3.0 PoC）。
  bool lastOnDeviceFailed = false;

  /// 直近のオンデバイス失敗の理由（診断表示用、v0.3.1）。
  String? lastOnDeviceError;

  /// 直近の呼び出しで ChatGPT が失敗し次へ倒れたか（v0.4.0）。
  bool lastChatGptFailed = false;

  /// 直近の ChatGPT 失敗の理由（診断表示用、v0.4.0）。
  String? lastChatGptError;

  /// 直近の呼び出しがユーザー手動の「定型で続ける」だったか（R-04）。
  bool lastManualTemplate = false;

  /// 直近のオンデバイス状態（R-04）。
  OnDeviceStatus? get lastOnDeviceStatus => onDevice is OnDeviceBackend
      ? (onDevice as OnDeviceBackend).lastStatus
      : null;

  /// 定型モードに落ちた理由（R-04）。AI応答時は null。
  FallbackReason? fallbackReason({
    required bool hasRemoteKey,
    required bool remoteConsent,
  }) => fallbackReasonFor(
    isLocalSource: lastSource == AnswerSource.local,
    hasRemoteKey: hasRemoteKey,
    remoteConsent: remoteConsent,
    // v0.4.0: ChatGPT の失敗も「クラウドAIに接続できなかった」に含める。
    lastRemoteFailed: lastRemoteFailed || lastChatGptFailed,
    onDeviceNeedsDownload: lastOnDeviceStatus == OnDeviceStatus.needsDownload,
    manualTemplate: lastManualTemplate,
  );

  void cancelPending() {
    final active = _active;
    if (active == null || active.isCompleted) return;
    active.complete();
    _activeRemote?.cancelPending();
    _activeChatGpt?.cancelPending();
    _activeChatGpt = null;
    final candidate = onDevice;
    if (candidate is OnDeviceBackend) {
      candidate.cancelPending();
    }
  }

  void dispose() {
    cancelPending();
    final fixed = _fixedRemote;
    if (fixed is GeminiBackend) fixed.dispose();
  }

  /// 現在のモード表示（DigScreen のバッジ用）。
  DigModeKind get currentModeKind {
    final s = lastSource;
    if (s == AnswerSource.onDevice) return DigModeKind.onDevice;
    if (s == AnswerSource.chatGpt) return DigModeKind.chatGpt;
    if (s == AnswerSource.remote) return DigModeKind.ai;
    if (s == AnswerSource.local &&
        (lastOnDeviceFailed || lastChatGptFailed || lastRemoteFailed)) {
      return DigModeKind.templateFailed;
    }
    if (s == AnswerSource.local) return DigModeKind.templateNoKey;
    // 未呼び出し: 最優先の候補を表示する。
    if (onDevice != null) return DigModeKind.onDevice;
    if (chatGpt != null) return DigModeKind.chatGpt;
    if (remote != null) return DigModeKind.ai;
    return DigModeKind.templateNoKey;
  }

  /// 候補を優先順（オンデバイス→ChatGPT→Gemini→ローカル）で試す共通処理。
  Future<(T, AnswerSource)> _run<T>(
    Future<T> Function(AiBackend backend) op,
    Future<T> Function() localOp, {
    bool templateOnly = false,
  }) async {
    cancelPending();
    final active = Completer<void>();
    _active = active;
    try {
      return await Future.any([
        _resolve(op, localOp, active, templateOnly),
        active.future.then<(T, AnswerSource)>((_) => throw const AiCancelled()),
      ]);
    } finally {
      if (identical(_active, active)) _active = null;
    }
  }

  Future<(T, AnswerSource)> _resolve<T>(
    Future<T> Function(AiBackend backend) op,
    Future<T> Function() localOp,
    Completer<void> active,
    bool templateOnly,
  ) async {
    void checkCancelled() {
      if (!identical(_active, active) || active.isCompleted) {
        throw const AiCancelled();
      }
    }

    var onDeviceFailed = false;
    String? onDeviceError;
    var remoteFailed = false;
    GeminiFailure? remoteError;

    (T, AnswerSource) commit(T result, AnswerSource source) {
      checkCancelled();
      lastOnDeviceFailed = onDeviceFailed;
      lastOnDeviceError = onDeviceError;
      lastRemoteFailed = remoteFailed;
      lastRemoteError = remoteError;
      lastManualTemplate = templateOnly;
      lastSource = source;
      return (result, source);
    }

    // 呼び出し開始時に前回の失敗状態をリセットする（ChatGPT 分岐は commit() を
    // 通らず直接フィールドを書くため、ここでの初期化が要る）。
    lastOnDeviceFailed = false;
    lastChatGptFailed = false;
    lastRemoteFailed = false;
    lastRemoteError = null;
    lastOnDeviceError = null;
    lastManualTemplate = templateOnly;
    if (!templateOnly && onDevice != null) {
      checkCancelled();
      onPhase?.call(AiPhase.onDevice);
      try {
        checkCancelled();
        final r = await op(onDevice!);
        return commit(r, AnswerSource.onDevice);
      } catch (e) {
        checkCancelled();
        onDeviceFailed = true;
        final od = onDevice;
        onDeviceError = od is OnDeviceBackend
            ? (od.lastError ?? e.toString())
            : e.toString();
      }
    }
    // v0.4.0: 第2候補は ChatGPT（サインイン済みのときだけ非 null）。
    // Gemini と同じクラウド扱いで、フェーズ通知・キャンセル規約に合わせる。
    final cg = chatGpt;
    if (!templateOnly && cg != null) {
      onPhase?.call(AiPhase.cloud);
      try {
        checkCancelled();
        if (cg is ChatGptBackend) _activeChatGpt = cg;
        final r = await op(cg);
        final result = commit(r, AnswerSource.chatGpt);
        lastChatGptError = null;
        return result;
      } catch (e) {
        checkCancelled();
        lastChatGptFailed = true;
        lastChatGptError = cg is ChatGptBackend
            ? (cg.lastError ?? e.toString())
            : e.toString();
      } finally {
        if (identical(_active, active)) _activeChatGpt = null;
      }
    }
    checkCancelled();
    final cloud = templateOnly ? null : remote;
    if (cloud != null) {
      checkCancelled();
      onPhase?.call(AiPhase.cloud);
      try {
        checkCancelled();
        if (cloud is GeminiBackend) _activeRemote = cloud;
        final r = await op(cloud);
        return commit(r, AnswerSource.remote);
      } catch (error) {
        checkCancelled();
        remoteFailed = error != GeminiFailure.revoked;
        if (error is GeminiFailure && remoteFailed) remoteError = error;
      } finally {
        if (identical(_activeRemote, cloud)) _activeRemote = null;
        if (remoteFactory != null && cloud is GeminiBackend) {
          cloud.dispose();
        }
      }
    }
    final result = await localOp();
    return commit(result, AnswerSource.local);
  }

  @override
  bool get isRemote => remote != null || chatGpt != null;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
    bool templateOnly = false,
    List<QaEntry>? templateHistory,
    FirstDigContext? firstDig,
  }) async {
    final (question, source) = await _run(
      (b) {
        if (b is GuidedDigBackend) {
          return b.nextQuestion(
            idea: idea,
            history: history,
            style: style,
            viewpoint: viewpoint,
            contrarianDue: contrarianDue,
            firstDig: firstDig,
          );
        }
        return b.nextQuestion(
          idea: idea,
          history: history,
          style: style,
          viewpoint: viewpoint,
          contrarianDue: contrarianDue,
        );
      },
      () => local.nextQuestion(
        idea: idea,
        history: templateHistory ?? history,
        style: style,
        viewpoint: viewpoint,
        contrarianDue: contrarianDue,
        firstDig: firstDig,
      ),
      templateOnly: templateOnly,
    );
    return question.copyWith(source: source);
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
    bool templateOnly = false,
    bool reviewDraft = false,
  }) async {
    final (memo, source) = await _run(
      (b) {
        if (b is GuidedDigBackend) {
          return b.summarize(
            idea: idea,
            history: history,
            version: version,
            style: style,
            reviewDraft: reviewDraft,
          );
        }
        return b.summarize(
          idea: idea,
          history: history,
          version: version,
          style: style,
        );
      },
      () => local.summarize(
        idea: idea,
        history: history,
        version: version,
        style: style,
        reviewDraft: reviewDraft,
      ),
      templateOnly: templateOnly,
    );
    return memo.copyWith(source: source);
  }

  @override
  Future<List<String>> nameCandidates({
    required Idea idea,
    bool templateOnly = false,
  }) async {
    final (names, _) = await _run(
      (b) => b.nameCandidates(idea: idea),
      () => local.nameCandidates(idea: idea),
      templateOnly: templateOnly,
    );
    return names;
  }
}
