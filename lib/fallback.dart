import 'dig_mode.dart';
import 'first_dig.dart';
import 'models.dart';

/// APIキー未設定／オフラインでも深掘りが成立するための
/// 組み込み定型質問セット（5問＝1セッション分）。
/// 質問IDはメモ型の各欄に対応する。
class FallbackQuestions {
  static const List<DigQuestion> questions = [
    DigQuestion(
      id: 'who',
      text: '誰のためのアプリ？',
      choices: ['自分みたいな個人', '特定の仕事・趣味の人', 'まだ決めない、広くみんな'],
    ),
    DigQuestion(
      id: 'why',
      text: 'その人が一番困っているのは？',
      choices: ['面倒で手間がかかる', '時間がかかる', '忘れる・続かない'],
    ),
    DigQuestion(
      id: 'what',
      text: 'アプリの形はどれが近い？',
      choices: ['サッと記録する', '毎日開く相棒', '作る・編集する道具'],
    ),
    DigQuestion(
      id: 'how',
      text: 'どうやって助ける？',
      choices: ['自動でやってくれる', '知らせて支える', '見える化で気づかせる'],
    ),
    DigQuestion(
      id: 'next',
      text: '最初の一歩はどれ？',
      choices: ['まず自分が毎日使う', '知り合いに試してもらう', '似たアプリを調べる'],
    ),
  ];

  static const _firstScene = DigQuestion(
    id: 'guided_local_scene',
    axis: 'scene',
    text: '最初にこのアプリを使うのはどんな場面？',
    choices: ['困ったそのとき', '後で思い出すとき', '楽しみとして始めるとき'],
  );
  static const _firstObstacle = DigQuestion(
    id: 'guided_local_obstacle',
    axis: 'obstacle',
    text: '今のやり方で、どの段階が難しい？',
    choices: ['取りかかるまで', '作業の途中', '後で見返すとき'],
  );
  static const _firstTest = DigQuestion(
    id: 'guided_local_test',
    axis: 'test',
    text: '最初に何を確かめたい？',
    choices: ['今のやり方で詰まるところ', 'どのくらい頻繁に起きるか', '手作業でも助かるか'],
  );
  static const _firstAudience = DigQuestion(
    id: 'guided_local_audience',
    axis: 'audience',
    text: '最初に試してもらうなら、どんな人が近い？',
    choices: ['自分と同じ場面で困っている人', '今のやり方に慣れた人', '初めてその作業をする人'],
  );

  static DigQuestion firstDig(
    FirstDigContext context,
    DigStyle style,
    DigViewpoint viewpoint,
  ) {
    final initial = switch (context.firstAnswer) {
      null => _firstScene,
      QaEntry(axis: 'test') => _firstObstacle,
      _ => _firstTest,
    };
    final focused = viewpointQuestions[viewpoint] ?? const [];
    final axes = switch (viewpoint) {
      DigViewpoint.none => const <String>[],
      DigViewpoint.money => const ['audience', 'approach', 'test'],
      DigViewpoint.tech => const ['obstacle', 'test', 'approach'],
      DigViewpoint.user => const ['scene', 'approach', 'obstacle'],
    };
    for (final candidate in {
      for (var index = 0; index < focused.length; index++)
        DigQuestion(
          id: focused[index].id,
          axis: axes[index],
          text: focused[index].text,
          choices: focused[index].choices,
        ),
      initial,
      _firstObstacle,
      _firstAudience,
    }) {
      if (candidate.axis == context.firstAnswer?.axis ||
          candidate.axis == context.excludedQuestion?.axis) {
        continue;
      }
      final question = styled(candidate, style);
      if (context.acceptsQuestion(question.text)) return question;
    }
    return context.excludedQuestion ?? styled(initial, style);
  }

  /// 回答済み件数の次に出す質問。全部答えたら null。
  static DigQuestion? nextAfter(int answeredCount) {
    if (answeredCount < 0 || answeredCount >= questions.length) return null;
    return questions[answeredCount];
  }

  /// 逆張り質問の固定文（v0.2 項目3）。定型では2周目以降の4問目に出す（R-01）。
  static const DigQuestion contrarianQuestion = DigQuestion(
    id: 'contrarian',
    text: 'このアイデアが失敗するとしたら、何が原因だと思う？',
    choices: ['需要がない', '作りきれない', '続けられない'],
    isContrarian: true,
  );

  /// 視点別の定型質問セット（R-03）。定型モードでも視点選択を次の質問へ反映する。
  static const Map<DigViewpoint, List<DigQuestion>> viewpointQuestions = {
    DigViewpoint.money: [
      DigQuestion(
        id: 'money_1',
        text: 'このアプリにお金を払うとしたら、誰が一番払いそう？',
        choices: ['使う本人', 'お店や会社', 'まずは無料で広げたい'],
      ),
      DigQuestion(
        id: 'money_2',
        text: '続けるための仕組みはどれが近そう？',
        choices: ['買い切りでシンプルに', '月額でコツコツ', '基本無料＋追加機能'],
      ),
      DigQuestion(
        id: 'money_3',
        text: '無料のままでも価値を届けるなら、どこを工夫したい？',
        choices: ['広告を控えめに入れる', '自分の実績にする', 'まず検証だけ割り切る'],
      ),
    ],
    DigViewpoint.tech: [
      DigQuestion(
        id: 'tech_1',
        text: '作るときに一番むずかしそうな部分はどこ？',
        choices: ['データ保存や同期', 'AIや外部API連携', '使い心地・画面の設計'],
      ),
      DigQuestion(
        id: 'tech_2',
        text: '最初の試作はどのくらいの範囲に絞れそう？',
        choices: ['画面1〜2枚の最小版', '今ある技術だけで1週間', 'まず紙やメモで試す'],
      ),
      DigQuestion(
        id: 'tech_3',
        text: '既存の仕組みで楽できそうなところは？',
        choices: ['端末内保存だけで済ませる', '既存APIやライブラリを使う', '手作業を少し残して始める'],
      ),
    ],
    DigViewpoint.user: [
      DigQuestion(
        id: 'user_1',
        text: '使う人は、1日のどのタイミングで開きたくなりそう？',
        choices: ['朝や移動中のすきま時間', '困ったその瞬間すぐ', '夜にゆっくり振り返るとき'],
      ),
      DigQuestion(
        id: 'user_2',
        text: '初めて開いた人が「これいいな」と思う瞬間は？',
        choices: ['3秒で入力が終わったとき', '自分の状態が見えたとき', '迷わず次の一歩が分かったとき'],
      ),
      DigQuestion(
        id: 'user_3',
        text: '使う人が途中でやめてしまいそうな理由は？',
        choices: ['入力が面倒になる', '開くきっかけを忘れる', '変化や手応えが見えない'],
      ),
    ],
  };

  /// 2周目以降の定型深掘り質問（基本5問の繰り返しを防ぐ）。
  static const List<DigQuestion> deepeningQuestions = [
    DigQuestion(
      id: 'deep_1',
      text: '一番最初に使ってもらう場面を1つだけ選ぶなら？',
      choices: ['朝の準備中', '仕事や作業の合間', '寝る前の5分'],
    ),
    DigQuestion(
      id: 'deep_2',
      text: '似たアプリや今のやり方と比べて、ここだけは違う点は？',
      choices: ['とにかく速く終わる', '自分の好みに寄り添う', '余計な機能がない'],
    ),
    DigQuestion(
      id: 'deep_3',
      text: '最初のバージョンで、あえて入れない機能は？',
      choices: ['ログインや同期', '細かい設定やカスタマイズ', 'SNS共有や通知'],
    ),
    DigQuestion(
      id: 'deep_4',
      text: '使い続けてもらうための小さな工夫は？',
      choices: ['前回の続きがすぐ見える', '少し進むだけで変化が出る', '毎日でなくても責めない'],
    ),
    DigQuestion(
      id: 'deep_5',
      text: '1週間後に試作品ができたら、誰に最初に見せたい？',
      choices: ['まず自分だけで使い込む', '身近な友人・家族', 'SNSやコミュニティで公開'],
    ),
  ];

  /// 上司モード用の前置き（v0.2 項目1）。質問の骨格と選択肢は共通で、
  /// boss のときだけ各質問の前置きを詰める調子に差し替える。
  static const Map<String, String> _bossPrefixes = {
    'who': '対象をはっきりさせよう。',
    'why': '甘くないか、確認する。',
    'what': '形を決めよう。',
    'how': '実現方法を詰めよう。',
    'next': '次の一手を決めよう。',
    'contrarian': '甘い前提を疑おう。',
  };

  /// スタイルに合わせて質問を返す。friend はそのまま、boss は前置きを付ける。
  static DigQuestion styled(DigQuestion q, DigStyle style) {
    if (style == DigStyle.friend) return q;
    final prefix = _bossPrefixes[q.id] ?? '詰めよう。';
    return DigQuestion(
      id: q.id,
      text: '$prefix${q.text}',
      choices: q.choices,
      axis: q.axis,
      isContrarian: q.isContrarian,
    );
  }
}

/// 回答群から企画メモの型をローカルで整形する（AIなし版）。
class LocalMemoBuilder {
  static PlanMemo build({
    required String title,
    required List<QaEntry> answers,
    required int version,
    DateTime? now,
    bool reviewDraft = false,
  }) {
    final slots = <String, String>{};
    for (final question in FallbackQuestions.questions) {
      for (final entry in answers.reversed) {
        if (!_matchesTemplate(entry, question) ||
            entry.undecided ||
            entry.answer.trim().isEmpty) {
          continue;
        }
        slots[question.id] = entry.answer;
        break;
      }
    }

    String slot(String id) => slots[id] ?? '';

    final form = slot('what');
    final what = form.isEmpty
        ? (reviewDraft ? '' : title)
        : (title.contains('アプリ') || form.contains('アプリ'))
        ? '「$title」— $form'
        : '「$title」— $formアプリ';

    if (reviewDraft) {
      return PlanMemo(
        what: what,
        who: slot('who'),
        why: slot('why'),
        how: slot('how'),
        nextStep: slot('next'),
        openQuestions: '',
        createdAt: now ?? DateTime.now(),
        version: version,
      );
    }

    // 体力測定（v0.2 項目4）の簡易ルール。単純で説明可能に保つ:
    // - 作りやすさ ease: 「形（what）／どうやって（how）／次の一歩（next）」の
    //   3欄のうち埋まった数（最低1）。作る道筋が見えるほど高い。
    // - ワクワク度 spark: 1 +「誰に（who）」が埋まれば1 +「なぜ（why）」が
    //   埋まれば1（最大3）。誰の何を解くかが見えるほど高い。
    final buildSlots = [
      'what',
      'how',
      'next',
    ].where((id) => slot(id).isNotEmpty).length;
    final ease = buildSlots == 0 ? 1 : buildSlots;
    final spark =
        1 + (slot('who').isNotEmpty ? 1 : 0) + (slot('why').isNotEmpty ? 1 : 0);

    return PlanMemo(
      what: what,
      who: slot('who').isEmpty ? '（まだ掘れていない）' : slot('who'),
      why: slot('why').isEmpty ? '（まだ掘れていない）' : slot('why'),
      how: slot('how').isEmpty ? '（まだ掘れていない）' : slot('how'),
      nextStep: slot('next').isEmpty ? '続きを深掘りする' : slot('next'),
      createdAt: now ?? DateTime.now(),
      version: version,
      ease: ease,
      spark: spark,
    );
  }

  // 生成された質問の ID は任意。旧データでは定型の本文と一致する場合だけ使う。
  static bool _matchesTemplate(QaEntry entry, DigQuestion question) {
    if (entry.questionId != question.id || entry.contrarian) return false;
    if (entry.source != null && entry.source != AnswerSource.local) {
      return false;
    }
    return entry.question == question.text ||
        entry.question ==
            FallbackQuestions.styled(question, DigStyle.boss).text;
  }
}
