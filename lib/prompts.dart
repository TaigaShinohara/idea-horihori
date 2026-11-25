import 'dart:convert';

import 'dig_mode.dart';
import 'first_dig.dart';
import 'models.dart';

/// Gemini へ渡すプロンプト生成と、応答JSONの解釈（純ロジック寄り）。
class Prompts {
  static const int maxTextLength = 500;
  static const int maxQuestionLength = 200;
  static const int maxChoiceLength = 120;
  static const int standardBudget = 3200;
  static const int nanoBudget = 1550;
  static const int compactNanoBudget = 750;
  static const _memoFields = ['what', 'who', 'why', 'how', 'nextStep'];
  static const _draftFields = [..._memoFields, 'openQuestions'];
  static const reviewMemoSchema = {
    'type': 'object',
    'properties': {
      'what': {'type': 'string', 'description': '本人が決めたアプリの形'},
      'who': {'type': 'string', 'description': '本人が明示した利用者'},
      'why': {'type': 'string', 'description': '本人が語った困りごと'},
      'how': {'type': 'string', 'description': '本人が選んだ手段'},
      'nextStep': {'type': 'string', 'description': '未確認事項を小さく試す行動を一つ'},
      'openQuestions': {'type': 'string', 'description': 'まだ本人が決めていないこと'},
    },
    'required': _draftFields,
  };

  /// AI出力の安全検証（S-03: UI側で自動リンク化しないプレーンテキスト表示前提）。
  /// 制御文字・空文字・過大長を拒否する。
  static bool _safeText(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > maxTextLength) return false;
    if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(text)) return false;
    return true;
  }

  static bool _safeGuidedText(String value) =>
      _safeText(value) && !value.contains('```');

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

  /// 同じ入力でプロンプトを作り、応答の引用先を検証する。
  static ({String prompt, String anchorSource, Map<String, Object> schema})
  firstDigQuestion({
    required String title,
    required String note,
    required FirstDigContext context,
    DigStyle style = DigStyle.friend,
    DigViewpoint viewpoint = DigViewpoint.none,
    int budget = standardBudget,
    bool structuredOutput = false,
  }) {
    final titleText = _clip(title, 120);
    final noteText = _summaryNote(note.trim(), budget ~/ 3);
    final answerText = _clip(context.substantiveAnswer, budget ~/ 3);
    final first = context.firstAnswer;
    final anchorSource = answerText.isNotEmpty
        ? answerText
        : noteText.isNotEmpty
        ? noteText
        : titleText;
    final focus = first == null
        ? '使う場面を一つ具体化する。場面が明らかなら、別の未決事項を一つ聞く。'
        : '''
2問目では「実際に起きたこと」と「これから作る機能」を区別する。
原因や必要な情報がまだ見つかっていないなら、機能を決める前にどこで何を確かめるかを聞く。3つの答えは調べる対象や場所の候補にする。
本人が原因を把握したなら、それを解消する小さな手段を聞く。手段まで選んでいたら、その方法が効くかの試し方を聞く。
判断例：自転車の空気が抜ける場所が不明なら漏れを調べる場所を聞く。バルブの緩みが分かったなら締め直して確かめる条件を聞く。この例を出力に混ぜない。
前の軸（${first.axis ?? "不明"}）とは異なる軸を選ぶ。''';
    final candidates = anchorSource
        .split(RegExp(r'[。！？、\n]'))
        .where((part) => part.trim().isNotEmpty && !part.contains('省略'))
        .map((part) {
          final runes = part.trim().runes.take(30);
          return String.fromCharCodes(runes).replaceAll('…', '').trim();
        })
        .where((part) => part.isNotEmpty)
        .toSet()
        .take(5)
        .toList();
    final previous = first == null
        ? ''
        : '\n前の質問: ${_clip(first.question, 120)}\n前の回答: ${answerText.isEmpty ? "まだ分からない" : answerText}'
              '${structuredOutput ? '' : '\nanchorの候補: ${candidates.join('／')}'}';
    final excluded = context.excludedQuestion?.text;
    final excludedLine = excluded == null
        ? ''
        : '\n避ける質問: ${_clip(excluded, 120)}';
    final viewpointLine = viewpoint.promptLine;
    final tone = style == DigStyle.friend ? '親しみやすく' : '率直に';
    const plainFormat =
        '\nJSONオブジェクトのみ。キーは text, choices, axis, anchor。コードフェンス禁止。';
    return (
      prompt:
          '''
アプリ企画のインタビュー。$tone、日本語で一文の質問を作る。
題: $titleText
${previous.trim()}$excludedLine
$focus
質問は具体的な一文。選択肢は疑問文や言い換えを避け、短い直接の答えを3つ。
axisは scene（場面）、audience（利用者）、obstacle（つまずき）、approach（手段）、test（試し方）。${first == null ? 'anchorは空欄。' : 'anchorは候補を一つ引用。'}${viewpointLine == null ? '' : '\n$viewpointLineこと。'}
元メモと変えてはいけない制約: $noteText
質問文と3つの答えすべてで、元メモの制約・本人の選択・すでに失敗した方法を確認する。違反や未確認の事実を前提にする答えは候補から外す。${structuredOutput ? '' : plainFormat}
''',
      anchorSource: anchorSource,
      schema: {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': first == null
                ? '使う場面を尋ねる短い質問文'
                : '前の回答の困りごとに対し、次に何を試すかを尋ねる短い質問文',
          },
          'choices': {
            'type': 'array',
            'items': {
              'type': 'string',
              'description': '質問への短い直接の答え。答えると最初に調べることや作るものが変わる',
            },
            'minItems': 3,
            'maxItems': 3,
          },
          'axis': {
            'type': 'string',
            'enum': [
              for (final axis in FirstDigContext.axes)
                if (axis != first?.axis) axis,
            ],
          },
          'anchor': {
            'type': 'string',
            'description': '重視した本人の言葉を一つ',
            if (first != null && candidates.isNotEmpty) 'enum': candidates,
          },
        },
        'required': ['text', 'choices', 'axis', 'anchor'],
      },
    );
  }

  static DigQuestion? parseFirstDigQuestion(
    String text, {
    required FirstDigContext context,
    required String anchorSource,
  }) {
    final output = extractJson(text);
    if (output == null) return null;
    final question = output['text'];
    final rawChoices = output['choices'];
    final axis = output['axis'];
    final anchor = output['anchor'];
    if (question is! String ||
        !_safeGuidedText(question) ||
        question.trim().length > maxQuestionLength ||
        !context.acceptsQuestion(question) ||
        axis is! String ||
        !FirstDigContext.axes.contains(axis) ||
        axis == context.firstAnswer?.axis ||
        anchor is! String ||
        rawChoices is! List ||
        rawChoices.length != 3 ||
        rawChoices.any((choice) => choice is! String)) {
      return null;
    }
    if (context.firstAnswer != null) {
      final quote = anchor.trim();
      final minLength = anchorSource.runes.length == 1 ? 1 : 2;
      if (quote.runes.length < minLength ||
          quote.runes.length > 40 ||
          FirstDigContext.normalize(quote).isEmpty ||
          quote.contains('…') ||
          !anchorSource
              .split('\n（元メモの一部を省略）\n')
              .any((part) => part.contains(quote))) {
        return null;
      }
    }
    final choices = rawChoices
        .cast<String>()
        .map((choice) => choice.trim())
        .toList();
    final normalized = choices.map(FirstDigContext.normalize).toSet();
    if (choices.any(
          (choice) =>
              !_safeGuidedText(choice) || choice.length > maxChoiceLength,
        ) ||
        normalized.length != 3 ||
        normalized.contains('')) {
      return null;
    }
    final ordinal = context.firstAnswer == null ? 1 : 2;
    return DigQuestion(
      id: 'guided_${ordinal}_$axis',
      text: question.trim(),
      choices: choices,
      axis: axis,
    );
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
    bool reviewDraft = false,
    bool structuredOutput = false,
  }) {
    final titleText = _clip(title, 120);
    final noteText = note.trim();
    const noteHeading = '\n元メモ（本人の原文・制約）:\n';
    const historyHeading = '\n今回のQ&A:\n';
    const previousHeading = '\n前回の企画メモ（今回の入力とは別の参考情報）:\n';
    final turns = [
      for (final entry in history)
        reviewDraft
            ? 'AIの問い: ${entry.question}\n本人の発言: ${entry.answer}'
            : 'Q: ${entry.question}\nA: ${entry.answer}',
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
    if (reviewDraft) {
      const plainFormat =
          '\nJSONオブジェクトのみ。キーは what, who, why, how, nextStep, openQuestions。コードフェンス禁止。';
      return '''
アプリ「$titleText」の確認用の下書きを日本語で短く整理する。$notePart$historyHeading$historyPart$previousPart
決定の根拠にできるのは「本人の発言」と「元メモ」。AIの問いの例や選択肢は本人の決定に含めない。
what（作るもの）、who（利用者）、why（困りごと）、how（手段）は明示されたことだけ。未定なら空欄。未確認事項は openQuestions。
nextStep は手元でできる小さな確認を一つ。原因・情報源が不明なら観察や調査を先にする。本人が選んだ方法を変えず、失敗した場所や方法から離れて次を試す。判断材料がなければ空欄。
すべての欄を元メモと本人の発言に照らし、結論や次の一歩が本人の制約に反していないか確かめる。${structuredOutput ? '' : plainFormat}
''';
    }
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
    bool reviewDraft = false,
  }) {
    final j = extractJson(text);
    if (j == null) return null;
    final values = <String>[];
    for (final key in reviewDraft ? _draftFields : _memoFields) {
      final value = j[key];
      if (value is! String ||
          !(reviewDraft && value.trim().isEmpty) &&
              !(reviewDraft ? _safeGuidedText(value) : _safeText(value))) {
        return null;
      }
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
      ease: reviewDraft ? null : fitnessValueOrNull(j['ease']),
      spark: reviewDraft ? null : fitnessValueOrNull(j['spark']),
      openQuestions: reviewDraft ? values[5] : null,
    );
  }
}
