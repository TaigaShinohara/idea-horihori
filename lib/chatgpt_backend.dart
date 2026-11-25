import 'dart:async';
import 'dart:convert';

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
  ChatGptException(this.message);
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
  final http.Client _client;
  final bool Function()? maySend;
  int _revision = 0;

  ChatGptBackend({
    ChatGptAuthService? authService,
    http.Client? client,
    this.maySend,
  }) : _auth = authService ?? ChatGptAuthService(),
       _client = client ?? http.Client();

  static const String endpoint =
      'https://chatgpt.com/backend-api/codex/responses';
  static const String model = 'gpt-5-codex';
  static const Duration generateTimeout = Duration(seconds: 90);

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

  void cancelPending() => _revision++;

  void _checkCurrent(int revision) {
    if (revision != _revision) throw const AiCancelled();
    if (maySend?.call() == false) {
      throw ChatGptException('ChatGPTへの送信を停止しました');
    }
  }

  Future<String> _generate(String prompt, int revision) async {
    try {
      _checkCurrent(revision);
      final token = await _auth.getValidAccessToken();
      _checkCurrent(revision);
      if (token == null) {
        throw ChatGptException('ChatGPTにサインインしていない');
      }
      final accountId = await _auth.getAccountId();
      _checkCurrent(revision);
      final res = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              if (accountId != null && accountId.isNotEmpty)
                'chatgpt-account-id': accountId,
            },
            body: jsonEncode({
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
            }),
          )
          .timeout(
            generateTimeout,
            onTimeout: () => throw ChatGptException('ChatGPTの生成がタイムアウトした'),
          );
      _checkCurrent(revision);
      if (res.statusCode != 200) {
        throw ChatGptException('ChatGPTでの生成に失敗した (Status: ${res.statusCode})');
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw ChatGptException('ChatGPTの応答形式が不正だった');
      }
      final text = extractOutputText(decoded);
      if (text.trim().isEmpty) throw ChatGptException('ChatGPTの応答が空だった');
      return text;
    } on AiCancelled {
      rethrow;
    } on ChatGptException catch (e) {
      if (revision != _revision) throw const AiCancelled();
      lastError = e.message;
      rethrow;
    } catch (e) {
      if (revision != _revision) throw const AiCancelled();
      lastError = 'generation failed: $e';
      throw ChatGptException('generation failed: $e');
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
    throw ChatGptException('unparsable $what (after retry)');
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
    if (idea.memos.isEmpty) throw ChatGptException('no memo');
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
