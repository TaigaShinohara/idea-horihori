import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'fallback.dart';
import 'models.dart';
import 'prompts.dart';

/// 応答がどこから来たか（K1: モード開示のために画面へ伝える）。
enum AnswerSource { remote, local }

/// AIバックエンドの抽象化。v1の既定は Gemini、差し替え口だけ用意する。
abstract class AiBackend {
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
  });
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
  });
  bool get isRemote;
}

/// Gemini REST (generateContent) 実装。キーはログに出さない。
class GeminiBackend implements AiBackend {
  final String apiKey;
  final String model;
  final http.Client _client;
  GeminiBackend({required this.apiKey, String? model, http.Client? client})
      : model = model ?? AppConfig.defaultGeminiModel,
        _client = client ?? http.Client();

  @override
  bool get isRemote => true;

  Future<String> _generate(String prompt) async {
    final uri = Uri.parse('${AppConfig.geminiEndpoint}/$model:generateContent');
    final res = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {'temperature': 0.7},
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('Gemini API error: ${res.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List? ?? [];
    if (candidates.isEmpty) throw Exception('Gemini API: empty response');
    final content = (candidates.first as Map<String, dynamic>)['content']
        as Map<String, dynamic>?;
    final parts = content?['parts'] as List? ?? [];
    final text = parts
        .map((p) => (p as Map<String, dynamic>)['text']?.toString() ?? '')
        .join();
    if (text.trim().isEmpty) throw Exception('Gemini API: empty text');
    return text;
  }

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
  }) async {
    final text = await _generate(Prompts.nextQuestion(
      title: idea.title,
      note: idea.note,
      history: history,
      latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
    ));
    final q = Prompts.parseQuestion(text);
    if (q == null) throw Exception('Gemini API: unparsable question');
    return q;
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
  }) async {
    final text = await _generate(Prompts.summarize(
      title: idea.title,
      history: history,
      latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
    ));
    final memo = Prompts.parseMemo(text, version: version);
    if (memo == null) throw Exception('Gemini API: unparsable memo');
    return memo;
  }
}

/// ローカルフォールバック実装（キー未設定／オフライン／API失敗時）。
/// 定型質問＋ローカル整形で、ネットなしでも深掘りが完結する。
class LocalBackend implements AiBackend {
  @override
  bool get isRemote => false;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
  }) async {
    // 既出の定型質問は飛ばし、次の未出題を出す。
    for (final q in FallbackQuestions.questions) {
      if (!history.any((a) => a.questionId == q.id)) return q;
    }
    // 定型を使い切ったら汎用の広げ質問を出す。
    final n = history.length + 1;
    return DigQuestion(
      id: 'extra$n',
      text: '「${idea.title}」で、まだ決まっていない大事なことは？',
      choices: ['使う場面をもっと具体的に', '一番の売りを決める', '似たものとの違いを決める'],
    );
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
  }) async {
    return LocalMemoBuilder.build(
      title: idea.title,
      answers: history,
      version: version,
    );
  }
}

/// リモート優先・失敗時はローカルに倒す合成バックエンド。
///
/// K1（v0.1.2）: 失敗を無言で吸収せず、直近の応答元と失敗有無を
/// [lastSource] / [lastRemoteFailed] として公開する。画面側はセッション中
/// 同じインスタンスを保持し、呼び出しのたびにこの値でモード表示を更新する。
class ResilientBackend implements AiBackend {
  final AiBackend? remote;
  final LocalBackend local = LocalBackend();
  ResilientBackend(this.remote);

  /// 直近の呼び出し（質問・まとめ共通）の応答元。未呼び出しなら null。
  AnswerSource? lastSource;

  /// 直近の呼び出しでリモートが失敗しローカルへ倒れたか。
  /// キー未設定で最初からローカルの場合は false。
  bool lastRemoteFailed = false;

  @override
  bool get isRemote => remote != null;

  @override
  Future<DigQuestion> nextQuestion({
    required Idea idea,
    required List<QaEntry> history,
  }) async {
    if (remote != null) {
      try {
        final q = await remote!.nextQuestion(idea: idea, history: history);
        lastSource = AnswerSource.remote;
        lastRemoteFailed = false;
        return q;
      } catch (_) {
        // オフライン・キー不正などはローカルへ倒すが、失敗した事実は残す。
        lastSource = AnswerSource.local;
        lastRemoteFailed = true;
      }
    } else {
      lastSource = AnswerSource.local;
      lastRemoteFailed = false;
    }
    return local.nextQuestion(idea: idea, history: history);
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
  }) async {
    if (remote != null) {
      try {
        final memo =
            await remote!.summarize(idea: idea, history: history, version: version);
        lastSource = AnswerSource.remote;
        lastRemoteFailed = false;
        return memo;
      } catch (_) {
        lastSource = AnswerSource.local;
        lastRemoteFailed = true;
      }
    } else {
      lastSource = AnswerSource.local;
      lastRemoteFailed = false;
    }
    return local.summarize(idea: idea, history: history, version: version);
  }
}
