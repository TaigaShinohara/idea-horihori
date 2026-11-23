import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../models.dart';
import '../store.dart';
import '../widgets/glass.dart';
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
  late bool _celebrate = widget.highlightLatestMemo;
  bool _editing = false;
  bool _archiving = false;
  bool _namesOpen = false;
  bool _openingDig = false;

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
    if (_namesOpen) return;
    _namesOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _NameCandidatesSheet(store: store, idea: idea),
      );
    } finally {
      _namesOpen = false;
    }
  }

  Future<void> _openDig() async {
    if (_openingDig || _archiving || _editing) return;
    _openingDig = true;
    try {
      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => DigScreen(store: store, idea: idea, fromDetail: true),
        ),
      );
      if (completed == true && mounted) setState(() => _celebrate = true);
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
          title: const Text('アーカイブする？'),
          content: const Text('一覧からは消えるけど、あとで戻せるよ。'),
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
          content: const Text('アーカイブした'),
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('企画メモ'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'タイトルとメモを編集',
            onPressed: _editing || _archiving ? null : () => _editIdea(context),
          ),
          IconButton(
            icon: const Icon(Icons.archive_outlined),
            tooltip: 'アーカイブ',
            onPressed: _editing || _archiving ? null : () => _confirmArchive(context),
          ),
        ],
      ),
      body: GlassBackground(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final memos = idea.memos.reversed.toList();
            final latest = memos.isEmpty ? null : memos.first;
            final older = memos.length <= 1 ? <PlanMemo>[] : memos.sublist(1);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
                            fontSize: 19, fontWeight: FontWeight.bold, height: 1.5),
                      ),
                    ),
                  ],
                ),
                if (idea.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(idea.note, style: const TextStyle(fontSize: 14, height: 1.6)),
                ],
                const SizedBox(height: 12),
                GrowthBar(
                  value: idea.growthValue,
                  stage: idea.stage,
                  animate: _celebrate,
                ),
                const SizedBox(height: 16),
                if (latest == null) ...[
                  // メモがまだ無い時だけ、深掘りCTAが主役でよい。
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kButtonFill,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: _openDig,
                    icon: const Icon(Icons.terrain, size: 19),
                    label: const Text('深掘りする'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('まだメモはないよ')),
                  ),
                ] else ...[
                  // K5: 最新メモが主役（最初・最大）。
                  _MemoView(memo: latest),
                  const SizedBox(height: 14),
                  // K5: CTAはメモの後へ降格し、トーンも落とす。
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccent.withValues(alpha: 0.16),
                      foregroundColor: kAccentDeep,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _openDig,
                    icon: const Icon(Icons.terrain, size: 19),
                    label: const Text('もっと深掘り'),
                  ),
                  const SizedBox(height: 10),
                  // v0.2 項目5・6: メモがある時だけ出せる書き出し／名前候補。
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DevBriefScreen(idea: idea),
                            ),
                          ),
                          icon: const Icon(Icons.description_outlined,
                              size: 18),
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
                  if (idea.sessions.any((s) => s.answers.isNotEmpty)) ...[
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
                      _OldMemoTile(memo: memo),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// メモの中身（型の5欄）。最新メモ・旧メモ共通。
class _MemoBody extends StatelessWidget {
  final PlanMemo memo;
  const _MemoBody({required this.memo});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('何を作る', memo.what),
        _row('誰に', memo.who),
        _row('なぜ', memo.why),
        _row('どうやって', memo.how),
        _row('次の一歩', memo.nextStep, last: true),
      ],
    );
  }

  Widget _row(String label, String value, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(value.isEmpty ? '—' : value,
              style: const TextStyle(fontSize: 15, height: 1.6)),
        ],
      ),
    );
  }
}

/// 最新メモの表示（読み物ガラスで大きく）。
class _MemoView extends StatelessWidget {
  final PlanMemo memo;
  const _MemoView({required this.memo});

  @override
  Widget build(BuildContext context) {
    return ReadingGlass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('メモ v${memo.version}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold, color: kAccentDeep)),
          const SizedBox(height: 10),
          if (memo.source case final source?)
            Text('生成元  ${source.label}', style: const TextStyle(fontSize: 12)),
          _MemoBody(memo: memo),
          // 体力測定（項目4）: 値がある時だけ、末尾に静かに1行添える。
          if (memo.hasFitness) ...[
            const SizedBox(height: 12),
            Text(
              [
                if (memo.ease != null)
                  '作りやすさ ${fitnessDots(memo.ease!)}',
                if (memo.spark != null)
                  'ワクワク度 ${fitnessDots(memo.spark!)}',
              ].join(' ／ '),
              style: const TextStyle(fontSize: 13, color: kAccentDeep),
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
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d.year}/${d.month}/${d.day} の深掘り（${s.answers.length}問）',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: kAccentDeep),
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                ],
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
                          Text('Q: ${a.question}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  height: 1.5)),
                          Text('A: ${a.answer}',
                              style:
                                  const TextStyle(fontSize: 14, height: 1.6)),
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

/// 旧メモの折りたたみ（K5）。見出しは「メモ vN」だけ、タップで展開する。
class _OldMemoTile extends StatefulWidget {
  final PlanMemo memo;
  const _OldMemoTile({required this.memo});

  @override
  State<_OldMemoTile> createState() => _OldMemoTileState();
}

class _OldMemoTileState extends State<_OldMemoTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'メモ v${widget.memo.version}'
                      '${widget.memo.source == null ? '' : '  ${widget.memo.source!.label}'}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: kAccentDeep),
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _MemoBody(memo: widget.memo),
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
          decoration: const InputDecoration(labelText: 'タイトル'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'メモ'),
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
  AiPhase? _phase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backend = widget.store.backend()
      ..onPhase = (phase) {
        if (mounted) setState(() => _phase = phase);
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
    _phase = null;
    final names = _backend.nameCandidates(
      idea: widget.idea,
      templateOnly: templateOnly,
    );
    setState(() => _names = names);
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _backend.cancelPending();
    },
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                const Text(
                  '名前の候補',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                if (waiting) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    _phase == AiPhase.cloud
                        ? 'Gemini APIで生成中…'
                        : '端末AIを確認・生成中…',
                  ),
                  TextButton(
                    onPressed: () => _generate(templateOnly: true),
                    child: const Text('定型で続ける'),
                  ),
                ] else if (snapshot.hasError || names.isEmpty) ...[
                  const Text('名前候補の生成が完了しませんでした。'),
                  TextButton(onPressed: _generate, child: const Text('もう一度試す')),
                ] else ...[
                  if (source != null) Text('生成元  ${source.label}'),
                  if (_backend.lastRemoteError case final failure?)
                    Text(failure.message),
                  for (final name in names)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(name, style: const TextStyle(fontSize: 16)),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}
