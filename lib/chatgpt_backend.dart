import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show Listenable;
import 'package:http/http.dart' as http;

import 'ai_backend.dart';
import 'chatgpt_auth_service.dart';
import 'dig_mode.dart';
import 'first_dig.dart';
import 'models.dart';
import 'prompts.dart';

/// ChatGPT バックエンドの失敗。理由は診断表示に使うため保持する。
class ChatGptException implements Exception {
  final String message;
  final bool revoked;
  ChatGptException(this.message, {this.revoked = false});
  @override
  String toString() => message;
}

/// 「Sign in with ChatGPT」で取得した本人のトークンを使い、ChatGPT（Codex）
/// バックエンドの Responses API で生成する [AiBackend] 実装。
///
/// 非公式な Codex 向けエンドポイントのため、OpenAI 側の仕様変更で
/// 動かなくなる可能性がある。プロンプトと JSON パースは他バックエンドと
/// 共通の [Prompts] を使い、実装の型は [OnDeviceBackend] と揃える。
/// 設計は ProfileMaker の ChatGPT 実装と同一方式（v0.4.0）。
class ChatGptBackend implements GuidedDigBackend {
  final ChatGptAuthService _auth;
  final http.Client? _client;
  http.Client? _ownedClient;
  final Listenable? consentChanges;
  final bool Function()? maySend;
  int _revision = 0;
  Completer<void>? _activeRequest;

  ChatGptBackend({
    ChatGptAuthService? authService,
    http.Client? client,
    this.consentChanges,
    this.maySend,
  }) : _auth = authService ?? ChatGptAuthService(),
       // ignore: prefer_initializing_formals
       _client = client;

  static const String endpoint =
      'https://chatgpt.com/backend-api/codex/responses';
  static const String model = 'gpt-5-codex';
  static const Duration generateTimeout = Duration(seconds: 25);

  /// 直近の失敗理由（診断表示用）。
  String? lastError;

  @override
  bool get isRemote => true;

  /// Responses API の応答 JSON から生成テキストを取り出す（テスト可能）。
  static String extractOutputText(Map<String, dynamic> responseJson) {
    final buffer = StringBuffer();
    final output = responseJson['output'];
    if (output is List) {
      for (final item in output) {
        if (item is! Map || item['type'] != 'message') continue;
        final content = item['content'];
        if (content is! List) continue;
        for (final part in content) {
          if (part is Map && part['type'] == 'output_text') {
            final text = part['text'];
            if (text is String) buffer.write(text);
          }
        }
      }
    }
    if (buffer.isEmpty) {
      final topLevel = responseJson['output_text'];
      if (topLevel is String) buffer.write(topLevel);
    }
    return buffer.toString();
  }

  void cancelPending() {
    _revision++;
    final request = _activeRequest;
    if (request != null && !request.isCompleted) request.complete();
  }

  void dispose() {
    cancelPending();
    _ownedClient?.close();
    _ownedClient = null;
  }

  void _checkCurrent(int revision) {
    if (revision != _revision) throw const AiCancelled();
    if (maySend?.call() == false) {
      throw ChatGptException('ChatGPTへの送信を停止しました。', revoked: true);
    }
  }

  Future<String> _generate(String prompt, int revision) async {
    Completer<void>? abort;
    void Function()? stopListener;
    try {
      _checkCurrent(revision);
      final token = await _auth.getValidAccessToken();
      _checkCurrent(revision);
      if (token == null) {
        throw ChatGptException(
          'ChatGPTにサインインしていません。設定画面からサインインしてください。',
        );
      }
      final accountId = await _auth.getAccountId();
      _checkCurrent(revision);

      final localAbort = Completer<void>();
      abort = localAbort;
      void stop() {
        if (!localAbort.isCompleted) localAbort.complete();
      }
      stopListener = stop;

      _activeRequest = localAbort;
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse(endpoint),
              abortTrigger: localAbort.future,
            )
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Content-Type'] = 'application/json; charset=utf-8';
      if (accountId != null && accountId.isNotEmpty) {
        request.headers['chatgpt-account-id'] = accountId;
      }
      request.body = jsonEncode({
        'model': model,
        // プロンプトは単体で完結する設計（Prompts）のため instructions は付けない。
        'input': [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': prompt},
            ],
          },
        ],
        'stream': false,
      });

      final client = _client ?? (_ownedClient ??= http.Client());
      consentChanges?.addListener(stop);
      final res = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(generateTimeout);

      if (revision != _revision) throw const AiCancelled();
      if (localAbort.isCompleted || maySend?.call() == false) {
        throw ChatGptException('ChatGPTへの送信を停止しました。', revoked: true);
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw ChatGptException(
          'ChatGPTの認証が切れています。設定画面からサインインし直してください。',
        );
      }
      if (res.statusCode == 429) {
        throw ChatGptException(
          'ChatGPTの利用上限に達しました。少し待って再試行してください。',
        );
      }
      if (res.statusCode >= 500) {
        throw ChatGptException(
          'ChatGPTで一時的な障害が発生しています。少し待って再試行してください。',
        );
      }
      if (res.statusCode != 200) {
        throw ChatGptException(
          'ChatGPTでの生成に失敗しました（ステータス: ${res.statusCode}）。少し待って再試行してください。',
        );
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw ChatGptException(
          'ChatGPTの応答形式が正しくありませんでした。もう一度お試しください。',
        );
      }
      final text = extractOutputText(decoded);
      if (text.trim().isEmpty) {
        throw ChatGptException('ChatGPTから応答が返りませんでした。もう一度お試しください。');
      }
      return text;
    } on AiCancelled {
      rethrow;
    } on http.RequestAbortedException {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException('ChatGPTへの送信を停止しました。', revoked: true);
      lastError = err.message;
      throw err;
    } on TimeoutException {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException(
        'ChatGPTから時間内に応答がありませんでした。少し待って再試行してください。',
      );
      lastError = err.message;
      throw err;
    } on http.ClientException {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException(
        'ChatGPTに接続できませんでした。通信状況を確認してください。',
      );
      lastError = err.message;
      throw err;
    } on SocketException {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException(
        'ChatGPTに接続できませんでした。通信状況を確認してください。',
      );
      lastError = err.message;
      throw err;
    } on FormatException {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException(
        'ChatGPTから使える形式の応答が返りませんでした。もう一度お試しください。',
      );
      lastError = err.message;
      throw err;
    } on ChatGptException catch (e) {
      if (revision != _revision) throw const AiCancelled();
      lastError = e.message;
      rethrow;
    } catch (_) {
      if (revision != _revision) throw const AiCancelled();
      final err = ChatGptException(
        'ChatGPTでの生成に失敗しました。少し待って再試行してください。',
      );
      lastError = err.message;
      throw err;
    } finally {
      if (stopListener != null) {
        consentChanges?.removeListener(stopListener);
      }
      if (abort != null && !abort.isCompleted) {
        abort.complete();
      }
      if (abort != null && identical(_activeRequest, abort)) {
        _activeRequest = null;
      }
    }
  }

  /// パース失敗時のみ1回だけ生成し直す（他バックエンドと同じ方針）。
  Future<T> _generateParsed<T>(
    String prompt,
    T? Function(String text) parse,
    String what,
  ) async {
    final revision = ++_revision;
    lastError = null;
    for (var attempt = 1; attempt <= 2; attempt++) {
      final text = await _generate(prompt, revision);
      final parsed = parse(text);
      if (parsed != null) return parsed;
    }
    const msg = 'ChatGPTから使える形式の応答が返りませんでした。もう一度お試しください。';
    lastError = msg;
    throw ChatGptException(msg);
  }

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
      );
      return _generateParsed(
        input.prompt,
        (text) => Prompts.parseFirstDigQuestion(
          text,
          context: firstDig,
          anchorSource: input.anchorSource,
        style: style,
        ),
        'question',
      );
    }
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
    bool reviewDraft = false,
  }) async {
    final note = idea.note;
    return _generateParsed(
      Prompts.summarize(
        title: idea.title,
        note: note,
        history: history,
        latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
        style: style,
        reviewDraft: reviewDraft,
      ),
      (text) => Prompts.parseMemo(
        text,
        version: version,
        reviewDraft: reviewDraft,
        history: history,
        note: note,
      ),
      'memo',
    );
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) async {
    if (idea.memos.isEmpty) {
      const msg = '企画メモがまだありません。';
      lastError = msg;
      throw ChatGptException(msg);
    }
    return _generateParsed(
      Prompts.nameCandidates(title: idea.title, memo: idea.memos.last),
      (text) {
        final list = Prompts.parseNameCandidates(text);
        return list.length >= 3 ? list : null;
      },
      'name candidates',
    );
  }
}
