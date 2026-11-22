import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../app_config.dart';
import '../dig_mode.dart';
import '../models.dart';
import '../session_logic.dart';
import '../store.dart';
import '../widgets/glass.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

/// S3 深掘りセッション。質問は1画面に1つ、3択チップ＋自由入力。
/// 1セッション5問を目安に区切り、途中保存・再開できる。
///
/// v0.1.2 の変更:
/// - K1: 現在のモード（AI／定型）をバッジで常時表示。API失敗時は
///   セッションに1回だけ静かな通知で定型への切替を知らせる。
/// - K2: まとめ完了後は起動元によらず詳細へ遷移し、完成メモを見せる。
/// - K3: キー未設定の初回だけ、キー案内＋設定への導線を1回出す。
/// - K4: 「答える」は回答がある時だけ有効。まとめ無効時は理由を1行出す。
class DigScreen extends StatefulWidget {
  final IdeaStore store;
  final Idea idea;

  /// 詳細画面から起動したか。true なら完了時は pop で詳細へ戻る。
  final bool fromDetail;
  const DigScreen({
    super.key,
    required this.store,
    required this.idea,
    this.fromDetail = false,
  });

  @override
  State<DigScreen> createState() => _DigScreenState();
}

class _DigScreenState extends State<DigScreen> {
  late DigSession _session;

  /// セッション中は同じバックエンドを使い回す（K1: 直近の応答元を保持するため）。
  late ResilientBackend _backend;
  DigQuestion? _question;
  bool _loading = true;
  bool _summarizing = false;
  String? _selectedChoice;
  final _freeCtrl = TextEditingController();

  /// 現在のモード表示（K1）。バックエンド呼び出しのたびに更新する。
  late DigModeKind _modeKind;

  /// API失敗→定型切替の通知はセッションに1回だけ（K1）。
  final OnceFlag _fallbackNotice = OnceFlag();

  Idea get idea => widget.idea;

  bool get _canAnswer =>
      _selectedChoice != null || _freeCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _backend = widget.store.backend();
    _modeKind = _backend.currentModeKind;
    _session = idea.resumableSession ??
        DigSession(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          startedAt: DateTime.now(),
        );
    if (!idea.sessions.contains(_session)) {
      idea.sessions.add(_session);
    }
    _loadQuestion();
  }

  @override
  void dispose() {
    _freeCtrl.dispose();
    super.dispose();
  }

  Future<void> _persist() => widget.store.updateIdea(idea);

  /// バックエンドの直近結果からモード表示を更新する（K1）。
  /// 定型（失敗）へ切り替わった瞬間に1回だけ通知する。
  void _syncMode({bool notify = true}) {
    final kind = _backend.currentModeKind;
    if (kind != _modeKind && mounted) {
      setState(() => _modeKind = kind);
    } else {
      _modeKind = kind;
    }
    // v0.3.0 PoC: オンデバイス→次候補への切替も、定型への切替と同じく
    // セッションに1回だけ静かに知らせる。
    final fellBack = kind == DigModeKind.templateFailed ||
        (_backend.lastOnDeviceFailed && kind == DigModeKind.ai);
    if (notify && fellBack && _fallbackNotice.tryConsume() && mounted) {
      final msg = kind == DigModeKind.ai
          ? 'オンデバイスAIが使えなかったので、AI（Gemini）に切り替えたよ'
          : _backend.lastOnDeviceFailed && !widget.store.hasRemoteKey
              ? 'オンデバイスAIが使えなかったので、定型の質問に切り替えたよ'
              : 'AIにつながらなかったので、定型の質問に切り替えたよ';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  /// K3: キー未設定で深掘りを始めた時に1回だけ案内を出す。
  void _maybeShowKeyGuide() {
    // v0.3.0 PoC: オンデバイスで掘れている間は案内しない。
    // 定型に落ちた時だけ出す。
    if (widget.store.hasRemoteKey ||
        widget.store.keyGuideShown ||
        _backend.lastSource != AnswerSource.local) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await widget.store.markKeyGuideShown();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('今は定型の質問で掘っているよ。キーを入れるとAIが質問するようになるよ'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'キーを入れる',
            onPressed: _openSettings,
          ),
        ),
      );
    });
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(store: widget.store)),
    );
    // 設定でキーが変わった可能性があるのでバックエンドを作り直す。
    _backend = widget.store.backend();
    _syncMode(notify: false);
  }

  Future<void> _loadQuestion() async {
    setState(() => _loading = true);
    // 再開時: 保存済みの pending があればそれを使う。
    if (_session.pendingQuestion != null) {
      _question = _session.pendingQuestion;
      setState(() => _loading = false);
      _maybeShowKeyGuide();
      return;
    }
    // ローカルのみ（キー未設定）の場合は履歴を現在のセッションだけに絞る:
    // 全履歴を渡すと LocalBackend の既出スキップで2周目に定型5問が
    // 最初から出なくなるため。Gemini利用時は従来どおり全履歴。
    final history = widget.store.hasRemoteKey
        ? [for (final s in idea.sessions) ...s.answers]
        : [..._session.answers];
    final q = await _backend.nextQuestion(
      idea: idea,
      history: history,
      style: widget.store.digStyle,
      viewpoint: _session.viewpoint,
      contrarianDue: contrarianDue(_session),
    );
    // 逆張り質問を出したら、その場で「出した」ことを記録する（再開時の二重防止）。
    if (q.isContrarian) _session.contrarianAsked = true;
    _session.pendingQuestion = q;
    await _persist();
    if (!mounted) return;
    setState(() {
      _question = q;
      _loading = false;
    });
    _syncMode();
    _maybeShowKeyGuide();
  }

  Future<void> _answer() async {
    final q = _question;
    if (q == null || !_canAnswer) return;
    final free = _freeCtrl.text.trim();
    final answer = free.isNotEmpty ? free : _selectedChoice;
    if (answer == null || answer.isEmpty) return;
    _session.answers.add(
      QaEntry(
        questionId: q.id,
        question: q.text,
        answer: answer,
        // 「1問もどる」で質問を復元できるよう選択肢も記録する（項目7）。
        choices: q.choices,
        contrarian: q.isContrarian,
      ),
    );
    _session.pendingQuestion = null;
    _freeCtrl.clear();
    _selectedChoice = null;
    await _persist();
    if (!mounted) return;
    if (_session.answers.length >= AppConfig.questionsPerSession) {
      await _summarize(auto: true);
    } else {
      await _loadQuestion();
    }
  }

  Future<void> _summarize({bool auto = false}) async {
    setState(() => _summarizing = true);
    final history = [
      for (final s in idea.sessions) ...s.answers,
    ];
    final memo = await _backend.summarize(
          idea: idea,
          history: history,
          version: idea.memos.length + 1,
          style: widget.store.digStyle,
        );
    idea.memos.add(memo); // 版として積む（上書きしない）
    _session.finished = true;
    await _persist();
    if (!mounted) return;
    setState(() => _summarizing = false);
    // K2: 起動元によらず詳細へ遷移し、完成した最新メモを見せる。
    if (widget.fromDetail) {
      Navigator.pop(context, true);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DetailScreen(
            store: widget.store,
            idea: idea,
            highlightLatestMemo: true,
          ),
        ),
      );
    }
  }

  /// 「1問もどる」（項目7）: 最後の回答を取り消し、その質問に戻る。
  Future<void> _undo() async {
    final removed = undoLastAnswer(_session);
    if (removed == null) return;
    _freeCtrl.clear();
    _selectedChoice = null;
    await _persist();
    if (!mounted) return;
    setState(() {
      _question = _session.pendingQuestion;
      _loading = false;
    });
  }

  /// 掘り方スタイルの切り替え（項目1）。セッション途中でも以後へ反映する。
  Future<void> _setStyle(DigStyle style) async {
    if (widget.store.digStyle == style) return;
    await widget.store.saveDigStyle(style);
    if (mounted) setState(() {});
  }

  /// 視点の切り替え（項目2）。セッションに保存して以後へ反映する。
  Future<void> _setViewpoint(DigViewpoint viewpoint) async {
    if (_session.viewpoint == viewpoint) return;
    setState(() => _session.viewpoint = viewpoint);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final done = _session.answers.length;
    final canSummarize = done > 0 || idea.totalAnswers > 0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(idea.title, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GlassBackground(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // v0.2.1 ノイズ削減 N3/N4: 進み具合は「n/5問」に一本化
              // （段階アイコンと成長バーはホーム／詳細が正本）。
              Align(
                alignment: Alignment.centerRight,
                child: Text('$done / ${AppConfig.questionsPerSession}問',
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 10),
              _ModeBadge(kind: _modeKind),
              const SizedBox(height: 10),
              _styleAndViewpointControls(),
              const SizedBox(height: 12),
              if (_loading || _summarizing)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_question != null)
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _questionCard(_question!),
                      ],
                    ),
                  ),
                ),
              if (!_loading && !_summarizing) ...[
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kButtonFill,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  // K4: 回答が無い間は無効の見た目にする。
                  onPressed: _canAnswer ? _answer : null,
                  child: const Text('答える', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 8),
                // v0.2.1 ノイズ削減 N7/N8: 補助ボタンは横1行に集約し、
                // 説明文と「あとで続きを掘る」（戻る操作と重複・自動保存済み）を削除。
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      // 項目7: 選択肢の記録がある最新の回答だけ「もどる」対象。
                      onPressed: canUndoLastAnswer(_session) ? _undo : null,
                      child: const Text('1問もどる'),
                    ),
                    TextButton(
                      onPressed: canSummarize ? () => _summarize() : null,
                      child: const Text('いったんまとめる'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 掘り方スタイル（友達／上司）と視点（通常／お金／技術／使う人）の切替UI。
  /// v0.2.1 ノイズ削減: 支援項目なので既定は畳む（質問が主役）。
  /// 見出しは現在の選択が閉じたままでも分かる形にする。
  Widget _styleAndViewpointControls() {
    final style = widget.store.digStyle;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        '掘り方・視点（${style.label}／${_session.viewpoint.label}）',
        style: const TextStyle(fontSize: 13),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in DigStyle.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: style == s,
                  onSelected: (_) => _setStyle(s),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final v in DigViewpoint.values)
                ChoiceChip(
                  label: Text(v.label),
                  selected: _session.viewpoint == v,
                  selectedColor: kAccent.withValues(alpha: 0.35),
                  onSelected: (_) => _setViewpoint(v),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _questionCard(DigQuestion q) {
    return GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              q.text,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, height: 1.6),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: q.choices
                  .map(
                    (c) => ChoiceChip(
                      label: Text(c),
                      selected: _selectedChoice == c,
                      onSelected: (_) => setState(() {
                        _selectedChoice = c;
                        _freeCtrl.clear();
                      }),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _freeCtrl,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: '自分の言葉で書いてもいいよ',
                filled: true,
                fillColor: glassInputFill(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {
                if (_freeCtrl.text.trim().isNotEmpty) _selectedChoice = null;
              }),
            ),
          ],
        ),
    );
  }
}

/// 現在のモードを示す小さなバッジ（K1）。常時表示する。
/// v0.2: 掘り方スタイルも併記する（例: 「AIで深掘り中・友達モード」）。
class _ModeBadge extends StatelessWidget {
  final DigModeKind kind;
  const _ModeBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final isAi = kind.isAi;
    // v0.2.1 ノイズ削減 N5: 掘り方は選択中チップが正本。バッジはAI／定型だけ。
    final fullLabel = kind.label;
    return Semantics(
      container: true,
      label: '現在のモード: $fullLabel',
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (isAi ? kAccent : Colors.black).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isAi
                      ? Icons.auto_awesome
                      : (kind == DigModeKind.templateFailed
                          ? Icons.cloud_off_outlined
                          : Icons.list_alt_outlined),
                  size: 15,
                  color: kAccentDeep,
                ),
                const SizedBox(width: 6),
                Text(
                  fullLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: kAccentDeep,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
