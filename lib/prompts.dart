import 'dart:convert';

import 'dig_mode.dart';
import 'models.dart';

/// Gemini へ渡すプロンプト生成と、応答JSONの解釈（純ロジック寄り）。
class Prompts {
  static const int maxTextLength = 500;
  static const int maxQuestionLength = 200;
  static const int maxChoiceLength = 120;
  static const int standardBudget = 3200;
  static const int nanoBudget = 1550;
  static const int compactNanoBudget = 750;

  /// AI出力の安全検証（S-03: UI側で自動リンク化しないプレーンテキスト表示前提）。
  /// 制御文字・空文字・過大長を拒否する。
  static bool _safeText(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > maxTextLength) return false;
    if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(text)) return false;
    return true;
  }

  static String _clip(String text, int limit) {
    if (limit <= 0) return '';
    final runes = text.trim().runes.take(limit + 1).toList();
    if (runes.length <= limit) return String.fromCharCodes(runes);
    if (limit == 1) return '…';
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

  static String _summaryNote(String note, int limit) {
    final runes = note.runes;
    final size = runes.length;
    if (size <= limit) return note;
    const omission = '\n（元メモの一部を省略）\n';
    final kept = limit - omission.runes.length;
    if (kept < 2) return _clip(omission, limit);
    final head = kept ~/ 2;
    return '${String.fromCharCodes(runes.take(head))}$omission'
        '${String.fromCharCodes(runes.skip(size - (kept - head)))}';
  }

  static String _summaryHistory(List<String> turns, int limit) {
    const omission = '（回答の一部を省略）';
    final recent = <String>[];
    var remaining = limit - omission.runes.length - 1;
    for (final turn in turns.reversed) {
      if (remaining <= 0) break;
      if (turn.runes.length > remaining) {
        if (recent.isEmpty) recent.add(_clip(turn, remaining));
        break;
      }
      recent.add(turn);
      remaining -= turn.runes.length + 1;
    }
    return [_clip(omission, limit), ...recent.reversed].join('\n');
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
    String note = '',
    required List<QaEntry> history,
    PlanMemo? latestMemo,
    DigStyle style = DigStyle.friend,
    int budget = standardBudget,
  }) {
    final titleText = _clip(title, 120);
    final noteText = note.trim();
    const noteHeading = '\n元メモ（本人の原文・制約）:\n';
    const historyHeading = '\n今回のQ&A:\n';
    const previousHeading = '\n前回の企画メモ（今回の入力とは別の参考情報）:\n';
    final turns = [
      for (final entry in history) 'Q: ${entry.question}\nA: ${entry.answer}',
    ];
    final fullHistory = turns.isEmpty ? '（まだ回答なし）' : turns.join('\n');
    final noteSize = noteText.runes.length;
    final historySize = fullHistory.runes.length;
    final primaryBudget =
        (budget -
                titleText.runes.length -
                historyHeading.runes.length -
                (noteText.isEmpty ? 0 : noteHeading.runes.length))
            .clamp(0, budget);
    // 一方が短ければ、空いた枠をもう一方に回す。両方が長い場合のみ分ける。
    final reservedNote = noteSize.clamp(0, primaryBudget ~/ 2);
    final historyBudget = historySize.clamp(0, primaryBudget - reservedNote);
    final noteBudget = noteSize.clamp(0, primaryBudget - historyBudget);
    final notePart = noteText.isEmpty
        ? ''
        : '$noteHeading${_summaryNote(noteText, noteBudget)}';
    final historyPart = historySize <= historyBudget
        ? fullHistory
        : _summaryHistory(turns, historyBudget);
    final previousBudget = (primaryBudget - noteSize - historySize).clamp(
      0,
      budget ~/ 4,
    );
    final previousTextBudget = previousBudget - previousHeading.runes.length;
    final previousPart = latestMemo == null || previousTextBudget < 40
        ? ''
        : '$previousHeading${_clip(_memoText(latestMemo, budget ~/ 2), previousTextBudget)}';
    return '''
アプリのアイデア「$titleText」の企画メモを整理してください。あなたの役割: ${style.personaPrompt}$notePart$historyHeading$historyPart$previousPart
各項目は1〜2文の日本語で、元メモの制約と今回の回答を守り、根拠のない内容は加えず未確認と書いてください。
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
    try {
      final direct = jsonDecode(t);
      if (direct is Map<String, dynamic>) return direct;
    } catch (_) {}

    for (var i = 0; i < t.length; i++) {
      if (t.codeUnitAt(i) != 0x7B) continue;
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var j = i; j < t.length; j++) {
        final code = t.codeUnitAt(j);
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (code == 0x5C) {
            escaped = true;
          } else if (code == 0x22) {
            inString = false;
          }
          continue;
        }
        if (code == 0x22) {
          inString = true;
        } else if (code == 0x7B) {
          depth++;
        } else if (code == 0x7D) {
          depth--;
          if (depth == 0) {
            try {
              final decoded = jsonDecode(t.substring(i, j + 1));
              if (decoded is Map<String, dynamic>) return decoded;
            } catch (_) {}
            break;
          }
        }
      }
    }
    return null;
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
        qText.length > maxQuestionLength ||
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
