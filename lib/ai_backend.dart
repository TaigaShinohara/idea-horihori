import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'dig_mode.dart';
import 'chatgpt_backend.dart';
import 'on_device_backend.dart';
import 'fallback.dart';
import 'models.dart';
import 'name_candidates.dart';
import 'prompts.dart';

/// 応答がどこから来たか（K1: モード開示のために画面へ伝える）。
enum AnswerSource { onDevice, chatGpt, remote, local }

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
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
  }) async {
    final text = await _generate(Prompts.nextQuestion(
      title: idea.title,
      note: idea.note,
      history: history,
      latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
      style: style,
      viewpoint: viewpoint,
      contrarian: contrarianDue,
    ));
    final q = Prompts.parseQuestion(text);
    if (q == null) throw Exception('Gemini API: unparsable question');
    // 逆張りとして出させた質問には印を付けて返す（取り消し時の復元用）。
    return contrarianDue ? q.copyWith(isContrarian: true) : q;
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
  }) async {
    final text = await _generate(Prompts.summarize(
      title: idea.title,
      history: history,
      latestMemo: idea.memos.isEmpty ? null : idea.memos.last,
      style: style,
    ));
    final memo = Prompts.parseMemo(text, version: version);
    if (memo == null) throw Exception('Gemini API: unparsable memo');
    return memo;
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) async {
    if (idea.memos.isEmpty) throw Exception('Gemini API: no memo');
    final text = await _generate(Prompts.nameCandidates(
      title: idea.title,
      memo: idea.memos.last,
    ));
    final names = Prompts.parseNameCandidates(text);
    if (names.length < 3) throw Exception('Gemini API: unparsable names');
    return names;
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
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarianDue = false,
  }) async {
    // 逆張り（項目3）: 指定があり、まだ出していなければ固定文を出す（1回だけ）。
    if (contrarianDue && !history.any((a) => a.contrarian)) {
      return FallbackQuestions.contrarianQuestion;
    }
    // 既出の定型質問は飛ばし、次の未出題を出す。
    for (final q in FallbackQuestions.questions) {
      if (!history.any((a) => a.questionId == q.id)) {
        return FallbackQuestions.styled(q, style);
      }
    }
    // 定型を使い切ったら汎用の広げ質問を出す。
    final n = history.length + 1;
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
  }) async {
    return LocalMemoBuilder.build(
      title: idea.title,
      answers: history,
      version: version,
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
class ResilientBackend implements AiBackend {
  final AiBackend? remote;

  /// v0.3.0 PoC: オンデバイスAI。最優先で試し、失敗したら次へ倒す。
  final AiBackend? onDevice;

  /// v0.4.0: ChatGPT（サインイン済みのときだけ非 null）。オンデバイスの次。
  final AiBackend? chatGpt;
  final LocalBackend local = LocalBackend();
  ResilientBackend(this.remote, {this.onDevice, this.chatGpt});

  /// 直近の呼び出し（質問・まとめ共通）の応答元。未呼び出しなら null。
  AnswerSource? lastSource;

  /// 直近の呼び出しでリモートが失敗しローカルへ倒れたか。
  /// キー未設定で最初からローカルの場合は false。
  bool lastRemoteFailed = false;

  /// 直近の呼び出しでオンデバイスが失敗し次へ倒れたか（v0.3.0 PoC）。
  bool lastOnDeviceFailed = false;

  /// 直近のオンデバイス失敗の理由（診断表示用、v0.3.1）。
  String? lastOnDeviceError;

  /// 直近の呼び出しで ChatGPT が失敗し次へ倒れたか（v0.4.0）。
  bool lastChatGptFailed = false;

  /// 直近の ChatGPT 失敗の理由（診断表示用、v0.4.0）。
  String? lastChatGptError;

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

  /// 候補を優先順（オンデバイス→リモート→ローカル）で試す共通処理。
  Future<T> _run<T>(
    Future<T> Function(AiBackend backend) op,
    Future<T> Function() localOp,
  ) async {
    lastOnDeviceFailed = false;
    lastChatGptFailed = false;
    lastRemoteFailed = false;
    if (onDevice != null) {
      try {
        final r = await op(onDevice!);
        lastSource = AnswerSource.onDevice;
        lastOnDeviceError = null;
        return r;
      } catch (e) {
        lastOnDeviceFailed = true;
        final od = onDevice;
        lastOnDeviceError =
            od is OnDeviceBackend ? (od.lastError ?? e.toString()) : e.toString();
      }
    }
    if (chatGpt != null) {
      try {
        final r = await op(chatGpt!);
        lastSource = AnswerSource.chatGpt;
        lastChatGptError = null;
        return r;
      } catch (e) {
        lastChatGptFailed = true;
        final cg = chatGpt;
        lastChatGptError =
            cg is ChatGptBackend ? (cg.lastError ?? e.toString()) : e.toString();
      }
    }
    if (remote != null) {
      try {
        final r = await op(remote!);
        lastSource = AnswerSource.remote;
        return r;
      } catch (_) {
        lastRemoteFailed = true;
      }
    }
    lastSource = AnswerSource.local;
    return localOp();
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
  }) {
    return _run(
      (b) => b.nextQuestion(
        idea: idea,
        history: history,
        style: style,
        viewpoint: viewpoint,
        contrarianDue: contrarianDue,
      ),
      () => local.nextQuestion(
        idea: idea,
        history: history,
        style: style,
        viewpoint: viewpoint,
        contrarianDue: contrarianDue,
      ),
    );
  }

  @override
  Future<PlanMemo> summarize({
    required Idea idea,
    required List<QaEntry> history,
    required int version,
    DigStyle style = DigStyle.friend,
  }) {
    return _run(
      (b) => b.summarize(
        idea: idea,
        history: history,
        version: version,
        style: style,
      ),
      () => local.summarize(
        idea: idea,
        history: history,
        version: version,
        style: style,
      ),
    );
  }

  @override
  Future<List<String>> nameCandidates({required Idea idea}) {
    return _run(
      (b) => b.nameCandidates(idea: idea),
      () => local.nameCandidates(idea: idea),
    );
  }
}
