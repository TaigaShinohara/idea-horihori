import 'dart:convert';

import 'dig_mode.dart';
import 'models.dart';

/// Gemini へ渡すプロンプト生成と、応答JSONの解釈（純ロジック寄り）。
class Prompts {
  static const int maxTextLength = 500;
  static const int maxChoiceLength = 120;

  static bool _safeText(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > maxTextLength) return false;
    if (text.contains('\u0000')) return false;
    if (RegExp(r'https?://', caseSensitive: false).hasMatch(text)) return false;
    return true;
  }

  static String _historyText(List<QaEntry> history) {
    if (history.isEmpty) return '（まだ回答なし）';
    return history.map((a) => 'Q: ${a.question}\nA: ${a.answer}').join('\n');
  }

  /// 次の質問を1つだけJSONで返させるプロンプト。
  /// [style] で掘り方（友達／上司）、[viewpoint] で視点掘り、
  /// [contrarian] が true のときは逆張り質問にする（v0.2 項目1〜3）。
  static String nextQuestion({
    required String title,
    String note = '',
    required List<QaEntry> history,
    PlanMemo? latestMemo,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    bool contrarian = false,
  }) {
    final memoPart = latestMemo == null
        ? ''
        : '\n前回までの企画メモ:\nWhat: ${latestMemo.what}\n誰に: ${latestMemo.who}\nなぜ: ${latestMemo.why}\nどうやって: ${latestMemo.how}\n次の一歩: ${latestMemo.nextStep}\n';
    final viewpointLine =
        viewpoint.promptLine == null ? '' : '\n${viewpoint.promptLine}こと。';
    final contrarianLine = contrarian
        ? '\n今回は逆張りとして、このアイデアが失敗するとしたら何が原因かを聞く質問にすること。'
        : '';
    return '''
あなたはアプリのアイデアを深掘りするインタビュアーです。あなたの役割: ${style.personaPrompt}
アイデア: 「$title」${note.isEmpty ? '' : '\nメモ: $note'}$memoPart
これまでのやりとり:
${_historyText(history)}

次に聞く質問を「1つだけ」考えてください。条件:
- 企画を具体化するために今いちばん効く質問にする
- 回答の選択肢をちょうど3つ作る。3つ目は発想を広げる選択肢にする
- 質問も選択肢も短く、日本語で$viewpointLine$contrarianLine
出力はJSONのみ（コードフェンス禁止）:
{"id":"q${history.length + 1}","text":"質問文","choices":["選択肢1","選択肢2","選択肢3"]}
''';
  }

  /// 回答群を企画メモの型に整理させるプロンプト。
  /// 出力には体力測定（ease/spark、各1〜3）も含める（v0.2 項目4）。
  static String summarize({
    required String title,
    required List<QaEntry> history,
    PlanMemo? latestMemo,
    DigStyle style = DigStyle.friend,
  }) {
    return '''
アプリのアイデア「$title」について、以下のQ&Aをもとに企画メモを整理してください。あなたの役割: ${style.personaPrompt}
${_historyText(history)}
${latestMemo == null ? '' : '前回のメモ（改善してよい）: What: ${latestMemo.what} / 誰に: ${latestMemo.who} / なぜ: ${latestMemo.why} / どうやって: ${latestMemo.how} / 次の一歩: ${latestMemo.nextStep}'}
各項目は1〜2文の日本語で、Q&Aに無いことは盛らないでください。
あわせて体力測定として、作りやすさ ease とワクワク度 spark をそれぞれ1〜3の整数で付けてください。
出力はJSONのみ（コードフェンス禁止）:
{"what":"何を作るか","who":"誰のためか","why":"どんな困りごとを解くか","how":"どうやって助けるか","nextStep":"次の一歩","ease":2,"spark":3}
''';
  }

  /// 名前候補を3つ返させるプロンプト（v0.2 項目6）。
  static String nameCandidates({required String title, required PlanMemo memo}) {
    return '''
アプリのアイデア「$title」の企画メモ:
What: ${memo.what}
誰に: ${memo.who}
なぜ: ${memo.why}
どうやって: ${memo.how}

このアプリの名前の候補をちょうど3つ考えてください。条件:
- 短く、呼びやすく、覚えやすいこと
- 日本語／英語の混在可
出力はJSONのみ（コードフェンス禁止）:
{"candidates":["候補1","候補2","候補3"]}
''';
  }

  /// 名前候補の応答JSONを解釈する。取れた分だけ返す（最大3件）。
  static List<String> parseNameCandidates(String text) {
    final j = extractJson(text);
    if (j == null) return [];
    return (j['candidates'] as List? ?? [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .where((s) => _safeText(s) && s.length <= maxChoiceLength)
        .take(3)
        .toList();
  }

  /// 応答テキストからJSONオブジェクトを取り出す（フェンス混入に耐える）。
  static Map<String, dynamic>? extractJson(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trim();
    }
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(t.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static DigQuestion? parseQuestion(String text) {
    final j = extractJson(text);
    if (j == null) return null;
    final qText = (j['text'] as String? ?? '').trim();
    final choices = (j['choices'] as List? ?? [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .where((s) => _safeText(s) && s.length <= maxChoiceLength)
        .take(3)
        .toList();
    if (!_safeText(qText) ||
        qText.length > maxChoiceLength ||
        choices.length < 2 ||
        choices.length > 3) {
      return null;
    }
    return DigQuestion(
      id: (j['id'] as String? ?? 'ai').trim().isEmpty ? 'ai' : j['id'] as String,
      text: qText,
      choices: choices,
    );
  }

  static PlanMemo? parseMemo(String text, {required int version, DateTime? now}) {
    final j = extractJson(text);
    if (j == null) return null;
    const allowed = {
      'what',
      'who',
      'why',
      'how',
      'nextStep',
      'ease',
      'spark',
    };
    if (j.keys.any((key) => !allowed.contains(key))) return null;
    String v(String k) => (j[k] as String? ?? '').trim();
    final values = [v('what'), v('who'), v('why'), v('how'), v('nextStep')];
    if (values.any((value) => value.isEmpty) ||
        values.any((value) => !_safeText(value))) {
      return null;
    }
    return PlanMemo(
      what: v('what'),
      who: v('who'),
      why: v('why'),
      how: v('how'),
      nextStep: v('nextStep').isEmpty ? '続きを深掘りする' : v('nextStep'),
      createdAt: now ?? DateTime.now(),
      version: version,
      // 体力測定: 範囲外・欠落は null（表示なし）に倒す。
      ease: fitnessValueOrNull(j['ease']),
      spark: fitnessValueOrNull(j['spark']),
    );
  }
}
