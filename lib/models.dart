import 'dart:math' as math;

import 'dig_mode.dart';

/// 成長段階: 種(登録直後) → 芽(深掘り中) → 実(メモ1つ以上)
enum GrowthStage { seed, sprout, fruit }

extension GrowthStageX on GrowthStage {
  String get emoji => switch (this) {
        GrowthStage.seed => '🌱',
        GrowthStage.sprout => '🌿',
        GrowthStage.fruit => '🌳',
      };
  String get label => switch (this) {
        GrowthStage.seed => '種',
        GrowthStage.sprout => '芽',
        GrowthStage.fruit => '実',
      };
}

/// AI（またはフォールバック）が出す質問1つ。
class DigQuestion {
  final String id;
  final String text;
  final List<String> choices; // 最大3つ。3つ目は「広げる」選択肢

  /// 逆張り質問かどうか（v0.2 項目3）。旧データには無いので既定 false。
  final bool isContrarian;
  const DigQuestion({
    required this.id,
    required this.text,
    required this.choices,
    this.isContrarian = false,
  });

  DigQuestion copyWith({bool? isContrarian}) => DigQuestion(
        id: id,
        text: text,
        choices: choices,
        isContrarian: isContrarian ?? this.isContrarian,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'choices': choices,
        'isContrarian': isContrarian,
      };
  factory DigQuestion.fromJson(Map<String, dynamic> j) => DigQuestion(
        id: j['id'] as String,
        text: j['text'] as String,
        choices: (j['choices'] as List).map((e) => e.toString()).toList(),
        isContrarian: j['isContrarian'] as bool? ?? false,
      );
}

/// 質問への回答1件。
class QaEntry {
  final String questionId;
  final String question;
  final String answer;

  /// 回答時に提示されていた選択肢（v0.2 項目7）。
  /// 「1問もどる」で質問を復元するために記録する。旧データでは null で、
  /// その場合は「もどる」対象にできない。
  final List<String>? choices;

  /// 逆張り質問への回答かどうか（v0.2 項目3）。旧データでは false。
  final bool contrarian;
  const QaEntry({
    required this.questionId,
    required this.question,
    required this.answer,
    this.choices,
    this.contrarian = false,
  });

  Map<String, dynamic> toJson() => {
        'questionId': questionId,
        'question': question,
        'answer': answer,
        'choices': choices,
        'contrarian': contrarian,
      };
  factory QaEntry.fromJson(Map<String, dynamic> j) => QaEntry(
        questionId: j['questionId'] as String,
        question: j['question'] as String,
        answer: j['answer'] as String,
        choices: (j['choices'] as List?)?.map((e) => e.toString()).toList(),
        contrarian: j['contrarian'] as bool? ?? false,
      );
}

/// 企画メモ（型: What / 誰に / なぜ / どうやって / 次の一歩）。
/// アイデアごとに版として積む（上書きしない）。
class PlanMemo {
  final String what;
  final String who;
  final String why;
  final String how;
  final String nextStep;
  final DateTime createdAt;
  final int version;

  /// 企画の体力測定（v0.2 項目4）: 作りやすさ／ワクワク度（各1〜3）。
  /// 旧メモには無いので nullable。null のときは表示自体を出さない。
  final int? ease;
  final int? spark;
  const PlanMemo({
    required this.what,
    required this.who,
    required this.why,
    required this.how,
    required this.nextStep,
    required this.createdAt,
    required this.version,
    this.ease,
    this.spark,
  });

  /// 体力測定が1つでも入っているか。
  bool get hasFitness => ease != null || spark != null;

  Map<String, dynamic> toJson() => {
        'what': what,
        'who': who,
        'why': why,
        'how': how,
        'nextStep': nextStep,
        'createdAt': createdAt.toIso8601String(),
        'version': version,
        'ease': ease,
        'spark': spark,
      };
  factory PlanMemo.fromJson(Map<String, dynamic> j) => PlanMemo(
        what: j['what'] as String? ?? '',
        who: j['who'] as String? ?? '',
        why: j['why'] as String? ?? '',
        how: j['how'] as String? ?? '',
        nextStep: j['nextStep'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        version: j['version'] as int? ?? 1,
        ease: fitnessValueOrNull(j['ease']),
        spark: fitnessValueOrNull(j['spark']),
      );
}

/// 体力測定の値を 1〜3 に収める。範囲外・欠落・型違いは null（表示なし）。
int? fitnessValueOrNull(Object? v) {
  if (v is! num) return null;
  final i = v.round();
  return (i >= 1 && i <= 3) ? i : null;
}

/// 体力測定の3段階ドット表示（例: 2 → 「●●○」）。数字で追い詰めない表示用。
String fitnessDots(int value) {
  final v = value.clamp(1, 3);
  return '●' * v + '○' * (3 - v);
}

/// 深掘りセッション。途中保存・再開できるよう状態を全部持つ。
class DigSession {
  final String id;
  final DateTime startedAt;
  final List<QaEntry> answers;
  DigQuestion? pendingQuestion; // 次に答える質問（再開時に復元）
  bool finished;

  /// 視点掘りの視点（v0.2 項目2）。旧データは none 扱い。
  DigViewpoint viewpoint;

  /// 逆張り質問を既に出したか（v0.2 項目3）。1セッション1回まで。
  bool contrarianAsked;
  DigSession({
    required this.id,
    required this.startedAt,
    List<QaEntry>? answers,
    this.pendingQuestion,
    this.finished = false,
    this.viewpoint = DigViewpoint.none,
    this.contrarianAsked = false,
  }) : answers = answers ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'answers': answers.map((e) => e.toJson()).toList(),
        'pendingQuestion': pendingQuestion?.toJson(),
        'finished': finished,
        'viewpoint': viewpoint.storageValue,
        'contrarianAsked': contrarianAsked,
      };
  factory DigSession.fromJson(Map<String, dynamic> j) => DigSession(
        id: j['id'] as String,
        startedAt: DateTime.tryParse(j['startedAt'] as String? ?? '') ?? DateTime.now(),
        answers: (j['answers'] as List? ?? [])
            .map((e) => QaEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        pendingQuestion: j['pendingQuestion'] == null
            ? null
            : DigQuestion.fromJson(j['pendingQuestion'] as Map<String, dynamic>),
        finished: j['finished'] as bool? ?? false,
        viewpoint: DigViewpointX.fromStorage(j['viewpoint'] as String?),
        contrarianAsked: j['contrarianAsked'] as bool? ?? false,
      );
}

/// アイデア1件。
class Idea {
  final String id;
  String title;
  String note;
  final DateTime createdAt;
  final List<DigSession> sessions;
  final List<PlanMemo> memos;
  bool archived;
  Idea({
    required this.id,
    required this.title,
    this.note = '',
    required this.createdAt,
    List<DigSession>? sessions,
    List<PlanMemo>? memos,
    this.archived = false,
  })  : sessions = sessions ?? [],
        memos = memos ?? [];

  int get totalAnswers =>
      sessions.fold(0, (sum, s) => sum + s.answers.length);

  /// 未完了で再開できるセッション（最後のもの）。
  DigSession? get resumableSession {
    for (final s in sessions.reversed) {
      if (!s.finished) return s;
    }
    return null;
  }

  GrowthStage get stage => stageFor(this);
  double get growthValue => growthValueFor(this);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'sessions': sessions.map((e) => e.toJson()).toList(),
        'memos': memos.map((e) => e.toJson()).toList(),
        'archived': archived,
      };
  factory Idea.fromJson(Map<String, dynamic> j) => Idea(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        note: j['note'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        sessions: (j['sessions'] as List? ?? [])
            .map((e) => DigSession.fromJson(e as Map<String, dynamic>))
            .toList(),
        memos: (j['memos'] as List? ?? [])
            .map((e) => PlanMemo.fromJson(e as Map<String, dynamic>))
            .toList(),
        archived: j['archived'] as bool? ?? false,
      );
}

/// 成長段階の判定（純ロジック）。
GrowthStage stageFor(Idea idea) {
  if (idea.memos.isNotEmpty) return GrowthStage.fruit;
  if (idea.totalAnswers > 0) return GrowthStage.sprout;
  return GrowthStage.seed;
}

/// 読み上げ用の成長ラベル（K6）。段階名と成長度を言葉で返す。
String growthSemanticsLabel(GrowthStage stage, double value) =>
    '成長段階は${stage.label}、成長度は${(value.clamp(0.0, 1.0) * 100).round()}パーセント';

/// 成長バー用の値 0.0–1.0（純ロジック）。％表示はしない前提の内部値。
double growthValueFor(Idea idea) {
  if (idea.memos.isNotEmpty) {
    // メモが積まれるほど満ちる（3版で満杯）。
    return 0.7 + 0.3 * (math.min(idea.memos.length, 3) / 3);
  }
  if (idea.totalAnswers > 0) {
    // 回答5件で芽の上限 0.65。
    return 0.2 + 0.45 * (math.min(idea.totalAnswers, 5) / 5);
  }
  return 0.12; // 種でも少しだけ見える
}
