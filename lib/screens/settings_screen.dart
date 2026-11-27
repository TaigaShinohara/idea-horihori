import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../app_config.dart';
import '../chatgpt_auth_service.dart';
import '../google_workspace.dart';
import '../models.dart';
import '../on_device_backend.dart';
import '../store.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  final IdeaStore store;

  /// v0.5.0: Google Workspace 連携（テストではフェイクを差し替える）。
  final GoogleWorkspaceService? googleService;
  const SettingsScreen({super.key, required this.store, this.googleService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final _key = TextEditingController(text: widget.store.apiKey);
  late final _model = TextEditingController(text: widget.store.model);
  late final OnDeviceBackend _nano = widget.store.onDeviceBackend(
    onDownloadProgress: _downloadProgress,
  );
  bool _obscure = true;
  bool _editing = false;
  bool _checking = false;
  bool _preparingNano = false;
  bool _testingNano = false;
  double? _progress;
  int _nanoAttempt = 0;
  OnDeviceCheck? _diagnosis;
  DigQuestion? _sampleQuestion;
  GeminiBackend? _connection;
  String? _apiMessage;
  String? _modelMessage;
  String? _connectionMessage;
  String? _nanoMessage;

  // v0.4.0: ChatGPT サインイン。
  final ChatGptAuthService _chatGptAuth = ChatGptAuthService();
  final TextEditingController _codeCtrl = TextEditingController();
  bool _cgBusy = false;
  String? _cgMessage;

  // v0.5.0: Google Workspace 連携。
  late final GoogleWorkspaceService _google =
      widget.googleService ?? GoogleWorkspaceService();
  bool _gBusy = false;
  bool _gChecked = false;
  GoogleAccountInfo? _gAccount;
  String? _gMessage;

  Future<void> _refreshGoogleAccount() async {
    final account = await _google.currentAccount();
    if (!mounted) return;
    setState(() {
      _gAccount = account;
      _gChecked = true;
    });
  }

  Future<void> _googleSignIn() async {
    setState(() {
      _gBusy = true;
      _gMessage = null;
    });
    try {
      final account = await _google.signIn();
      if (!mounted) return;
      setState(() {
        _gAccount = account;
        _gChecked = true;
        _gMessage = 'サインインしました';
      });
    } on GoogleWorkspaceException catch (e) {
      if (!mounted) return;
      setState(() => _gMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _gMessage = 'Google サインインに失敗しました。通信状態を確認して、もう一度お試しください。',
      );
    } finally {
      if (mounted) setState(() => _gBusy = false);
    }
  }

  Future<void> _googleSignOut() async {
    setState(() => _gBusy = true);
    try {
      await _google.signOut();
    } catch (_) {
      // サインアウト失敗でも表示は未サインイン側へ倒す。
    }
    if (!mounted) return;
    setState(() {
      _gBusy = false;
      _gAccount = null;
      _gChecked = true;
      _gMessage = 'サインアウトしました';
    });
  }

  Future<void> _chatGptSignIn() async {
    setState(() {
      _cgBusy = true;
      _cgMessage = null;
    });
    try {
      await _chatGptAuth.signIn();
      await widget.store.refreshChatGptStatus();
      if (!mounted) return;
      setState(() => _cgMessage = 'サインインしました');
    } on ChatGptAuthException catch (e) {
      if (!mounted) return;
      setState(() => _cgMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _cgMessage = 'ChatGPT サインインに失敗しました。通信状態を確認して、もう一度お試しください。',
      );
    } finally {
      if (mounted) setState(() => _cgBusy = false);
    }
  }

  Future<void> _chatGptSignInWithCode() async {
    setState(() {
      _cgBusy = true;
      _cgMessage = null;
    });
    try {
      await _chatGptAuth.signInWithCode(_codeCtrl.text);
      await widget.store.refreshChatGptStatus();
      if (!mounted) return;
      _codeCtrl.clear();
      setState(() => _cgMessage = 'サインインしました');
    } on ChatGptAuthException catch (e) {
      if (!mounted) return;
      setState(() => _cgMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _cgMessage = '認可コードでのサインインに失敗しました。コードを確認して、もう一度お試しください。',
      );
    } finally {
      if (mounted) setState(() => _cgBusy = false);
    }
  }

  Future<void> _chatGptSignOut() async {
    setState(() => _cgBusy = true);
    try {
      await _chatGptAuth.signOut();
      await widget.store.refreshChatGptStatus();
      if (!mounted) return;
      setState(() => _cgMessage = 'サインアウトしました');
    } catch (_) {
      if (!mounted) return;
      setState(() => _cgMessage = 'サインアウトに失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => _cgBusy = false);
    }
  }

  Future<void> _toggleChatGptConsent(bool value) async {
    if (_cgBusy || _editing) return;
    setState(() {
      _editing = true;
      _cgMessage = null;
    });
    try {
      await widget.store.saveChatGptConsent(value);
      if (mounted) {
        setState(
          () => _cgMessage = value ? 'ChatGPT送信を有効にしました。' : 'ChatGPT送信を停止しました。',
        );
      }
    } on StoreFailure catch (failure) {
      if (mounted) setState(() => _cgMessage = failure.message);
    } catch (_) {
      if (mounted) setState(() => _cgMessage = '設定を保存できませんでした。');
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final cached = widget.store.cachedOnDeviceStatus;
    if (cached != null) {
      _diagnosis = cached;
    } else {
      _runDiagnosis(auto: true);
    }
    // 未設定ビルドではプラグインに触れない（currentAccount が即 null を返す）。
    if (_google.isConfigured) {
      _refreshGoogleAccount();
    } else {
      _gChecked = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      var changed = false;
      if (!_obscure) {
        _obscure = true;
        changed = true;
      }
      if (_connection != null) {
        _connection?.dispose();
        _connection = null;
        _connectionMessage = 'バックグラウンドへ移動したため接続確認を中断しました。';
        changed = true;
      }
      if (_testingNano) {
        _nanoAttempt++;
        _nano.cancelPending();
        _testingNano = false;
        _nanoMessage = 'バックグラウンドへ移動したためテストを中断しました。';
        changed = true;
      }
      if (changed && mounted) setState(() {});
    }
  }

  Future<void> _edit(
    Future<void> Function() change,
    String Function() success,
  ) async {
    if (_editing) return;
    setState(() {
      _editing = true;
      _apiMessage = null;
    });
    try {
      await change();
      if (mounted) setState(() => _apiMessage = success());
    } on StoreFailure catch (failure) {
      if (mounted) setState(() => _apiMessage = failure.message);
    } catch (_) {
      if (mounted) setState(() => _apiMessage = '設定を保存できませんでした。');
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _save() async {
    final trimmedKey = _key.text.trim();
    final keyChanged = trimmedKey != widget.store.apiKey;
    await _edit(
      () async {
        final model = AppConfig.geminiModel(_model.text);
        if (!AppConfig.validGeminiModel(model)) {
          throw const StoreFailure('モデル名の形式を確認してください。');
        }
        if (keyChanged) {
          await widget.store.saveApiKey(_key.text);
        }
        await widget.store.saveModel(model);
        if (mounted) {
          _model.text = widget.store.model;
          _key.text = widget.store.apiKey;
        }
      },
      () => widget.store.hasRemoteKey && !widget.store.remoteConsent
          ? '設定を保存しました。クラウドAIを使うには下のスイッチをONにしてください。'
          : '設定を保存しました。',
    );
  }

  Future<void> _saveModel() async {
    if (_editing) return;
    setState(() {
      _editing = true;
      _modelMessage = null;
    });
    try {
      final model = AppConfig.geminiModel(_model.text);
      if (!AppConfig.validGeminiModel(model)) {
        throw const StoreFailure('モデル名の形式を確認してください。');
      }
      await widget.store.saveModel(model);
      if (mounted) {
        _model.text = widget.store.model;
        setState(() => _modelMessage = 'モデル名を保存しました。');
      }
    } on StoreFailure catch (failure) {
      if (mounted) setState(() => _modelMessage = failure.message);
    } catch (_) {
      if (mounted) setState(() => _modelMessage = 'モデル名を保存できませんでした。');
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _deleteKey() => _edit(() async {
    await widget.store.deleteApiKey();
    if (mounted) _key.clear();
  }, () => 'APIキーを削除しました。');

  Future<void> _verifyConnection() async {
    if (_connection != null || _editing) return;
    final connection = GeminiBackend(apiKey: _key.text, model: _model.text);
    setState(() {
      _connection = connection;
      _connectionMessage = null;
    });
    try {
      await connection.verifyConnection();
      if (mounted && identical(_connection, connection)) {
        setState(() => _connectionMessage = 'キーとモデルへのアクセスを確認できました。');
      }
    } on GeminiFailure catch (failure) {
      if (mounted && identical(_connection, connection)) {
        setState(() => _connectionMessage = failure.message);
      }
    } catch (_) {
      if (mounted && identical(_connection, connection)) {
        setState(() => _connectionMessage = '接続を確認できませんでした。');
      }
    } finally {
      connection.dispose();
      if (mounted && identical(_connection, connection)) {
        setState(() => _connection = null);
      }
    }
  }

  Future<void> _runDiagnosis({bool auto = false}) async {
    final attempt = ++_nanoAttempt;
    setState(() {
      _checking = true;
      if (!auto) {
        _sampleQuestion = null;
        _nanoMessage = null;
      }
    });
    try {
      final result = await _nano.diagnose();
      if (!mounted || attempt != _nanoAttempt) return;
      setState(() => _diagnosis = result);
    } catch (_) {
      if (mounted && attempt == _nanoAttempt) {
        setState(() {
          _diagnosis = const OnDeviceCheck(OnDeviceStatus.checkFailed);
        });
      }
    } finally {
      if (mounted && attempt == _nanoAttempt) {
        setState(() => _checking = false);
      }
    }
  }

  void _downloadProgress(double? value) {
    if (mounted && (_preparingNano || _testingNano)) {
      setState(() => _progress = value);
    }
  }

  Future<void> _prepareNano() async {
    final attempt = ++_nanoAttempt;
    setState(() {
      _preparingNano = true;
      _nanoMessage = null;
      _progress = null;
    });
    try {
      final result = await _nano.prepareModel();
      if (!mounted || attempt != _nanoAttempt) return;
      setState(() {
        _diagnosis = result;
        _nanoMessage = result.status == OnDeviceStatus.available
            ? '端末AIの準備が完了しました。'
            : null;
      });
    } on OnDeviceException catch (error) {
      if (mounted && attempt == _nanoAttempt) {
        setState(() => _nanoMessage = 'モデルの準備ができませんでした。${error.message}');
      }
    } on AiCancelled {
      // 画面を閉じた場合やユーザー中止時。
    } finally {
      if (mounted && attempt == _nanoAttempt) {
        setState(() => _preparingNano = false);
      }
    }
  }

  Future<void> _verifyNano() async {
    final attempt = ++_nanoAttempt;
    setState(() {
      _testingNano = true;
      _sampleQuestion = null;
      _nanoMessage = null;
      _progress = null;
    });
    try {
      final question = await _nano.verifyGeneration();
      if (!mounted || attempt != _nanoAttempt) return;
      setState(() {
        _diagnosis = const OnDeviceCheck(OnDeviceStatus.available);
        _sampleQuestion = question;
      });
    } on OnDeviceException catch (error) {
      if (mounted && attempt == _nanoAttempt) {
        setState(
          () => _nanoMessage = '$onDeviceModelNameで生成できませんでした。${error.message}',
        );
      }
    } on AiCancelled {
      // 画面を閉じた場合もキャンセルする。
    } finally {
      if (mounted && attempt == _nanoAttempt) {
        setState(() => _testingNano = false);
      }
    }
  }

  void _cancelNano() {
    _nanoAttempt++;
    _nano.cancelPending();
    setState(() {
      _preparingNano = false;
      _testingNano = false;
      _nanoMessage = '端末AIの処理を中止しました。';
    });
  }

  String get _diagnosisSummary => switch (_diagnosis?.status) {
    OnDeviceStatus.available => '利用できます（オフラインで動作します）',
    OnDeviceStatus.needsDownload => 'モデルの準備が必要です。',
    OnDeviceStatus.unavailable => 'この端末では利用できません。',
    OnDeviceStatus.checkFailed => '$onDeviceServiceNameの状態を確認できませんでした（使えないと確定ではありません）。下の「質問を試す」で、実際に生成できるか確かめられます。',
    null => _checking ? '対応状況を確認しています…' : '未確認',
  };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connection?.dispose();
    _nano.cancelPending();
    _key.dispose();
    _model.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiBusy = _editing || _connection != null;
    final nanoBusy = _checking || _preparingNano || _testingNano;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final accentText = accentTextColor(context);
    final canToggleConsent =
        widget.store.hasRemoteKey || widget.store.remoteConsent;
    final canToggleChatGptConsent =
        widget.store.chatGptSignedIn || widget.store.chatGptConsent;

    return PopScope(
      canPop: !(_editing || _preparingNano || _cgBusy),
      child: GlassBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('設定'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'AIの優先順：端末AI → ChatGPT → Gemini API → 定型',
                style: TextStyle(fontSize: 13, color: muted, height: 1.4),
              ),
            ),
            // 1. 端末AI（通常面は状態1行＋未取得時は「モデルを準備する」＋確認失敗時は「質問を試す」）
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '端末AI',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _diagnosisSummary,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                  if (_preparingNano) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text(
                      _progress == null
                          ? 'モデルを準備しています…'
                          : 'モデル取得中 ${(_progress! * 100).round()}%',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _cancelNano,
                        child: const Text('中止する'),
                      ),
                    ),
                  ] else if (_testingNano) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text(
                      _progress == null
                          ? 'モデルの準備状況を確認し、サンプル質問を生成しています。'
                          : 'モデル取得中 ${(_progress! * 100).round()}%',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _cancelNano,
                        child: const Text('中止する'),
                      ),
                    ),
                  ] else if (_diagnosis?.status ==
                      OnDeviceStatus.needsDownload) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: accentTonalFill(context),
                        foregroundColor: accentText,
                      ),
                      onPressed: nanoBusy ? null : _prepareNano,
                      child: const Text('モデルを準備する'),
                    ),
                  ] else if (_diagnosis?.status ==
                      OnDeviceStatus.checkFailed) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: accentTonalFill(context),
                        foregroundColor: accentText,
                      ),
                      onPressed: nanoBusy ? null : _verifyNano,
                      child: const Text('質問を試す'),
                    ),
                  ],
                  if (_nanoMessage case final message?) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                    ),
                  ],
                  if (_sampleQuestion case final question?) ...[
                    const SizedBox(height: 10),
                    Text(
                      '$onDeviceModelNameで生成できました',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(question.text),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 2. ChatGPT（v0.4.0: サインインで本人の ChatGPT を使う）
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'ChatGPT',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.store.chatGptSignedIn
                        ? widget.store.chatGptConsent
                            ? 'サインイン済み。端末AIが使えない時は、あなたの ChatGPT で深掘りします。'
                            : 'サインイン済み。下のスイッチをONにすると、端末AIが使えない時に ChatGPT で深掘りします。'
                        : 'サインインすると、あなたの ChatGPT（サブスクリプション）で深掘りできます。トークンは端末の中だけに保存されます。',
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  if (widget.store.chatGptSignedIn)
                    OutlinedButton(
                      onPressed: _cgBusy ? null : _chatGptSignOut,
                      child: const Text('サインアウト'),
                    )
                  else
                    FilledButton(
                      onPressed: _cgBusy ? null : _chatGptSignIn,
                      style: FilledButton.styleFrom(
                        backgroundColor: kButtonFill,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(_cgBusy ? 'サインイン中…' : 'ChatGPTでサインイン'),
                    ),
                  if (_cgMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _cgMessage!,
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('端末AIが使えないときにChatGPTを使う'),
                      subtitle: !canToggleChatGptConsent
                          ? Text(
                              'サインインするとONにできます。',
                              style: TextStyle(fontSize: 12, color: muted),
                            )
                          : null,
                      value: widget.store.chatGptConsent,
                      onChanged: _cgBusy || _editing || !canToggleChatGptConsent
                          ? null
                          : _toggleChatGptConsent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '送信内容：タイトル・メモ・深掘りの回答をOpenAIへ送信します。\n'
                    '注意点：個人情報や機密情報は入力しないでください。この連携は非公式な方式のため、仕様変更により予告なく利用できなくなる場合があります。',
                    style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                  ),
                  if (!widget.store.chatGptSignedIn) ...[
                    const SizedBox(height: 6),
                    Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'ブラウザから戻れない時は',
                          style: TextStyle(fontSize: 13),
                        ),
                        childrenPadding: const EdgeInsets.only(bottom: 8),
                        children: [
                          const Text(
                            'サインインを開始したあと、ブラウザに表示された認可コードを貼り付けてください。',
                            style: TextStyle(fontSize: 12, height: 1.6),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _codeCtrl,
                            enabled: !_cgBusy,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            decoration: glassInputDecoration(
                              context,
                              labelText: '認可コード',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _cgBusy ? null : _chatGptSignInWithCode,
                            child: const Text('コードでサインイン'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 3. クラウドAI（キー入力＋取得先1行 → 保存 → クラウド送信スイッチ＋必須開示2要素）
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'クラウドAI（Gemini API）',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Google AI Studio で取得したAPIキーを入力できます。',
                    style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    enabled: !apiBusy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: glassInputDecoration(
                      context,
                      labelText: 'APIキー',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'APIキーを表示' : 'APIキーを隠す',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kButtonFill,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: apiBusy ? null : _save,
                    child: const Text('保存する'),
                  ),
                  if (widget.store.hasRemoteKey ||
                      widget.store.keyStorageError != null) ...[
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: apiBusy ? null : _deleteKey,
                      child: const Text('キーを削除する'),
                    ),
                  ],
                  if ((_apiMessage ?? widget.store.keyStorageError)
                      case final message?) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('端末AIが使えないときにGemini APIを使う'),
                      subtitle: !canToggleConsent
                          ? Text(
                              'APIキーを保存するとONにできます。',
                              style: TextStyle(fontSize: 12, color: muted),
                            )
                          : null,
                      value: widget.store.remoteConsent,
                      onChanged: apiBusy || !canToggleConsent
                          ? null
                          : (value) => _edit(
                              () => widget.store.saveRemoteConsent(value),
                              () => value
                                  ? 'クラウド送信を有効にしました。'
                                  : 'クラウド送信を停止しました。',
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // R-04 必須開示下限（常時表示）: ①送信対象 ②無料枠注意
                  Text(
                    '送信内容：タイトル・メモ・深掘りの回答をGoogleのGemini APIへ送信します。\n'
                    '注意点：無料枠では入力がGoogleのモデル改善等に使われる場合があります。個人情報や機密情報は入力しないでください。',
                    style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 4. Google Workspace（v0.5.0: 企画メモを Google ドキュメント化）
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Google Workspace',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (!_google.isConfigured)
                    const Text(
                      '未設定（セットアップ待ち）です。Google Cloud 側の設定が完了したビルドで有効になります。有効になると、完成した企画メモを Google ドキュメントとしてドライブへ送れます。',
                      style: TextStyle(fontSize: 13, height: 1.6),
                    )
                  else if (_gAccount case final account?)
                    Text(
                      'サインイン済み（${account.email}）。企画メモの画面から Google ドキュメント化できます。アクセスは、このアプリが作ったファイルだけに限られます。',
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    )
                  else
                    const Text(
                      'サインインすると、完成した企画メモを Google ドキュメントとしてドライブへ送れます。アクセスは、このアプリが作ったファイルだけ（drive.file）に限られます。',
                      style: TextStyle(fontSize: 13, height: 1.6),
                    ),
                  if (_google.isConfigured) ...[
                    const SizedBox(height: 12),
                    if (_gAccount != null)
                      OutlinedButton(
                        onPressed: _gBusy ? null : _googleSignOut,
                        child: const Text('サインアウト'),
                      )
                    else
                      FilledButton(
                        onPressed: _gBusy || !_gChecked
                            ? null
                            : _googleSignIn,
                        style: FilledButton.styleFrom(
                          backgroundColor: kButtonFill,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(_gBusy
                            ? 'サインイン中…'
                            : !_gChecked
                                ? '確認中…'
                                : 'Googleでサインイン'),
                      ),
                  ],
                  if (_gMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(_gMessage!,
                        style: const TextStyle(fontSize: 13, height: 1.6)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 5. 詳細・動作確認（開発者向け診断・テスト・モデル名を折りたたみへ隔離）
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      '詳細・動作確認',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    children: [
                      const SizedBox(height: 8),
                      TextField(
                        controller: _model,
                        enabled: !apiBusy,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: glassInputDecoration(
                          context,
                          labelText: 'モデル名',
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: apiBusy ? null : _saveModel,
                        child: const Text('モデル名を保存'),
                      ),
                      if (_modelMessage case final message?) ...[
                        const SizedBox(height: 6),
                        Text(
                          message,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: apiBusy ? null : _verifyConnection,
                        child: Text(
                          _connection == null ? 'キーとモデルの接続を確認' : '接続を確認中…',
                        ),
                      ),
                      if (_connectionMessage case final message?) ...[
                        const SizedBox(height: 6),
                        Text(
                          message,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: nanoBusy ? null : () => _runDiagnosis(),
                        child: Text(_checking ? '確認中…' : '状態を確認する'),
                      ),
                      if (_diagnosis case final diagnosis?) ...[
                        const SizedBox(height: 8),
                        Text(
                          _diagnosisSummary,
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (diagnosis.message.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            diagnosis.message,
                            style: TextStyle(fontSize: 12, color: muted),
                          ),
                        ],
                      ],
                      const SizedBox(height: 10),
                      if (_testingNano) ...[
                        LinearProgressIndicator(value: _progress),
                        const SizedBox(height: 8),
                        Text(
                          _progress == null
                              ? 'モデルの準備状況を確認し、サンプル質問を生成しています。'
                              : 'モデル取得中 ${(_progress! * 100).round()}%',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                        TextButton(
                          onPressed: _cancelNano,
                          child: const Text('中止する'),
                        ),
                      ] else
                        OutlinedButton(
                          onPressed: nanoBusy ? null : _verifyNano,
                          child: Text(onDeviceModelName == 'Gemini Nano'
                              ? 'Nanoで質問を試す'
                              : '$onDeviceModelNameで質問を試す'),
                        ),
                      if (_nanoMessage case final message?) ...[
                        const SizedBox(height: 8),
                        Text(
                          message,
                          style: TextStyle(
                            fontSize: 13,
                            color: muted,
                            height: 1.5,
                          ),
                        ),
                      ],
                      if (_sampleQuestion case final question?) ...[
                        const SizedBox(height: 10),
                        Text(
                          '$onDeviceModelNameで生成できました',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(question.text),
                      ],
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }
}
