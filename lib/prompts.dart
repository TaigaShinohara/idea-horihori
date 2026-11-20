import 'dart:convert';

import 'models.dart';

/// Gemini へ渡すプロンプト生成と、応答JSONの解釈（純ロジック寄り）。
class Prompts {
  static String _historyText(List<QaEntry> history) {
    if (history.isEmpty) return '（まだ回答なし）';
    return history.map((a) => 'Q: ${a.question}\nA: ${a.answer}').join('\n');
  }

  /// 次の質問を1つだけJSONで返させるプロンプト。
  static String nextQuestion({
    required String title,
    String note = '',
    required List<QaEntry> history,
    PlanMemo? latestMemo,
  }) {
    final memoPart = latestMemo == null
        ? ''
        : '\n前回までの企画メモ:\nWhat: ${latestMemo.what}\n誰に: ${latestMemo.who}\nなぜ: ${latestMemo.why}\nどうやって: ${latestMemo.how}\n次の一歩: ${latestMemo.nextStep}\n';
    return '''
あなたはアプリのアイデアを深掘りするインタビュアーです。
アイデア: 「$title」${note.isEmpty ? '' : '\nメモ: $note'}$memoPart
これまでのやりとり:
${_historyText(history)}

次に聞く質問を「1つだけ」考えてください。条件:
- 企画を具体化するために今いちばん効く質問にする
- 回答の選択肢をちょうど3つ作る。3つ目は発想を広げる選択肢にする
- 質問も選択肢も短く、日本語で
出力はJSONのみ（コードフェンス禁止）:
{"id":"q${history.length + 1}","text":"質問文","choices":["選択肢1","選択肢2","選択肢3"]}
''';
  }

  /// 回答群を企画メモの型に整理させるプロンプト。
  static String summarize({
    required String title,
    required List<QaEntry> history,
    PlanMemo? latestMemo,
  }) {
    return '''
アプリのアイデア「$title」について、以下のQ&Aをもとに企画メモを整理してください。
${_historyText(history)}
${latestMemo == null ? '' : '前回のメモ（改善してよい）: What: ${latestMemo.what} / 誰に: ${latestMemo.who} / なぜ: ${latestMemo.why} / どうやって: ${latestMemo.how} / 次の一歩: ${latestMemo.nextStep}'}
各項目は1〜2文の日本語で、Q&Aに無いことは盛らないでください。
出力はJSONのみ（コードフェンス禁止）:
{"what":"何を作るか","who":"誰のためか","why":"どんな困りごとを解くか","how":"どうやって助けるか","nextStep":"次の一歩"}
''';
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
        .take(3)
        .toList();
    if (qText.isEmpty || choices.length < 2) return null;
    return DigQuestion(
      id: (j['id'] as String? ?? 'ai').trim().isEmpty ? 'ai' : j['id'] as String,
      text: qText,
      choices: choices,
    );
  }

  static PlanMemo? parseMemo(String text, {required int version, DateTime? now}) {
    final j = extractJson(text);
    if (j == null) return null;
    String v(String k) => (j[k] as String? ?? '').trim();
    if (v('what').isEmpty && v('who').isEmpty) return null;
    return PlanMemo(
      what: v('what'),
      who: v('who'),
      why: v('why'),
      how: v('how'),
      nextStep: v('nextStep').isEmpty ? '続きを深掘りする' : v('nextStep'),
      createdAt: now ?? DateTime.now(),
      version: version,
    );
  }
}
