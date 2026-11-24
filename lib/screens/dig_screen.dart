import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../app_config.dart';
import '../dig_mode.dart';
import '../models.dart';
import '../on_device_backend.dart';
import '../session_logic.dart';
import '../store.dart';
import '../widgets/glass.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

/// S3 深掘りセッション。質問は1画面に1つ、3択チップ＋自由入力。
/// 1セッション5問を目安に区切り、途中保存・再開できる。
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
  late ResilientBackend _backend;
  DigQuestion? _question;
  bool _loading = false;
  bool _summarizing = false;
  bool _saving = false;
  bool _leaving = false;
  bool _openingSettings = false;
  bool _optionsOpen = false;
  bool _backgrounded = false;
  bool _retrySummary = false;
  bool _returnedFromSettings = false;
  bool _guidePrompted = false;
  int _request = 0;
  AiPhase? _phase;
  String? _failure;
  String? _retryNotice;
  String? _selectedChoice;
  final _freeCtrl = TextEditingController();

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
    _initBackend();
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

  void _initBackend() {
    _backend = widget.store.backend()
      ..onPhase = (phase) {
        if (mounted && !_leaving) setState(() => _phase = phase);
      };
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
      if (!mounted) return;
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

  Future<void> _openSettings() async {
    if (_busy ||
        _leaving ||
        _openingSettings ||
        _optionsOpen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _openingSettings = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => SettingsScreen(store: widget.store)),
      );
      if (!mounted || _leaving) return;
      _backend.cancelPending();
      _initBackend();
      setState(() {
        _returnedFromSettings = _question?.source == AnswerSource.local;
        _retryNotice = null;
      });
    } finally {
      _openingSettings = false;
    }
  }

  FallbackReason? _currentFallbackReason() {
    if (_busy || _question?.source != AnswerSource.local) return null;
    final fromBackend = _backend.fallbackReason(
      hasRemoteKey: widget.store.hasRemoteKey,
      remoteConsent: widget.store.remoteConsent,
    );
    if (fromBackend != null) return fromBackend;
    final cachedStatus = widget.store.cachedOnDeviceStatus?.status;
    return fallbackReasonFor(
      isLocalSource: true,
      hasRemoteKey: widget.store.hasRemoteKey,
      remoteConsent: widget.store.remoteConsent,
      lastRemoteFailed: _backend.lastRemoteError != null,
      onDeviceNeedsDownload: cachedStatus == OnDeviceStatus.needsDownload,
      manualTemplate: _backend.lastManualTemplate,
    );
  }

  bool _canRetryWithAi() {
    if (_busy || _question?.source != AnswerSource.local) return false;
    if (_returnedFromSettings) return true;
    if (_backend.lastRemoteError != null) return true;
    if (widget.store.hasRemoteKey && widget.store.remoteConsent) return true;
    if (widget.store.cachedOnDeviceStatus?.status == OnDeviceStatus.available) {
      return true;
    }
    return false;
  }

  void _maybeMarkKeyGuideShown(FallbackReason? reason) {
    if (_guidePrompted || reason == null || !reason.suggestsSettings) return;
    if (widget.store.keyGuideShown) return;
    _guidePrompted = true;
    widget.store.markKeyGuideShown();
  }

  Future<void> _loadQuestion({bool templateOnly = false}) async {
    if (_session.pendingQuestion case final question?) {
      setState(() {
        _question = question;
        _loading = false;
        _failure = null;
        _retryNotice = null;
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
      _retryNotice = null;
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
      setState(() {
        _question = generated;
        _returnedFromSettings = false;
      });
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

  /// R-04: 未回答の定型フォールバック質問を、ユーザー操作でAIへ聞き直す。
  /// 成功時のみ pendingQuestion を上書き保存し、失敗・キャンセル時は元へロールバックする。
  Future<void> _retryQuestionWithAi() async {
    final previousQuestion = _question;
    if (_busy || _leaving || previousQuestion?.source != AnswerSource.local) {
      return;
    }
    final previousPending = _session.pendingQuestion;
    final previousContrarian = _session.contrarianAsked;
    final request = ++_request;
    setState(() {
      _loading = true;
      _summarizing = false;
      _phase = null;
      _failure = null;
      _retryNotice = null;
    });
    DigQuestion? generated;
    try {
      generated = await _backend.nextQuestion(
        idea: idea,
        history: [for (final s in idea.sessions) ...s.answers],
        templateHistory: [..._session.answers],
        style: widget.store.digStyle,
        viewpoint: _session.viewpoint,
        contrarianDue: contrarianDue(_session),
        templateOnly: false,
      );
      if (!_current(request)) return;
      if (generated.source == AnswerSource.local) {
        final reason = _backend.fallbackReason(
          hasRemoteKey: widget.store.hasRemoteKey,
          remoteConsent: widget.store.remoteConsent,
        );
        setState(() {
          _question = previousQuestion;
          _retryNotice =
              _backend.lastRemoteError?.message ??
              reason?.message ??
              'AIでの聞き直しができませんでした。このまま定型で続けられます。';
        });
        return;
      }
      _session.pendingQuestion = generated;
      _session.contrarianAsked =
          previousContrarian || generated.isContrarian;
      setState(() {
        _saving = true;
        _loading = false;
      });
      await _persist();
      if (!_current(request)) return;
      _freeCtrl.clear();
      setState(() {
        _question = generated;
        _selectedChoice = null;
        _returnedFromSettings = false;
        _retryNotice = null;
      });
    } on AiCancelled {
      _session.pendingQuestion = previousPending;
      _session.contrarianAsked = previousContrarian;
      return;
    } catch (_) {
      _session.pendingQuestion = previousPending;
      _session.contrarianAsked = previousContrarian;
      if (_current(request)) {
        setState(() {
          _question = previousQuestion;
          _retryNotice = 'AIでの聞き直しに失敗しました。元の質問のまま続けられます。';
        });
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
    FocusScope.of(context).unfocus();
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
      _retryNotice = null;
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
      _retryNotice = null;
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
        _retryNotice = null;
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

  Future<bool> _setStyle(DigStyle style) async {
    if (widget.store.digStyle == style) return true;
    if (_busy) return false;
    setState(() => _saving = true);
    try {
      await widget.store.saveDigStyle(style);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (mounted && !_leaving) setState(() => _saving = false);
    }
  }

  Future<bool> _setViewpoint(DigViewpoint viewpoint) async {
    if (_session.viewpoint == viewpoint) return true;
    if (_busy) return false;
    final previous = _session.viewpoint;
    setState(() {
      _session.viewpoint = viewpoint;
      _saving = true;
    });
    try {
      await _persist();
      return true;
    } catch (_) {
      _session.viewpoint = previous;
      return false;
    } finally {
      if (mounted && !_leaving) setState(() => _saving = false);
    }
  }

  Future<void> _openOptionsSheet() async {
    if (_busy ||
        _leaving ||
        _openingSettings ||
        _optionsOpen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _optionsOpen = true;
    try {
      FocusScope.of(context).unfocus();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _DigOptionsSheet(
          initialStyle: widget.store.digStyle,
          initialViewpoint: _session.viewpoint,
          onStyleChanged: _setStyle,
          onViewpointChanged: _setViewpoint,
        ),
      );
      if (mounted) setState(() {});
    } finally {
      _optionsOpen = false;
    }
  }

  String _shortStyleLabel(DigStyle style) => switch (style) {
    DigStyle.friend => '友達',
    DigStyle.boss => '上司',
  };

  @override
  Widget build(BuildContext context) {
    final done = _session.answers.length;
    final canSummarize = canSummarizeSession(_session);
    final displaySource = _question?.source ?? _backend.lastSource;
    final fallbackReason = _currentFallbackReason();
    final showOneTimeSettings =
        fallbackReason != null &&
        fallbackReason.suggestsSettings &&
        (!widget.store.keyGuideShown || _guidePrompted);
    if (showOneTimeSettings && !_guidePrompted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeMarkKeyGuideShown(fallbackReason);
      });
    }
    final canRetryAi = _canRetryWithAi();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return PopScope<bool>(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _leaving = true;
        _stopGeneration();
      },
      child: GlassBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(idea.title, overflow: TextOverflow.ellipsis),
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            actions: [
              IconButton(
                tooltip: 'AI設定',
                onPressed: _busy ? null : _openSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // R-03: 1行固定最小高さヘッダ（モード／現在値チップ／進捗）。
                  // 留意1・M-01: Flexible + ellipsis と minHeight で狭幅・文字拡大時の溢れを防ぐ。
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 36),
                    child: Row(
                      children: [
                        if (displaySource != null)
                          _ModeBadge(source: displaySource)
                        else
                          const SizedBox(width: 4),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _StyleViewpointChip(
                              label:
                                  '${_shortStyleLabel(widget.store.digStyle)}・${_session.viewpoint.label}',
                              enabled: !_busy,
                              onTap: _openOptionsSheet,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$done / ${AppConfig.questionsPerSession}問',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _busy
                        ? Center(
                            child: GlassCard(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 14),
                                  Text(
                                    _saving
                                        ? '保存しています…'
                                        : _summarizing
                                        ? '企画メモにまとめています…'
                                        : 'つぎの質問を考えています…',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                  if (!_saving && _phase != null) ...[
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: _useTemplate,
                                      child: const Text('定型で続ける'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          )
                        : _failure != null
                        ? Center(
                            child: GlassCard(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _failure!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.6,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: kButtonFill,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: _retry,
                                    child: const Text('再開する'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _question != null
                        ? SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AnimatedSwitcher(
                                  duration: reduceMotion
                                      ? Duration.zero
                                      : const Duration(milliseconds: 220),
                                  child: KeyedSubtree(
                                    key: ValueKey(_question!.id),
                                    child: _questionCard(_question!),
                                  ),
                                ),
                                if (_retryNotice != null ||
                                    _backend.lastRemoteError != null ||
                                    fallbackReason != null) ...[
                                  const SizedBox(height: 10),
                                  _FallbackBanner(
                                    message:
                                        _retryNotice ??
                                        _backend.lastRemoteError?.message ??
                                        fallbackReason!.message,
                                    showSettings: showOneTimeSettings,
                                    onOpenSettings: _openSettings,
                                    showRetryAi: canRetryAi,
                                    onRetryAi: _retryQuestionWithAi,
                                  ),
                                ],
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 12),
                  // P1-1 #3: ロード中も下部操作枠を維持し、毎問の縦ジャンプを防ぐ。
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kButtonFill,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed:
                        !_busy &&
                            _failure == null &&
                            _question != null &&
                            _canAnswer
                        ? _answer
                        : null,
                    child: const Text('答える', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Flexible(
                        child: TextButton(
                          onPressed:
                              !_busy &&
                                  _failure == null &&
                                  canUndoLastAnswer(_session)
                              ? _undo
                              : null,
                          child: const Text('1問もどる'),
                        ),
                      ),
                      Flexible(
                        child: TextButton(
                          onPressed:
                              !_busy && _failure == null && canSummarize
                              ? () => _summarize()
                              : null,
                          child: const Text('いったんまとめる'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
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
              fontSize: 20,
              fontWeight: FontWeight.bold,
              height: 1.6,
            ),
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
                    onSelected: (selected) => setState(() {
                      _selectedChoice = selected ? c : null;
                      if (selected) _freeCtrl.clear();
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
            decoration: glassInputDecoration(
              context,
              hintText: '自分の言葉で書いても大丈夫です',
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

class _StyleViewpointChip extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _StyleViewpointChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentText = accentTextColor(context);
    return Semantics(
      button: true,
      label: '掘り方と視点を変更。現在：$label',
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(99),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: barTrackColor(context),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? accentText
                            : accentText.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: enabled
                        ? accentText
                        : accentText.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DigOptionsSheet extends StatefulWidget {
  final DigStyle initialStyle;
  final DigViewpoint initialViewpoint;
  final Future<bool> Function(DigStyle) onStyleChanged;
  final Future<bool> Function(DigViewpoint) onViewpointChanged;
  const _DigOptionsSheet({
    required this.initialStyle,
    required this.initialViewpoint,
    required this.onStyleChanged,
    required this.onViewpointChanged,
  });

  @override
  State<_DigOptionsSheet> createState() => _DigOptionsSheetState();
}

class _DigOptionsSheetState extends State<_DigOptionsSheet> {
  late DigStyle _style = widget.initialStyle;
  late DigViewpoint _viewpoint = widget.initialViewpoint;
  bool _saving = false;
  String? _error;

  Future<void> _selectStyle(DigStyle style) async {
    if (_saving || _style == style) return;
    final previous = _style;
    setState(() {
      _style = style;
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      ok = await widget.onStyleChanged(style);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) {
        _style = previous;
        _error = '変更を保存できませんでした。もう一度お試しください。';
      }
    });
  }

  Future<void> _selectViewpoint(DigViewpoint viewpoint) async {
    if (_saving || _viewpoint == viewpoint) return;
    final previous = _viewpoint;
    setState(() {
      _viewpoint = viewpoint;
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      ok = await widget.onViewpointChanged(viewpoint);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) {
        _viewpoint = previous;
        _error = '変更を保存できませんでした。もう一度お試しください。';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopScope(
      canPop: !_saving,
      child: GlassSheetSurface(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '掘り方・視点',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            '掘り方',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final s in DigStyle.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: _style == s,
                  onSelected: _saving ? null : (_) => _selectStyle(s),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '視点',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final v in DigViewpoint.values)
                ChoiceChip(
                  label: Text(v.label),
                  selected: _viewpoint == v,
                  selectedColor: kAccent.withValues(alpha: 0.35),
                  onSelected: _saving ? null : (_) => _selectViewpoint(v),
                ),
            ],
          ),
            const SizedBox(height: 12),
            Text(
              '変更は次の質問から反映されます。',
              style: TextStyle(fontSize: 13, color: muted),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
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
}

class _FallbackBanner extends StatelessWidget {
  final String message;
  final bool showSettings;
  final VoidCallback onOpenSettings;
  final bool showRetryAi;
  final VoidCallback onRetryAi;
  const _FallbackBanner({
    required this.message,
    required this.showSettings,
    required this.onOpenSettings,
    required this.showRetryAi,
    required this.onRetryAi,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final accentText = accentTextColor(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(fontSize: 13, color: muted, height: 1.5),
          ),
          if (showSettings || showRetryAi) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (showRetryAi)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: accentText,
                    ),
                    onPressed: onRetryAi,
                    child: const Text('AIで聞き直す'),
                  ),
                if (showSettings)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: accentText,
                    ),
                    onPressed: onOpenSettings,
                    child: const Text('設定を開く'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 現在のモードを示す小さなバッジ（K1）。常時表示する。
class _ModeBadge extends StatelessWidget {
  final AnswerSource source;
  const _ModeBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final isAi = source != AnswerSource.local;
    final fullLabel = source.label;
    final accentText = accentTextColor(context);
    return Semantics(
      container: true,
      label: '現在のモード: $fullLabel',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isAi ? accentTonalFill(context) : barTrackColor(context),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAi ? Icons.auto_awesome : Icons.list_alt_outlined,
                size: 14,
                color: accentText,
              ),
              const SizedBox(width: 5),
              Text(
                fullLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: accentText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
