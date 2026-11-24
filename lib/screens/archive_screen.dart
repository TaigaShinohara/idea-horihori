import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../widgets/glass.dart';

/// アーカイブ済みアイデアの一覧。ここから一覧へ戻す／完全に削除できる。
/// （v0.1.0 ではアーカイブすると戻す手段がなく「消えた」ように見えた）
class ArchiveScreen extends StatelessWidget {
  final IdeaStore store;
  const ArchiveScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('アーカイブ'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final archived = store.archivedIdeas;
            if (archived.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          Icons.archive_outlined,
                          size: 44,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'アーカイブはありません',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: archived.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ArchivedCard(store: store, idea: archived[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ArchivedCard extends StatefulWidget {
  final IdeaStore store;
  final Idea idea;
  const _ArchivedCard({required this.store, required this.idea});

  @override
  State<_ArchivedCard> createState() => _ArchivedCardState();
}

class _ArchivedCardState extends State<_ArchivedCard> {
  bool _busy = false;

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.store.unarchiveIdea(widget.idea);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('一覧に戻しました')));
      }
    } catch (_) {
      if (mounted) _showError(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // v0.2.1 ノイズ削減 N13: 戻す／消すの判断に成長段階は要らない。
          Text(
            widget.idea.title,
            style: const TextStyle(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _confirmDelete(context),
                child: Text(
                  '完全に削除',
                  style: TextStyle(color: errorColor),
                ),
              ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: accentTonalFill(context),
                  foregroundColor: accentTextColor(context),
                ),
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.unarchive_outlined, size: 18),
                label: const Text('戻す'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final errorColor = Theme.of(context).colorScheme.error;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('完全に削除しますか？'),
          content: const Text('このアイデアは元に戻せません。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(
                '削除する',
                style: TextStyle(color: errorColor),
              ),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        try {
          await widget.store.deleteIdea(widget.idea);
        } catch (_) {
          if (context.mounted) _showError(context);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(BuildContext context) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('変更を保存できませんでした。')));
}
