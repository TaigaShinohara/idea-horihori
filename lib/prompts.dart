import 'dart:convert';

import 'dig_mode.dart';
import 'models.dart';

/// Gemini へ渡すプロンプト生成と、応答JSONの解釈（純ロジック寄り）。
class Prompts {
  static const int maxTextLength = 500;
  static const int maxChoiceLength = 120;
  static const int standardBudget = 3200;
  static const int nanoBudget = 1550;
  static const int compactNanoBudget = 750;

  static bool _safeText(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > maxTextLength) return false;
    if (text.contains('\u0000')) return false;
    if (RegExp(r'https?://', caseSensitive: false).hasMatch(text)) return false;
    return true;
  }

  static String _clip(String text, int limit) {
    final runes = text.trim().runes.take(limit + 1).toList();
    if (runes.length <= limit) return String.fromCharCodes(runes);
    return '${String.fromCharCodes(runes.take(limit - 1))}…';
  }

  static String _historyText(List<QaEntry> history, int budget) {
    if (history.isEmpty) return '（まだ回答なし）';
    final recent = <String>[];
    var remaining = budget * 3 ~/ 5;
    for (final entry in history.reversed.take(10)) {
      if (remaining < 80) break;
      final turn =
          'Q: ${_clip(entry.question, 90)}\n'
          'A: ${_clip(entry.answer, (remaining - 100).clamp(20, 260))}';
      if (turn.runes.length > remaining) break;
      recent.add(turn);
      remaining -= turn.runes.length + 1;
    }
    return [
      if (recent.length < history.length) '（古い回答は省略）',
      ...recent.reversed,
    ].join('\n');
  }

  static String _memoText(PlanMemo memo, int budget) => [
    ('What', memo.what),
    ('誰に', memo.who),
    ('なぜ', memo.why),
    ('どうやって', memo.how),
    ('次の一歩', memo.nextStep),
  ].map((field) => '${field.$1}: ${_clip(field.$2, budget ~/ 24)}').join('\n');

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
    int budget = standardBudget,
  }) {
    final memoPart = latestMemo == null
        ? ''
        : '\n前回までの企画メモ:\n${_memoText(latestMemo, budget)}\n';
    final viewpointLine = viewpoint.promptLine == null
        ? ''
        : '\n${viewpoint.promptLine}こと。';
    final contrarianLine = contrarian
        ? '\n今回は逆張りとして、このアイデアが失敗するとしたら何が原因かを聞く質問にすること。'
        : '';
    return '''
あなたはアプリのアイデアを深掘りするインタビュアーです。あなたの役割: ${style.personaPrompt}
アイデア: 「${_clip(title, 120)}」${note.isEmpty ? '' : '\nメモ: ${_clip(note, budget ~/ 10)}'}$memoPart
これまでのやりとり:
${_historyText(history, budget)}

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
    int budget = standardBudget,
  }) {
    return '''
アプリのアイデア「${_clip(title, 120)}」について、以下のQ&Aをもとに企画メモを整理してください。あなたの役割: ${style.personaPrompt}
${_historyText(history, budget)}
${latestMemo == null ? '' : '前回のメモ（改善してよい）:\n${_memoText(latestMemo, budget)}'}
各項目は1〜2文の日本語で、Q&Aに無いことは盛らないでください。
あわせて体力測定として、作りやすさ ease とワクワク度 spark をそれぞれ1〜3の整数で付けてください。
出力はJSONのみ（コードフェンス禁止）:
{"what":"何を作るか","who":"誰のためか","why":"どんな困りごとを解くか","how":"どうやって助けるか","nextStep":"次の一歩","ease":2,"spark":3}
''';
  }

  /// 名前候補を3つ返させるプロンプト（v0.2 項目6）。
  static String nameCandidates({
    required String title,
    required PlanMemo memo,
    int budget = standardBudget,
  }) {
    return '''
アプリのアイデア「${_clip(title, 120)}」の企画メモ:
${_memoText(memo, budget)}

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
    final candidates = j['candidates'];
    if (candidates is! List) return [];
    return candidates
        .whereType<String>()
        .map((e) => e.trim())
        .where((s) => s.isNotEmpty)
        .where((s) => _safeText(s) && s.length <= maxChoiceLength)
        .toSet()
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
    final rawText = j['text'];
    final rawChoices = j['choices'];
    if (rawText is! String || rawChoices is! List) return null;
    final qText = rawText.trim();
    final choices = rawChoices
        .whereType<String>()
        .map((choice) => choice.trim())
        .where((s) => s.isNotEmpty)
        .where((s) => _safeText(s) && s.length <= maxChoiceLength)
        .toSet()
        .take(3)
        .toList();
    if (!_safeText(qText) ||
        qText.length > maxChoiceLength ||
        choices.length < 2 ||
        choices.length > 3) {
      return null;
    }
    final rawId = j['id'];
    if (rawId != null && rawId is! String) return null;
    final id = (rawId as String?)?.trim() ?? '';
    return DigQuestion(
      id: id.isEmpty ? 'ai' : id,
      text: qText,
      choices: choices,
    );
  }

  static PlanMemo? parseMemo(
    String text, {
    required int version,
    DateTime? now,
  }) {
    final j = extractJson(text);
    if (j == null) return null;
    const allowed = {'what', 'who', 'why', 'how', 'nextStep', 'ease', 'spark'};
    if (j.keys.any((key) => !allowed.contains(key))) return null;
    final values = <String>[];
    for (final key in ['what', 'who', 'why', 'how', 'nextStep']) {
      final value = j[key];
      if (value is! String || !_safeText(value)) return null;
      values.add(value.trim());
    }
    return PlanMemo(
      what: values[0],
      who: values[1],
      why: values[2],
      how: values[3],
      nextStep: values[4],
      createdAt: now ?? DateTime.now(),
      version: version,
      // 体力測定: 範囲外・欠落は null（表示なし）に倒す。
      ease: fitnessValueOrNull(j['ease']),
      spark: fitnessValueOrNull(j['spark']),
    );
  }
}
