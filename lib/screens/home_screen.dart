import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../store.dart';
import '../widgets/glass.dart';
import 'archive_screen.dart';
import 'detail_screen.dart';
import 'dig_screen.dart';
import 'settings_screen.dart';

/// S1 ストック一覧（ホーム）。出すのはタイトル＋成長アイコン＋成長バーだけ。
class HomeScreen extends StatelessWidget {
  final IdeaStore store;
  const HomeScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text(
            'アイデアホリホリ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                final count = store.archivedIdeas.length;
                final label = count == 0 ? 'アーカイブ' : 'アーカイブ $count件';
                void openArchive() {
                  if (!store.loaded || ModalRoute.of(context)?.isCurrent != true) {
                    return;
                  }
                  Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ArchiveScreen(store: store),
                    ),
                  );
                }

                return Semantics(
                  label: label,
                  button: true,
                  onTap: store.loaded ? openArchive : null,
                  excludeSemantics: true,
                  child: IconButton(
                    tooltip: label,
                    onPressed: store.loaded ? openArchive : null,
                    icon: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.archive_outlined),
                        if (count > 0)
                          Positioned(
                            right: -10,
                            top: -6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: kButtonFill,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                '$count',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: store,
              builder: (context, _) => IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '設定',
                onPressed: store.loaded
                    ? () {
                        if (ModalRoute.of(context)?.isCurrent != true) return;
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SettingsScreen(store: store),
                          ),
                        );
                      }
                    : null,
              ),
            ),
          ],
        ),
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            if (!store.loaded) {
              if (store.loadError case final error?) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: GlassCard(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            error,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: store.load,
                            child: const Text('再読み込み'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              return const Center(child: CircularProgressIndicator());
            }
            final ideas = store.visibleIdeas;
            if (ideas.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ExcludeSemantics(
                        child: Text('🌱', style: TextStyle(fontSize: 44)),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '思いついたら、1行で残しておきましょう',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      const _EmptyFlowHint(),
                      if (store.ideasRecoveryNotice case final notice?) ...[
                        const SizedBox(height: 16),
                        _RecoveryNoticeBanner(
                          notice: notice,
                          onDismiss: store.ideasWritable
                              ? store.dismissRecoveryNotice
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }
            final recovery = store.ideasRecoveryNotice;
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: ideas.length + (recovery == null ? 0 : 1),
              itemBuilder: (context, i) {
                if (recovery != null && i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _RecoveryNoticeBanner(
                      notice: recovery,
                      onDismiss: store.ideasWritable
                          ? store.dismissRecoveryNotice
                          : null,
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _IdeaCard(
                    store: store,
                    idea: ideas[i - (recovery == null ? 0 : 1)],
                  ),
                );
              },
            );
          },
        ),
        floatingActionButton: AnimatedBuilder(
          animation: store,
          builder: (context, _) => FloatingActionButton.extended(
            backgroundColor: kButtonFill,
            foregroundColor: Colors.white,
            onPressed: store.loaded ? () => _showQuickAdd(context) : null,
            icon: const Icon(Icons.add),
            label: const Text('アイデアを追加'),
          ),
        ),
      ),
    );
  }

  Future<void> _showQuickAdd(BuildContext context) async {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuickAddSheet(store: store),
    );
  }
}

class _RecoveryNoticeBanner extends StatelessWidget {
  final String notice;
  final VoidCallback? onDismiss;
  const _RecoveryNoticeBanner({required this.notice, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: '通知を閉じる',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

class _QuickAddSheet extends StatefulWidget {
  final IdeaStore store;
  const _QuickAddSheet({required this.store});

  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving || _title.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.addIdea(_title.text, _note.text);
      HapticFeedback.lightImpact();
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存できませんでした。入力内容を残しています。';
        });
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_saving,
    child: GlassSheetSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            enabled: !_saving,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            style: const TextStyle(fontSize: 17),
            decoration: glassInputDecoration(
              context,
              hintText: 'どんなアプリですか？ 1行で',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            enabled: !_saving,
            maxLines: 4,
            minLines: 1,
            style: const TextStyle(fontSize: 14),
            decoration: glassInputDecoration(
              context,
              hintText: 'メモ（任意）',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kButtonFill,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: _saving || _title.text.trim().isEmpty ? null : _save,
            child: Text(_saving ? '保存中…' : 'ストックする'),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _IdeaCard extends StatelessWidget {
  final IdeaStore store;
  final Idea idea;
  const _IdeaCard({required this.store, required this.idea});

  void _open(BuildContext context, Widget screen) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.push<void>(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final stage = idea.stage;
    final resumable = idea.resumableSession;
    final isReviewPending =
        resumable?.reviewOpen == true && resumable?.reviewDraft != null;
    final digLabel = isReviewPending
        ? '下書きを確認'
        : resumable != null
        ? 'つづきを掘る'
        : idea.memos.isNotEmpty
        ? 'もっと深掘り'
        : '深掘り';
    return GlassCard(
      onTap: () => _open(
        context,
        DetailScreen(store: store, idea: idea),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StageBadge(stage: stage, emojiSize: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  idea.title,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GrowthBar(value: idea.growthValue, stage: stage),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: accentTonalFill(context),
                foregroundColor: accentTextColor(context),
              ),
              onPressed: () => _open(
                context,
                DigScreen(store: store, idea: idea),
              ),
              icon: Icon(
                isReviewPending
                    ? Icons.fact_check_outlined
                    : Icons.chat_bubble_outline,
                size: 18,
              ),
              label: Text(digLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFlowHint extends StatelessWidget {
  const _EmptyFlowHint();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget step(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: muted),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 13, color: muted)),
      ],
    );
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          step(Icons.edit_note_outlined, '1行メモ'),
          ExcludeSemantics(
            child: Icon(Icons.arrow_forward, size: 14, color: muted),
          ),
          step(Icons.chat_bubble_outline, '質問に答える'),
          ExcludeSemantics(
            child: Icon(Icons.arrow_forward, size: 14, color: muted),
          ),
          step(Icons.description_outlined, '企画メモ'),
        ],
      ),
    );
  }
}
