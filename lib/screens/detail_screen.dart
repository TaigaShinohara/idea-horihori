import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai_backend.dart';
import '../models.dart';
import '../store.dart';
import '../widgets/glass.dart';
import '../widgets/memo_input_view.dart';
import 'dev_brief_screen.dart';
import 'dig_screen.dart';

/// S4 アイデア詳細＝企画メモ。メモは版として積まれ、古い版も見返せる。
///
/// v0.1.2 の変更:
/// - K5: 最新メモを主役に最初・最大で置き、深掘りCTAはメモの後へ降格
///   （トーンを落とす）。旧メモは折りたたみ（見出し「メモ vN」のみ）。
/// - K2: 深掘り完了直後は成長バーが伸び、「メモができたよ」を1行出す。
/// - K6: 成長段階ラベルを併記する。
class DetailScreen extends StatefulWidget {
  final IdeaStore store;
  final Idea idea;

  /// 深掘り完了直後の遷移かどうか（K2 の山場表示に使う）。
  final bool highlightLatestMemo;
  const DetailScreen({
    super.key,
    required this.store,
    required this.idea,
    this.highlightLatestMemo = false,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late int _celebrateCount = widget.highlightLatestMemo ? 1 : 0;
  bool _editing = false;
  bool _archiving = false;
  bool _namesOpen = false;
  bool _openingDig = false;
  bool _openingBrief = false;

  IdeaStore get store => widget.store;
  Idea get idea => widget.idea;

  Future<void> _editIdea(BuildContext context) async {
    if (_editing) return;
    setState(() => _editing = true);
    try {
      final values = await showDialog<(String, String)>(
        context: context,
        builder: (_) => _EditIdeaDialog(title: idea.title, note: idea.note),
      );
      if (values == null || !mounted) return;
      final previous = (idea.title, idea.note);
      idea.title = values.$1;
      idea.note = values.$2;
      try {
        await store.updateIdea(idea);
      } catch (_) {
        idea.title = previous.$1;
        idea.note = previous.$2;
        if (mounted) _showSaveError();
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _showNameCandidates(BuildContext context) async {
    if (_namesOpen ||
        _archiving ||
        _editing ||
        _openingDig ||
        _openingBrief ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _namesOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _NameCandidatesSheet(store: store, idea: idea),
      );
    } finally {
      _namesOpen = false;
    }
  }

  Future<void> _openBrief({PlanMemo? memo}) async {
    if (_openingBrief ||
        _archiving ||
        _editing ||
        _namesOpen ||
        _openingDig ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _openingBrief = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => DevBriefScreen(idea: idea, memo: memo)),
      );
    } finally {
      _openingBrief = false;
    }
  }

  Future<void> _openDig() async {
    if (_openingDig ||
        _archiving ||
        _editing ||
        _namesOpen ||
        _openingBrief ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _openingDig = true;
    try {
      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => DigScreen(store: store, idea: idea, fromDetail: true),
        ),
      );
      if (completed == true && mounted) {
        setState(() => _celebrateCount++);
      }
    } finally {
      _openingDig = false;
    }
  }

  void _showSaveError() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('変更を保存できませんでした。もう一度お試しください。')));

  Future<void> _confirmArchive(BuildContext context) async {
    if (_archiving || _editing) return;
    setState(() => _archiving = true);
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('アーカイブしますか？'),
          content: const Text('一覧からは隠れますが、あとで戻せます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('アーカイブする'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      await store.archiveIdea(idea);
      if (!context.mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('アーカイブしました'),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () async {
              try {
                await store.unarchiveIdea(idea);
              } catch (_) {
                if (messenger.mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('アイデアを一覧に戻せませんでした。')),
                  );
                }
              }
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted) _showSaveError();
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentText = accentTextColor(context);
    return PopScope(
      canPop: !(_editing || _archiving),
      child: GlassBackground(
        child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('企画メモ'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'タイトルとメモを編集',
              onPressed: _editing || _archiving ? null : () => _editIdea(context),
            ),
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: 'アーカイブ',
              onPressed:
                  _editing || _archiving ? null : () => _confirmArchive(context),
            ),
          ],
        ),
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final memos = idea.memos.reversed.toList();
            final latest = memos.isEmpty ? null : memos.first;
            final older = memos.length <= 1 ? <PlanMemo>[] : memos.sublist(1);
            final hasAnswers = idea.sessions.any((s) => s.answers.isNotEmpty);
            final hasResumable = idea.resumableSession != null;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StageBadge(stage: idea.stage, emojiSize: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        idea.title,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                if (idea.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    idea.note,
                    style: const TextStyle(fontSize: 14, height: 1.6),
                  ),
                ],
                const SizedBox(height: 12),
                GrowthBar(
                  key: ValueKey('growth-$_celebrateCount'),
                  value: idea.growthValue,
                  stage: idea.stage,
                  animate: _celebrateCount > 0,
                ),
                const SizedBox(height: 16),
                if (latest == null) ...[
                  GlassCard(
                    child: Text(
                      hasAnswers
                          ? '深掘りの途中です。続きに答えると企画メモにまとまります。'
                          : 'まだ企画メモはありません',
                      style: const TextStyle(fontSize: 14, height: 1.6),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kButtonFill,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: _openDig,
                    icon: const Icon(Icons.chat_bubble_outline, size: 19),
                    label: Text(hasResumable ? 'つづきを掘る' : '深掘りする'),
                  ),
                  if (hasAnswers) ...[
                    const SizedBox(height: 20),
                    const Text(
                      '深掘りの記録',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final session in idea.sessions)
                      if (session.answers.isNotEmpty) ...[
                        _SessionHistoryTile(session: session),
                        const SizedBox(height: 10),
                      ],
                  ],
                ] else ...[
                  // K5: 最新メモが主役（最初・最大）。S-01: 完了直後は静かなフェードイン。
                  _CelebratedFadeIn(
                    key: ValueKey('memo-$_celebrateCount-${latest.version}'),
                    animate: _celebrateCount > 0,
                    child: _MemoView(memo: latest, idea: idea),
                  ),
                  const SizedBox(height: 14),
                  // K5: CTAはメモの後へ降格し、トーンも落とす。
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: accentTonalFill(context),
                      foregroundColor: accentText,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _openDig,
                    icon: const Icon(Icons.chat_bubble_outline, size: 19),
                    label: Text(hasResumable ? 'つづきを掘る' : 'もっと深掘り'),
                  ),
                  const SizedBox(height: 10),
                  // v0.2 項目5・6: メモがある時だけ出せる書き出し／名前候補。
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _openBrief,
                          icon: const Icon(
                            Icons.description_outlined,
                            size: 18,
                          ),
                          label: const Text('指示書'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _showNameCandidates(context),
                          icon: const Icon(Icons.badge_outlined, size: 18),
                          label: const Text('名前候補'),
                        ),
                      ),
                    ],
                  ),
                  if (hasAnswers) ...[
                    const SizedBox(height: 20),
                    const Text(
                      '深掘りの記録',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final session in idea.sessions)
                      if (session.answers.isNotEmpty) ...[
                        _SessionHistoryTile(session: session),
                        const SizedBox(height: 10),
                      ],
                  ],
                  if (older.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'これまでのメモ',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final memo in older) ...[
                      _OldMemoTile(
                        memo: memo,
                        idea: idea,
                        onOpenBrief: () => _openBrief(memo: memo),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
  }
}

/// 完了直後の静かな出現アニメーション（300msフェード。disableAnimationsOf を尊重）。
class _CelebratedFadeIn extends StatelessWidget {
  final bool animate;
  final Widget child;
  const _CelebratedFadeIn({
    super.key,
    required this.animate,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: child,
    );
  }
}

/// メモの中身（型の5欄）。最新メモ・旧メモ共通。
class _MemoBody extends StatelessWidget {
  final PlanMemo memo;
  const _MemoBody({required this.memo});

  @override
  Widget build(BuildContext context) {
    final labelColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final openQuestions = memo.openQuestions;
    if (openQuestions != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            '決めたこと',
            [
              if (memo.what.isNotEmpty) '何を作る　${memo.what}',
              if (memo.who.isNotEmpty) '誰に　${memo.who}',
              if (memo.why.isNotEmpty) 'なぜ　${memo.why}',
              if (memo.how.isNotEmpty) 'どうやって　${memo.how}',
            ]
                .join('\n'),
            labelColor,
          ),
          _row('未確認のこと', openQuestions, labelColor),
          _row('次に試すこと', memo.nextStep, labelColor, last: true),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('何を作る', memo.what, labelColor),
        _row('誰に', memo.who, labelColor),
        _row('なぜ', memo.why, labelColor),
        _row('どうやって', memo.how, labelColor),
        _row('次の一歩', memo.nextStep, labelColor, last: true),
      ],
    );
  }

  Widget _row(String label, String value, Color labelColor, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: labelColor,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontSize: 15, height: 1.6),
          ),
        ],
      ),
    );
  }
}

/// 最新メモの表示（読み物ガラスで大きく）。
class _MemoView extends StatelessWidget {
  final PlanMemo memo;
  final Idea idea;
  const _MemoView({required this.memo, required this.idea});

  @override
  Widget build(BuildContext context) {
    final accentText = accentTextColor(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final fitnessVisual = [
      if (memo.ease != null) '作りやすさ ${fitnessDots(memo.ease!)}',
      if (memo.spark != null) 'ワクワク度 ${fitnessDots(memo.spark!)}',
    ].join(' ／ ');
    final fitnessSemantics = [
      if (memo.ease != null) '作りやすさ 3段階中${memo.ease!.clamp(1, 3)}',
      if (memo.spark != null) 'ワクワク度 3段階中${memo.spark!.clamp(1, 3)}',
    ].join('、');

    return ReadingGlass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'メモ v${memo.version}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: accentText,
                ),
              ),
              const SizedBox(width: 8),
              if (memo.source case final source?)
                Flexible(
                  child: Text(
                    source.label,
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: muted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _MemoBody(memo: memo),
          if (memo.input case final input?)
            MemoInputView(input: input, idea: idea),
          // 体力測定（項目4）: 値がある時だけ、末尾に静かに1行添える。
          if (memo.hasFitness) ...[
            const SizedBox(height: 14),
            Semantics(
              container: true,
              label: fitnessSemantics,
              child: ExcludeSemantics(
                child: Text(
                  fitnessVisual,
                  style: TextStyle(fontSize: 13, color: accentText),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 深掘りの記録（項目7）: セッションごとの折りたたみ。開始日＋Q→A を時系列で出す。
class _SessionHistoryTile extends StatefulWidget {
  final DigSession session;
  const _SessionHistoryTile({required this.session});

  @override
  State<_SessionHistoryTile> createState() => _SessionHistoryTileState();
}

class _SessionHistoryTileState extends State<_SessionHistoryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final d = s.startedAt;
    final accentText = accentTextColor(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${d.year}/${d.month}/${d.day} の深掘り（${s.answers.length}問）',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: accentText,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final a in s.answers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Q: ${a.question}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              height: 1.5,
                            ),
                          ),
                          Text(
                            'A: ${a.answer}',
                            style: const TextStyle(fontSize: 14, height: 1.6),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 旧メモの折りたたみ（K5）。閉じた見出しは「メモ vN」だけ、展開内ヘッダ右端に生成元。
class _OldMemoTile extends StatefulWidget {
  final PlanMemo memo;
  final Idea idea;
  final VoidCallback onOpenBrief;
  const _OldMemoTile({
    required this.memo,
    required this.idea,
    required this.onOpenBrief,
  });

  @override
  State<_OldMemoTile> createState() => _OldMemoTileState();
}

class _OldMemoTileState extends State<_OldMemoTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final accentText = accentTextColor(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'メモ v${widget.memo.version}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: accentText,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.memo.source case final source?) ...[
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        source.label,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  _MemoBody(memo: widget.memo),
                  if (widget.memo.hasFitness) ...[
                    const SizedBox(height: 12),
                    if (widget.memo.ease case final ease?)
                      Text('作りやすさ ${fitnessDots(ease)}'),
                    if (widget.memo.spark case final spark?)
                      Text('ワクワク度 ${fitnessDots(spark)}'),
                  ],
                  if (widget.memo.input case final input?) ...[
                    MemoInputView(input: input, idea: widget.idea),
                    TextButton(
                      onPressed: widget.onOpenBrief,
                      child: const Text('この版の指示書'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EditIdeaDialog extends StatefulWidget {
  final String title;
  final String note;
  const _EditIdeaDialog({required this.title, required this.note});

  @override
  State<_EditIdeaDialog> createState() => _EditIdeaDialogState();
}

class _EditIdeaDialogState extends State<_EditIdeaDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _note = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('タイトルとメモを編集'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _title,
          autofocus: true,
          decoration: glassInputDecoration(context, labelText: 'タイトル'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLines: 3,
          decoration: glassInputDecoration(context, labelText: 'メモ'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        onPressed: _title.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (
                _title.text.trim(),
                _note.text.trim(),
              )),
        child: const Text('保存'),
      ),
    ],
  );
}

class _NameCandidatesSheet extends StatefulWidget {
  final IdeaStore store;
  final Idea idea;
  const _NameCandidatesSheet({required this.store, required this.idea});

  @override
  State<_NameCandidatesSheet> createState() => _NameCandidatesSheetState();
}

class _NameCandidatesSheetState extends State<_NameCandidatesSheet>
    with WidgetsBindingObserver {
  late final ResilientBackend _backend;
  late Future<List<String>> _names;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backend = widget.store.backend()
      ..onPhase = (_) {
        if (mounted) setState(() {});
      };
    _names = _backend.nameCandidates(idea: widget.idea);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backend.cancelPending();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backend.cancelPending();
    super.dispose();
  }

  void _generate({bool templateOnly = false}) {
    _backend.cancelPending();
    final names = _backend.nameCandidates(
      idea: widget.idea,
      templateOnly: templateOnly,
    );
    setState(() => _names = names);
  }

  Future<void> _copyName(String name) async {
    var message = '「$name」をコピーしました';
    try {
      await Clipboard.setData(ClipboardData(text: name));
    } catch (_) {
      message = 'コピーできませんでした。';
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmApplyTitle(String name) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('タイトルを変更しますか？'),
          content: Text('「$name」をアイデアのタイトルに設定します。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('変更する'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final previous = widget.idea.title;
      widget.idea.title = name;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await widget.store.updateIdea(widget.idea);
        if (mounted) {
          Navigator.pop(context);
          messenger.showSnackBar(
            SnackBar(content: Text('タイトルを「$name」に変更しました')),
          );
        }
      } catch (_) {
        widget.idea.title = previous;
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(content: Text('タイトルを変更できませんでした。')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final accentText = accentTextColor(context);
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _backend.cancelPending();
      },
      child: GlassSheetSurface(
        child: FutureBuilder<List<String>>(
          future: _names,
          builder: (context, snapshot) {
            final waiting = snapshot.connectionState != ConnectionState.done;
            final names = snapshot.data ?? const [];
            final source = _backend.lastSource;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text(
                      '名前の候補',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (!waiting && source != null)
                      Text(
                        source.label,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (waiting) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  const Text('名前の候補を考えています…'),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => _generate(templateOnly: true),
                      child: const Text('定型で続ける'),
                    ),
                  ),
                ] else if (snapshot.hasError || names.isEmpty) ...[
                  const Text('名前の候補をつくれませんでした。'),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _generate,
                      child: const Text('もう一度試す'),
                    ),
                  ),
                ] else ...[
                  if (_backend.lastRemoteError case final failure?) ...[
                    Text(
                      failure.message,
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final name in names)
                    Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: () => _copyName(name),
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '$nameをコピー',
                                  onPressed: () => _copyName(name),
                                  icon: Icon(
                                    Icons.copy,
                                    size: 18,
                                    color: muted,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _applying
                                      ? null
                                      : () => _confirmApplyTitle(name),
                                  child: Text(
                                    'タイトルにする',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: accentText,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
