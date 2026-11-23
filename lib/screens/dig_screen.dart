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

class _DigScreenState extends State<DigScreen> with WidgetsBindingObserver {
  late final DigSession _session;
  late final ResilientBackend _backend;
  DigQuestion? _question;
  bool _loading = false;
  bool _summarizing = false;
  bool _saving = false;
  bool _leaving = false;
  bool _backgrounded = false;
  bool _retrySummary = false;
  int _request = 0;
  AiPhase? _phase;
  String? _failure;
  String? _selectedChoice;
  final _freeCtrl = TextEditingController();
  final OnceFlag _fallbackNotice = OnceFlag();

  Idea get idea => widget.idea;
  bool get _busy => _loading || _summarizing || _saving;
  bool get _canAnswer =>
      _selectedChoice != null || _freeCtrl.text.trim().isNotEmpty;
  bool get _sessionComplete =>
      _session.answers.length >= AppConfig.questionsPerSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backend = widget.store.backend()
      ..onPhase = (phase) {
        if (mounted && !_leaving) setState(() => _phase = phase);
      };
    _session =
        idea.resumableSession ??
        DigSession(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          startedAt: DateTime.now(),
        );
    if (_sessionComplete) {
      _summarize();
    } else {
      _loadQuestion();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backend.cancelPending();
    _freeCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgrounded =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (_backgrounded && !_leaving && (_loading || _summarizing)) {
      _retrySummary = _summarizing;
      _stopGeneration();
      setState(() {
        _loading = false;
        _summarizing = false;
        _failure = '生成を中止しました。続きから再開できます。';
      });
    }
  }

  void _stopGeneration() {
    _request++;
    _backend.cancelPending();
  }

  bool _current(int request) => mounted && !_leaving && request == _request;

  Future<void> _persist() async {
    final newSession = !idea.sessions.contains(_session);
    if (newSession) idea.sessions.add(_session);
    try {
      await widget.store.updateIdea(idea);
    } catch (_) {
      if (newSession) idea.sessions.remove(_session);
      rethrow;
    }
  }

  void _noticeFallback() {
    if (!_fallbackNotice.tryConsume()) return;
    final message =
        _backend.lastRemoteError?.message ??
        (_backend.lastSource == AnswerSource.remote
            ? '端末AIが使えなかったため、Gemini APIで生成しました。'
            : '端末AIが使えなかったため、定型の質問を表示します。');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _maybeShowKeyGuide() {
    if (widget.store.hasRemoteKey ||
        widget.store.keyGuideShown ||
        _backend.lastSource != AnswerSource.local ||
        !_backend.lastOnDeviceFailed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _leaving || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      try {
        await widget.store.markKeyGuideShown();
      } catch (_) {
        return;
      }
      if (!mounted || _leaving) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('設定で端末AIの状態を確認できます。'),
          action: SnackBarAction(label: '設定', onPressed: _openSettings),
        ),
      );
    });
  }

  void _openSettings() {
    if (_busy || _leaving) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(store: widget.store)),
    );
  }

  Future<void> _loadQuestion({bool templateOnly = false}) async {
    if (_session.pendingQuestion case final question?) {
      setState(() {
        _question = question;
        _loading = false;
        _failure = null;
      });
      return;
    }
    final request = ++_request;
    setState(() {
      _loading = true;
      _summarizing = false;
      _retrySummary = false;
      _phase = null;
      _failure = null;
    });
    final previousContrarian = _session.contrarianAsked;
    DigQuestion? generated;
    try {
      generated = await _backend.nextQuestion(
        idea: idea,
        history: [for (final s in idea.sessions) ...s.answers],
        templateHistory: [..._session.answers],
        style: widget.store.digStyle,
        viewpoint: _session.viewpoint,
        contrarianDue: contrarianDue(_session),
        templateOnly: templateOnly,
      );
      if (!_current(request)) return;
      if (generated.isContrarian) _session.contrarianAsked = true;
      _session.pendingQuestion = generated;
      setState(() {
        _saving = true;
        _loading = false;
      });
      await _persist();
      if (!_current(request)) return;
      setState(() => _question = generated);
      if (_backend.lastOnDeviceFailed || _backend.lastRemoteFailed) {
        _noticeFallback();
      }
      _maybeShowKeyGuide();
    } on AiCancelled {
      return;
    } catch (_) {
      if (generated != null && identical(_session.pendingQuestion, generated)) {
        _session.pendingQuestion = null;
        _session.contrarianAsked = previousContrarian;
      }
      if (_current(request)) {
        setState(() => _failure = '質問を保存できませんでした。もう一度お試しください。');
      }
    } finally {
      if (_current(request)) {
        setState(() {
          _loading = false;
          _saving = false;
        });
      }
    }
  }

  Future<void> _answer() async {
    final question = _question;
    if (_busy || _leaving || question == null || !_canAnswer) return;
    final free = _freeCtrl.text.trim();
    final answer = free.isNotEmpty ? free : _selectedChoice;
    if (answer == null || answer.isEmpty) return;
    setState(() => _saving = true);
    final previousContrarian = _session.contrarianAsked;
    final entry = QaEntry(
      questionId: question.id,
      question: question.text,
      answer: answer,
      choices: question.choices,
      contrarian: question.isContrarian,
      source: question.source,
    );
    _session.answers.add(entry);
    if (entry.contrarian) _session.contrarianAsked = true;
    _session.pendingQuestion = null;
    try {
      await _persist();
    } catch (_) {
      _session.answers.remove(entry);
      _session.pendingQuestion = question;
      _session.contrarianAsked = previousContrarian;
      if (mounted && !_leaving) {
        setState(() => _saving = false);
        _showSaveError();
      }
      return;
    }
    if (!mounted || _leaving) return;
    _freeCtrl.clear();
    setState(() {
      _question = null;
      _selectedChoice = null;
      _saving = false;
    });
    if (_backgrounded) {
      setState(() => _failure = '回答を保存しました。続きから再開できます。');
      return;
    }
    if (_sessionComplete) {
      await _summarize();
    } else {
      await _loadQuestion();
    }
  }

  Future<void> _summarize({bool templateOnly = false}) async {
    final request = ++_request;
    setState(() {
      _summarizing = true;
      _loading = false;
      _phase = null;
      _failure = null;
    });
    PlanMemo? memo;
    final previousPending = _session.pendingQuestion;
    try {
      memo = await _backend.summarize(
        idea: idea,
        history: [for (final s in idea.sessions) ...s.answers],
        version: idea.memos.length + 1,
        style: widget.store.digStyle,
        templateOnly: templateOnly,
      );
      if (!_current(request)) return;
      idea.memos.add(memo);
      _session.finished = true;
      _session.pendingQuestion = null;
      setState(() {
        _summarizing = false;
        _saving = true;
      });
      await _persist();
    } on AiCancelled {
      return;
    } catch (_) {
      if (memo != null && idea.memos.remove(memo)) {
        _session.finished = false;
        _session.pendingQuestion = previousPending;
      }
      if (_current(request)) {
        setState(() {
          _failure = '企画メモを保存できませんでした。もう一度お試しください。';
          _retrySummary = true;
        });
      }
      return;
    } finally {
      if (_current(request)) {
        setState(() {
          _summarizing = false;
          _saving = false;
        });
      }
    }
    if (!mounted || !_current(request)) return;
    final failure = _backend.lastRemoteError;
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    }
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

  void _useTemplate() {
    final summary = _summarizing;
    _stopGeneration();
    if (summary) {
      _summarize(templateOnly: true);
    } else {
      _loadQuestion(templateOnly: true);
    }
  }

  void _retry() {
    if (_retrySummary || _sessionComplete) {
      _summarize();
    } else {
      _loadQuestion();
    }
  }

  Future<void> _undo() async {
    if (_busy || _leaving) return;
    final previousPending = _session.pendingQuestion;
    final previousContrarian = _session.contrarianAsked;
    final removed = undoLastAnswer(_session);
    if (removed == null) return;
    setState(() => _saving = true);
    try {
      await _persist();
      if (!mounted || _leaving) return;
      _freeCtrl.clear();
      setState(() {
        _selectedChoice = null;
        _question = _session.pendingQuestion;
      });
    } catch (_) {
      _session.answers.add(removed);
      _session.pendingQuestion = previousPending;
      _session.contrarianAsked = previousContrarian;
      if (mounted && !_leaving) _showSaveError();
    } finally {
      if (mounted && !_leaving) setState(() => _saving = false);
    }
  }

  void _showSaveError() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('変更を保存できませんでした。もう一度お試しください。')));
  }

  Future<void> _setStyle(DigStyle style) async {
    if (_busy || widget.store.digStyle == style) return;
    setState(() => _saving = true);
    try {
      await widget.store.saveDigStyle(style);
    } catch (_) {
      if (mounted && !_leaving) _showSaveError();
    } finally {
      if (mounted && !_leaving) setState(() => _saving = false);
    }
  }

  Future<void> _setViewpoint(DigViewpoint viewpoint) async {
    if (_busy || _session.viewpoint == viewpoint) return;
    final previous = _session.viewpoint;
    setState(() {
      _session.viewpoint = viewpoint;
      _saving = true;
    });
    try {
      await _persist();
    } catch (_) {
      _session.viewpoint = previous;
      if (mounted && !_leaving) _showSaveError();
    } finally {
      if (mounted && !_leaving) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _session.answers.length;
    final canSummarize = done > 0 || idea.totalAnswers > 0;
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _leaving = true;
        _stopGeneration();
      },
      child: Scaffold(
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
                  child: Text(
                    '$done / ${AppConfig.questionsPerSession}問',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 10),
                if (!_busy && _question?.source != null)
                  _ModeBadge(source: _question!.source!),
                const SizedBox(height: 10),
                _styleAndViewpointControls(),
                const SizedBox(height: 12),
                if (_busy)
                  Expanded(
                    child: Center(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          const Center(child: CircularProgressIndicator()),
                          const SizedBox(height: 12),
                          Text(
                            _saving
                                ? '端末に保存中…'
                                : _phase == AiPhase.cloud
                                ? 'Gemini APIで生成中…'
                                : '端末AIを確認・生成中…',
                            textAlign: TextAlign.center,
                          ),
                          if (!_saving && _phase != null)
                            TextButton(
                              onPressed: _useTemplate,
                              child: const Text('定型で続ける'),
                            ),
                        ],
                      ),
                    ),
                  )
                else if (_failure case final failure?)
                  Expanded(
                    child: ListView(
                      children: [
                        Text(failure),
                        TextButton(
                          onPressed: _retry,
                          child: const Text('再開する'),
                        ),
                      ],
                    ),
                  )
                else if (_question != null)
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [_questionCard(_question!)],
                      ),
                    ),
                  ),
                if (!_busy && _failure == null) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kButtonFill,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    // K4: 回答が無い間は無効の見た目にする。
                    onPressed: _question != null && _canAnswer ? _answer : null,
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
                  onSelected: _busy ? null : (_) => _setStyle(s),
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
                  onSelected: _busy ? null : (_) => _setViewpoint(v),
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
  final AnswerSource source;
  const _ModeBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final isAi = source != AnswerSource.local;
    final fullLabel = source.label;
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
                  isAi ? Icons.auto_awesome : Icons.list_alt_outlined,
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
