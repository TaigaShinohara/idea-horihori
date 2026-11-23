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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('アーカイブ'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GlassBackground(
        child: AnimatedBuilder(
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
                      const Text('📦', style: TextStyle(fontSize: 44)),
                      const SizedBox(height: 12),
                      Text(
                        'アーカイブはないよ',
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

class _ArchivedCard extends StatelessWidget {
  final IdeaStore store;
  final Idea idea;
  const _ArchivedCard({required this.store, required this.idea});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // v0.2.1 ノイズ削減 N13: 戻す／消すの判断に成長段階は要らない。
          Text(
            idea.title,
            style: const TextStyle(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _confirmDelete(context),
                child: const Text(
                  '完全に削除',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: kAccent.withValues(alpha: 0.16),
                  foregroundColor: kAccentDeep,
                ),
                onPressed: () async {
                  try {
                    await store.unarchiveIdea(idea);
                  } catch (_) {
                    if (context.mounted) _showError(context);
                    return;
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('一覧に戻したよ')));
                  }
                },
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('完全に削除する？'),
        content: const Text('このアイデアは元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text(
              '削除する',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      try {
        await store.deleteIdea(idea);
      } catch (_) {
        if (context.mounted) _showError(context);
      }
    }
  }

  void _showError(BuildContext context) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('変更を保存できませんでした。')));
}
