import 'dig_mode.dart';
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

  /// 回答済み件数の次に出す質問。全部答えたら null。
  static DigQuestion? nextAfter(int answeredCount) {
    if (answeredCount < 0 || answeredCount >= questions.length) return null;
    return questions[answeredCount];
  }

  /// 逆張り質問の固定文（v0.2 項目3）。セッションの4問目に出す。
  static const DigQuestion contrarianQuestion = DigQuestion(
    id: 'contrarian',
    text: 'このアイデアが失敗するとしたら、何が原因だと思う？',
    choices: ['需要がない', '作りきれない', '続けられない'],
    isContrarian: true,
  );

  /// 上司モード用の前置き（v0.2 項目1）。質問の骨格と選択肢は共通で、
  /// boss のときだけ各質問の前置きを詰める調子に差し替える。
  static const Map<String, String> _bossPrefixes = {
    'who': '対象をはっきりさせよう。',
    'why': '甘くないか、確認する。',
    'what': '形を決めよう。',
    'how': '実現方法を詰めよう。',
    'next': '次の一手を決めよう。',
  };

  /// スタイルに合わせて質問を返す。friend はそのまま、boss は前置きを付ける。
  static DigQuestion styled(DigQuestion q, DigStyle style) {
    if (style == DigStyle.friend) return q;
    final prefix = _bossPrefixes[q.id] ?? '詰めよう。';
    return DigQuestion(
      id: q.id,
      text: '$prefix${q.text}',
      choices: q.choices,
      isContrarian: q.isContrarian,
    );
  }
}

/// 回答群から企画メモの型をローカルで整形する（AIなし版）。
class LocalMemoBuilder {
  static const List<String> _slotIds = ['who', 'why', 'what', 'how', 'next'];

  /// 質問文のキーワードから振り分け先の欄を推定する（テンプレ外ID用）。
  /// 「何」は汎用的なので最後に見る。
  static String? _routeByKeyword(String question) {
    if (question.contains('誰') || question.contains('ため')) return 'who';
    if (question.contains('困') || question.contains('悩')) return 'why';
    if (question.contains('どう') || question.contains('方法')) return 'how';
    if (question.contains('最初') || question.contains('次')) return 'next';
    if (question.contains('形') || question.contains('何')) return 'what';
    return null;
  }

  static PlanMemo build({
    required String title,
    required List<QaEntry> answers,
    required int version,
    DateTime? now,
  }) {
    final slots = <String, String>{for (final id in _slotIds) id: ''};

    // テンプレIDは「最後に一致した回答」を使う（再深掘りの新しい回答を
    // 優先し、古い回答でメモが固定されるのを防ぐ）。
    for (final a in answers) {
      if (_slotIds.contains(a.questionId) && a.answer.trim().isNotEmpty) {
        slots[a.questionId] = a.answer;
      }
    }

    // テンプレ外の回答（Geminiの q1, q2... など）:
    // 1) 質問文キーワードで振り分け（空き欄のみ）
    // 2) 振り分けられない／埋まっていたら空いている欄へ順に割り当て
    // 3) 最後に余ったものだけ What の補足にする
    final pool = <String>[];
    for (final a in answers) {
      if (_slotIds.contains(a.questionId)) continue;
      if (a.answer.trim().isEmpty) continue;
      final target = _routeByKeyword(a.question);
      if (target != null && slots[target]!.isEmpty) {
        slots[target] = a.answer;
      } else {
        pool.add(a.answer);
      }
    }
    final extras = <String>[];
    for (final answer in pool) {
      String emptyId = '';
      for (final id in _slotIds) {
        if (slots[id]!.isEmpty) {
          emptyId = id;
          break;
        }
      }
      if (emptyId.isEmpty) {
        extras.add(answer);
      } else {
        slots[emptyId] = answer;
      }
    }

    String slot(String id) => slots[id] ?? '';

    final form = slot('what');
    final whatBase = form.isEmpty ? title : '「$title」— $formアプリ';
    final what = extras.isEmpty ? whatBase : '$whatBase。${extras.join('。')}';

    // 体力測定（v0.2 項目4）の簡易ルール。単純で説明可能に保つ:
    // - 作りやすさ ease: 「形（what）／どうやって（how）／次の一歩（next）」の
    //   3欄のうち埋まった数（最低1）。作る道筋が見えるほど高い。
    // - ワクワク度 spark: 1 +「誰に（who）」が埋まれば1 +「なぜ（why）」が
    //   埋まれば1（最大3）。誰の何を解くかが見えるほど高い。
    final buildSlots = ['what', 'how', 'next']
        .where((id) => slot(id).isNotEmpty)
        .length;
    final ease = buildSlots == 0 ? 1 : buildSlots;
    final spark = 1 +
        (slot('who').isNotEmpty ? 1 : 0) +
        (slot('why').isNotEmpty ? 1 : 0);

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
}
