import 'first_dig.dart';
import 'models.dart';

typedef _AnswerEvidence = ({String id, String text, String? field});

/// 本人の完全な回答だけを選択肢として渡し、AIの指定を原文に置き換える。
class ReviewDraftGrounding {
  final List<_AnswerEvidence> _evidence;
  final String _nextStep;

  ReviewDraftGrounding._(this._evidence, this._nextStep);

  static const _decidedFields = ['what', 'who', 'why', 'how'];
  static final _namedField = {
    'what': RegExp(
      r'^(?:作るもの|アプリの形|what)(?:は|[:：])\s*[^\s。！？!?]',
      caseSensitive: false,
    ),
    'who': RegExp(
      r'^(?:対象者?|想定利用者|利用者|who)(?:は|[:：])\s*[^\s。！？!?]',
      caseSensitive: false,
    ),
    'why': RegExp(
      r'^(?:困りごと|解決する課題|目的|理由|why)(?:は|[:：])\s*[^\s。！？!?]',
      caseSensitive: false,
    ),
    'how': RegExp(
      r'^(?:実現方法|実装方法|手段|やり方|how)(?:は|[:：])\s*[^\s。！？!?]',
      caseSensitive: false,
    ),
  };

  static final _uncertain = RegExp(
    r'[？?]|わからな(?:い|かった)|分からな(?:い|かった)|知らな(?:い|かった)|分からず|知らず|未定|未確認|'
    r'たぶん|おそらく|かもしれ|かも(?:$|[。！!])|だろう|検討中|できれば|可能なら|'
    r'と思(?:う|います)|しようかな|試してみたい|かどうか|(?:か|を)確かめたい|'
    r'ほしい|欲しい|(?:知り|見|使い|比べ|探し)たい|良さそう|よさそう|任せる|なんとなく|'
    r'まだ|もし|ただし|けれど|けど|ものの|しかし|反面|一方|とはいえ|(?:だ|た|る)が[、，]|'
    r"\b(?:maybe|might|possibly|unsure|however|but|if)\b",
    caseSensitive: false,
  );
  static final _negated = RegExp(
    r'わけではなく|ではなく|じゃなく|ない(?:$|[。！？!?,、\s])|なかった|ません|られず|不要|禁止|'
    r"\b(?:not|never|without|cannot|can't|don't|won't)\b",
    caseSensitive: false,
  );
  static final _explicitTrial = RegExp(
    r'(?:^|[。！!])\s*(?:まず|次に|最初に|次の一歩は|手始めに).{1,160}'
    r'(?:試す|確認する|確かめる|調べる|比べる|観察する|見てみる)(?:[。！!]|$)',
  );
  static final _positiveIntent = RegExp(
    r'知りたい|ほしい|欲しい|見たい|見てみたい|見比べたい|比べたい|'
    r'試したい|試してみたい|確かめたい|確認したい|調べたい',
  );
  static final _refusedTrial = RegExp(
    r'でき(?:な[いく]|ません)|試せな[いく]|調べられな[いく]|使えな[いく]|'
    r'したくな[いく]|やりたくな[いく]|ほしくな[いく]|欲しくな[いく]|'
    r'望まな[いく]|(?:見|見比べ|比べ|確かめ|試し|調べ)たくな[いく]|試すつもり(?:は|が)な[いく]|'
    r'そうしたい(?:という)?(?:わけ|の)?(?:では|じゃ)な[いく]|'
    r'(?:確認|調査|比較|試行|検証)(?:は|が)?(?:無理|不可能)|'
    r"\b(?:cannot|can't|don't want|won't|unable)\b",
    caseSensitive: false,
  );
  static final _negatedIntentSuffix = RegExp(
    r'^\s*(?:という)?(?:わけ|の)?(?:では|じゃ)な[いく]',
  );
  static final _trialTopics = {
    FollowUpFocus.findInformation: RegExp(r'情報|知りたい|所在|探したい|見つけ|記載|どこ|入手'),
    FollowUpFocus.rememberInTime: RegExp(r'知らせ|通知|思い出|合図|覚えて|期限前'),
    FollowUpFocus.reviewOrder: RegExp(r'順|並べ|時系列'),
    FollowUpFocus.tellApart: RegExp(r'見分け|見比べ|区別|判別|比較'),
    FollowUpFocus.noticeChange: RegExp(r'印|合図|気[づ付]|気がつ|目に入|アイコン'),
    FollowUpFocus.resumeWork: RegExp(r'作業|続き|次にやる|次の一手|中断|再開|直前'),
  };
  static final _refusedLookup = RegExp(r'調べず|調べな[いく]|探さな[いく]');
  static final _example = RegExp(
    r'たとえば|例えば|一例|例として|例[:：]|仮に|\bfor example\b',
    caseSensitive: false,
  );
  static final _controlCharacter = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]');

  static bool _isKnownLocalChoice(QaEntry answer, String text) =>
      answer.source == AnswerSource.local &&
      (answer.choices?.contains(text) ?? false);

  static bool _hasPositiveIntent(FollowUpFocus focus, String text) {
    final topic = _trialTopics[focus];
    if (topic == null ||
        (focus == FollowUpFocus.findInformation &&
            _refusedLookup.hasMatch(text))) {
      return false;
    }
    return text
        .split(RegExp(r'[。！？!?、，\n]'))
        .any(
          (clause) =>
              topic.hasMatch(clause) &&
              _positiveIntent
                  .allMatches(clause)
                  .any(
                    (match) => !_negatedIntentSuffix.hasMatch(
                      clause.substring(match.end),
                    ),
                  ),
        );
  }

  static String? _decisionField(QaEntry answer, String text, String note) {
    if (note.isNotEmpty && note != text) return null;
    final id = answer.questionId;
    if (_decidedFields.contains(id) && _isKnownLocalChoice(answer, text)) {
      return id;
    }
    for (final field in _namedField.entries) {
      if (field.value.hasMatch(text)) return field.key;
    }
    return null;
  }

  factory ReviewDraftGrounding.fromAnswers(
    List<QaEntry> answers, {
    required int budget,
    String note = '',
  }) {
    final selected = <_AnswerEvidence>[];
    final originalNote = note.trim();
    var remaining = budget * 2 ~/ 3;
    var explicitStep = '';
    var guidedTrial = '';
    for (var index = answers.length - 1; index >= 0; index--) {
      final answer = answers[index];
      final text = answer.substantiveAnswer;
      if (text.isEmpty) continue;
      // 通常のAI質問のIDは生成任せ。軸があるアプリ発行の質問だけを使う。
      final focus = answer.axis == null
          ? null
          : FollowUpFocus.fromQuestionId(answer.questionId);
      if (text.length > 500 ||
          _controlCharacter.hasMatch(text) ||
          text.contains('```')) {
        continue;
      }
      final couldChangeMeaning =
          _uncertain.hasMatch(text) ||
          _negated.hasMatch(text) ||
          _example.hasMatch(text);
      final isTrialAnswer =
          focus != null ||
          answer.questionId.startsWith('guided_2_') ||
          answer.axis == 'test';
      final isExplicitStep =
          !couldChangeMeaning &&
          ((answer.questionId == 'next' && _isKnownLocalChoice(answer, text)) ||
              _explicitTrial.hasMatch(text));
      if (isExplicitStep && explicitStep.isEmpty) explicitStep = text;
      if (focus != null &&
          guidedTrial.isEmpty &&
          text.length <= 120 &&
          !_refusedTrial.hasMatch(text) &&
          !_example.hasMatch(text) &&
          (focus.choicesFor(answer.axis).contains(text) ||
              _hasPositiveIntent(focus, text))) {
        guidedTrial = '試す候補：${focus.trial}\n回答原文「$text」';
      }
      final estimatedLength = text.runes.length + 50;
      if (estimatedLength > remaining || isExplicitStep) continue;
      final field = isTrialAnswer || couldChangeMeaning
          ? null
          : _decisionField(answer, text, originalNote);
      selected.add((id: 'a${index + 1}', text: text, field: field));
      remaining -= estimatedLength;
    }
    return ReviewDraftGrounding._(
      selected.reversed.toList(),
      explicitStep.isEmpty ? guidedTrial : explicitStep,
    );
  }

  String get promptEvidence => _evidence.isEmpty
      ? '（この予算で選べる回答原文はありません）'
      : [
          for (final item in _evidence)
            '${item.id} [${item.field ?? "openQuestions"}]: ${item.text}',
        ].join('\n');

  PlanMemo build({
    required int version,
    DateTime? now,
    Map<String, String> selection = const {},
  }) {
    String resolve(String key) {
      final id = selection[key];
      for (final item in _evidence) {
        if (item.id == id && (item.field ?? 'openQuestions') == key) {
          return item.text;
        }
      }
      return '';
    }

    return PlanMemo(
      what: resolve('what'),
      who: resolve('who'),
      why: resolve('why'),
      how: resolve('how'),
      nextStep: _nextStep,
      openQuestions: resolve('openQuestions'),
      createdAt: now ?? DateTime.now(),
      version: version,
    );
  }
}
