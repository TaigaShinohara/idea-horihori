import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../widgets/glass.dart';
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

  IdeaStore get store => widget.store;
  Idea get idea => widget.idea;

  Future<void> _openDig() async {
    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DigScreen(store: store, idea: idea, fromDetail: true),
      ),
    );
    // K2: 詳細から始めた深掘りが完了したら、戻った先で山場を見せる。
    if (completed == true && mounted) {
      setState(() => _celebrate = true);
    }
  }

  Future<void> _confirmArchive(BuildContext context) async {
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
          onPressed: () => store.unarchiveIdea(idea),
        ),
      ),
    );
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
            icon: const Icon(Icons.archive_outlined),
            tooltip: 'アーカイブ',
            onPressed: () => _confirmArchive(context),
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
                if (_celebrate && latest != null) ...[
                  const SizedBox(height: 10),
                  const Row(
                    children: [
                      Text('🌳', style: TextStyle(fontSize: 16)),
                      SizedBox(width: 6),
                      Text(
                        '新しいメモができたよ',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: kAccentDeep,
                        ),
                      ),
                    ],
                  ),
                ],
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
                    child: Center(child: Text('まだメモはないよ。深掘りすると育つよ。')),
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
          _MemoBody(memo: memo),
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
                      'メモ v${widget.memo.version}',
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
