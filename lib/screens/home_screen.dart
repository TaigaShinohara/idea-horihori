import 'package:flutter/material.dart';

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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('アイデアホリホリ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          AnimatedBuilder(
            animation: store,
            builder: (context, _) {
              final count = store.archivedIdeas.length;
              return IconButton(
                tooltip: 'アーカイブ',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ArchiveScreen(store: store)),
                ),
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
                              horizontal: 5, vertical: 1),
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
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SettingsScreen(store: store)),
            ),
          ),
        ],
      ),
      body: GlassBackground(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            if (!store.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            final ideas = store.visibleIdeas;
            if (ideas.isEmpty) {
              final archivedCount = store.archivedIdeas.length;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🌱', style: TextStyle(fontSize: 44)),
                      const SizedBox(height: 12),
                      Text(
                        '思いついたら、1行で置いておこう',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      if (archivedCount > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          'アーカイブが$archivedCount件あるよ。右上の📦から戻せるよ',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: ideas.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _IdeaCard(store: store, idea: ideas[i]),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kButtonFill,
        foregroundColor: Colors.white,
        onPressed: () => _showQuickAdd(context),
        icon: const Icon(Icons.add),
        label: const Text('アイデアを追加'),
      ),
    );
  }

  /// S2 クイック追加シート（入力1つ＋任意メモ）。
  void _showQuickAdd(BuildContext context) {
    final titleCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
        ),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                maxLines: 2,
                minLines: 1,
                style: const TextStyle(fontSize: 17),
                decoration: const InputDecoration(
                  hintText: 'どんなアプリ？ 1行で',
                  border: InputBorder.none,
                ),
              ),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                minLines: 1,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'メモ（任意）',
                  border: InputBorder.none,
                ),
              ),
              const SizedBox(height: 8),
              // K4: タイトルが空の間は「ストックする」を無効の見た目にする。
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: titleCtrl,
                builder: (context, value, _) {
                  final canSave = value.text.trim().isNotEmpty;
                  return FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: kButtonFill),
                    onPressed: canSave
                        ? () async {
                            await store.addIdea(titleCtrl.text, noteCtrl.text);
                            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                          }
                        : null,
                    child: const Text('ストックする'),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IdeaCard extends StatelessWidget {
  final IdeaStore store;
  final Idea idea;
  const _IdeaCard({required this.store, required this.idea});

  @override
  Widget build(BuildContext context) {
    final stage = idea.stage;
    return GlassCard(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DetailScreen(store: store, idea: idea)),
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
                  style: const TextStyle(fontSize: 16, height: 1.5, fontWeight: FontWeight.w600),
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
                backgroundColor: kAccent.withValues(alpha: 0.16),
                foregroundColor: kAccentDeep,
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DigScreen(store: store, idea: idea)),
              ),
              icon: const Icon(Icons.terrain, size: 18),
              label: Text(idea.resumableSession != null ? 'つづきを掘る' : '深掘り'),
            ),
          ),
        ],
      ),
    );
  }
}
