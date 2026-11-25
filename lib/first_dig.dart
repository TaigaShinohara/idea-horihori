import 'dig_mode.dart';
import 'models.dart';

/// 1問目で扱う場面や未決事項。
enum OpeningFocus {
  scene('具体的な利用場面がまだ見えていない', '最初にこのアプリを使うのはどんな場面？', [
    '困ったそのとき',
    '後で思い出すとき',
    '楽しみとして始めるとき',
  ]),
  audience('使う場面が見えていて、最初に誰が使うかが未定', '最初に試してもらうなら、どんな人が近い？', [
    '自分と同じ場面で困っている人',
    '今のやり方に慣れた人',
    '初めてその作業をする人',
  ]),
  obstacle('今の状況が書かれていて、どの段階で困るかが未定', '今のやり方で、どの段階が難しい？', [
    '取りかかるまで',
    '作業の途中',
    '後で見返すとき',
  ]),
  test('利用場面と困りごとが書かれていて、先に試すことが未定', '最初に何を確かめたい？', [
    '今のやり方で詰まるところ',
    'どのくらい頻繁に起きるか',
    '手作業でも助かるか',
  ]);

  const OpeningFocus(this.description, this.question, this.choices);

  final String description;
  final String question;
  final List<String> choices;

  DigQuestion toQuestion([DigStyle style = DigStyle.friend]) => DigQuestion(
    id: 'guided_1_$name',
    text: style == DigStyle.friend ? question : 'まずここを確かめよう。$question',
    choices: choices,
    axis: name,
  );
}

/// AIが選ぶのは、本人の発言と、それを受けて確認する観点。
enum FollowUpFocus {
  findInformation('test', '必要な情報の所在や入手方法がまだ分からない', '必要な情報が見つかるか、まず何を確認したい？', [
    '今使っている画面や資料',
    '手元にある別の記録',
    '情報を出す人や窓口',
  ], '直近の1件で、まだ確認していない情報源を一つ調べ、必要な情報があるか確かめる。'),
  rememberInTime(
    'approach',
    '知っていたことを必要なときに思い出せなかった',
    '思い出せるか試すなら、どのタイミングがよさそう？',
    ['記録した直後', '必要になる少し前', '普段の作業を見返すとき'],
    '手元の1件を使い、選んだタイミングで思い出せるか試す。',
  ),
  reviewOrder('approach', '並び順を手がかりに見返したい', '並べ方を試すとき、何を手がかりにしたい？', [
    '作業や出来事が起きた順',
    '記録した日付の順',
    '本人が決めた順',
  ], '手元の候補を3件だけ並べ、選んだ順序で流れを追えるか確かめる。'),
  tellApart('approach', '似た候補があり、今の手がかりでは見分けにくい', '候補を見分けるなら、何が先に見えると助かる？', [
    '中身の一部',
    '候補ごとに違うところ',
    '自分で付けた目印',
  ], '似た候補を2件並べ、選んだ手がかりだけで開き直さず見分けられるか確かめる。'),
  noticeChange(
    'approach',
    'その場で自分の行動や周りの変化に気づきたい',
    '行動を止めずに気づけるか、どんな合図から試したい？',
    ['視界の端で見える小さな印', '見たいときに自分で確認できる印', 'いつもの動作の中で目に入る印'],
    '普段どおり続けられる場面を一つ選び、選んだ合図に気づけるかを確かめる。',
  ),
  resumeWork(
    'approach',
    '中断後に、どこから再開するかや次の作業を思い出したい',
    '作業に戻ったとき、最初に何を見返せると助かる？',
    ['直前に作業した場所', '次にやる一手', '止めた時点の進み具合'],
    '途中の作業を一度離れ、選んだ手がかりを見て再開できるか確かめる。',
  ),
  observeOnce('obstacle', '具体的な話が少なく、まず実際の状況を確かめたい', '実際の1件を見て、まず何を確かめたい？', [
    '始めるときにつまずくこと',
    '途中で手が止まること',
    'あとから見返すときに困ること',
  ], '実際の1件を振り返り、どの時点で何が起きたかを一つ記録する。');

  const FollowUpFocus(
    this.axis,
    this.description,
    this.question,
    this.choices,
    this.trial,
  );

  final String axis;
  final String description;
  final String question;
  final List<String> choices;
  final String trial;

  String get questionId => 'guided_2_$name';

  List<String> choicesFor(String? questionAxis) =>
      this == observeOnce && questionAxis == 'test'
      ? const ['今の手順にかかる時間', '一度で作業ができるか', '結果を後で見返せるか']
      : choices;

  static FollowUpFocus? fromQuestionId(String id) {
    for (final focus in values) {
      if (focus.questionId == id) return focus;
    }
    return null;
  }
}

/// 初回セッションの1問目または2問目で使う文脈。
class FirstDigContext {
  final QaEntry? firstAnswer;
  final DigQuestion? excludedQuestion;

  const FirstDigContext({this.firstAnswer, this.excludedQuestion});

  static String normalize(String text) => normalizeDigText(text);
  String get substantiveAnswer => firstAnswer?.substantiveAnswer ?? '';

  /// 引用を文の途中で切らない。否定や条件を含めて残す。
  static List<String> evidenceSentences(String source) => source
      .split(RegExp(r'(?<=[。！？!?])|\n'))
      .map((line) => line.trim())
      .where(
        (line) =>
            line.isNotEmpty &&
            line.runes.length <= 90 &&
            !line.contains('…') &&
            line != '（元メモの一部を省略）',
      )
      .toSet()
      .take(5)
      .toList(growable: false);

  Map<String, (FollowUpFocus, String)> followUpChoices(String source) {
    final passages = evidenceSentences(source);
    if (passages.isEmpty &&
        excludedQuestion?.id != FollowUpFocus.observeOnce.questionId) {
      return {'observeOnce:0': (FollowUpFocus.observeOnce, '')};
    }
    final candidates = {
      for (var index = 0; index < passages.length; index++)
        for (final focus in FollowUpFocus.values)
          if (focus.questionId != excludedQuestion?.id &&
              _axisFor(focus) != firstAnswer?.axis &&
              _supportsFocus(focus, passages[index]))
            '${focus.name}:${index + 1}': (focus, passages[index]),
    };
    // 本人の文に具体的な手がかりがあれば、その中から次に聞くことを選ぶ。
    // 「別の質問」で最後の具体的な観点を除いた場合も、汎用の観察に進める。
    if (candidates.values.any((item) => item.$1 != FollowUpFocus.observeOnce)) {
      candidates.removeWhere((_, item) => item.$1 == FollowUpFocus.observeOnce);
    }
    return candidates;
  }

  // 未知の情報を失念へ置き換えない。「思い出す」観点には本人の言葉が必要。
  static final _recall = RegExp(
    r'忘れ(?:た|て|がち|る)|思い出せ|覚えていな|forgot|forget|couldn.t remember',
    caseSensitive: false,
  );
  static final _recallDenied = RegExp(
    r'(?:忘れた|思い出せない)(?:の|わけ)?ではな[いく]|忘れていません|忘れて(?:は)?いな[いく]|didn.t forget|did not forget',
    caseSensitive: false,
  );
  static final _unknownInformation = RegExp(
    r'知らな|知らず|分から|わから|不明|見当たら|見つから|どこに|入手先|知りたい|unknown|not know|didn.t know|could not find|couldn.t find',
    caseSensitive: false,
  );
  static final _unknownDenied = RegExp(
    r'(?:知らなかった|分からなかった|わからなかった)(?:の|わけ)?ではな[いく]',
  );
  static final _sequence = RegExp(
    r'順序|順に|順で|時系列|並[べび]|順番|chronolog|sort(?:ing|ed)?|(?:date|time) order|order of',
    caseSensitive: false,
  );
  static final _distinction = RegExp(
    r'見分け|判別|区別|見比べ|選び間違|tell apart|differentiat',
    caseSensitive: false,
  );
  static final _notice = RegExp(
    r'気[づ付]|気がつ|見逃|見落と|合図がほしい|notic|overlook',
    caseSensitive: false,
  );
  static final _resume = RegExp(
    r'作業.*戻[るろっりれ]|戻[るろっりれ].*(?:作業|直前|次|地点)|再開|続き|中断後|中断の[あと後]|resume|pick up|left off',
    caseSensitive: false,
  );
  static final _expressedReservation = RegExp(
    r'わけではな[いく]|つもりはな[いく]|したくな[いく]|使いたくな[いく]|必要はな[いく]|不要|'
    r'使わな[いく]|並べ(?:な[いく]|ません)|順にしな[いく]|禁止|たとえば|例えば|もし|かもしれ|かも。?$|\b(?:hypothetically|for example)\b',
    caseSensitive: false,
  );

  String _axisFor(FollowUpFocus focus) =>
      focus == FollowUpFocus.observeOnce && firstAnswer?.axis == 'obstacle'
      ? 'test'
      : focus.axis;

  bool _supportsFocus(FollowUpFocus focus, String passage) {
    if (focus == FollowUpFocus.observeOnce) return true;
    if (substantiveAnswer.isEmpty) return false;
    if (_expressedReservation.hasMatch(passage)) return false;
    return switch (focus) {
      FollowUpFocus.findInformation =>
        _unknownInformation.hasMatch(passage) &&
            !_unknownDenied.hasMatch(passage) &&
            !_distinction.hasMatch(passage) &&
            !_resume.hasMatch(passage),
      FollowUpFocus.rememberInTime =>
        _recall.hasMatch(passage) &&
            !_recallDenied.hasMatch(passage) &&
            !_resume.hasMatch(passage),
      FollowUpFocus.reviewOrder => _sequence.hasMatch(passage),
      FollowUpFocus.tellApart => _distinction.hasMatch(passage),
      FollowUpFocus.noticeChange => _notice.hasMatch(passage),
      FollowUpFocus.resumeWork => _resume.hasMatch(passage),
      FollowUpFocus.observeOnce => true,
    };
  }

  DigQuestion? followUpQuestion(
    String choice,
    String source, {
    DigStyle style = DigStyle.friend,
  }) {
    final selected = followUpChoices(source)[choice];
    if (selected == null) return null;
    final (focus, evidence) = selected;
    final axis = _axisFor(focus);
    final simpleTest = focus == FollowUpFocus.observeOnce && axis == 'test';
    final question = simpleTest ? '今のやり方を一度試すなら、何を確かめたい？' : focus.question;
    final styled = style == DigStyle.friend
        ? question
        : '次に確かめることを絞ろう。$question';
    final text = evidence.isEmpty ? styled : '「$evidence」\n$styled';
    if (!acceptsQuestion(text)) return null;
    return DigQuestion(
      id: focus.questionId,
      text: text,
      choices: focus.choicesFor(axis),
      axis: axis,
    );
  }

  bool acceptsQuestion(String question) {
    final text = normalize(question);
    return text.isNotEmpty &&
        text != normalize(firstAnswer?.question ?? '') &&
        text != normalize(excludedQuestion?.text ?? '');
  }
}
