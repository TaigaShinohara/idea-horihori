import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../app_config.dart';
import '../chatgpt_auth_service.dart';
import '../models.dart';
import '../on_device_backend.dart';
import '../store.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  final IdeaStore store;
  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
  String? _nanoMessage;

  // v0.4.0: ChatGPT サインイン。
  final ChatGptAuthService _chatGptAuth = ChatGptAuthService();
  final TextEditingController _codeCtrl = TextEditingController();
  bool _cgBusy = false;
  String? _cgMessage;

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
    } catch (e) {
      if (!mounted) return;
      setState(() => _cgMessage = 'サインインに失敗しました: $e');
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
      setState(() => _cgMessage = 'サインインしました');
    } on ChatGptAuthException catch (e) {
      if (!mounted) return;
      setState(() => _cgMessage = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _cgMessage = 'サインインに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _cgBusy = false);
    }
  }

  Future<void> _chatGptSignOut() async {
    await _chatGptAuth.signOut();
    await widget.store.refreshChatGptStatus();
    if (!mounted) return;
    setState(() => _cgMessage = 'サインアウトしました');
  }

  @override
  void initState() {
    super.initState();
    final cached = widget.store.cachedOnDeviceStatus;
    if (cached != null) {
      _diagnosis = cached;
    } else {
      _runDiagnosis(auto: true);
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

  Future<void> _deleteKey() => _edit(() async {
    await widget.store.deleteApiKey();
    if (mounted) _key.clear();
  }, () => 'APIキーを削除しました。');

  Future<void> _verifyConnection() async {
    final connection = GeminiBackend(apiKey: _key.text, model: _model.text);
    setState(() {
      _connection = connection;
      _apiMessage = null;
    });
    try {
      await connection.verifyConnection();
      if (mounted) {
        setState(() => _apiMessage = 'キーとモデルへのアクセスを確認できました。');
      }
    } on GeminiFailure catch (failure) {
      if (mounted) setState(() => _apiMessage = failure.message);
    } catch (_) {
      if (mounted) setState(() => _apiMessage = '接続を確認できませんでした。');
    } finally {
      if (mounted) setState(() => _connection = null);
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
    final result = await _nano.diagnose();
    if (!mounted || attempt != _nanoAttempt) return;
    setState(() {
      _checking = false;
      _diagnosis = result;
    });
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
          () => _nanoMessage = 'Gemini Nanoで生成できませんでした。${error.message}',
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
    OnDeviceStatus.checkFailed => 'AICoreの状態を確認できませんでした。少し待って再確認してください。',
    null => _checking ? '対応状況を確認しています…' : '未確認',
  };

  @override
  void dispose() {
    _connection?.cancelPending();
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

    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('設定'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // 1. 端末AI（通常面は状態1行＋未取得時のみ「モデルを準備する」）
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
                  ],
                  if (_nanoMessage case final message?) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 2. クラウドAI（キー入力＋取得先1行 → 保存 → クラウド送信スイッチ＋必須開示2要素）
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
            // 3. ChatGPT（v0.4.0: サインインで本人の ChatGPT を使う）
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('ChatGPT',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    widget.store.chatGptSignedIn
                        ? 'サインイン済み。オンデバイスが使えない時は、あなたの ChatGPT で深掘りします。'
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
                    Text(_cgMessage!,
                        style: const TextStyle(fontSize: 13, height: 1.6)),
                  ],
                  if (!widget.store.chatGptSignedIn) ...[
                    const SizedBox(height: 6),
                    Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        title: const Text('ブラウザから戻れない時は',
                            style: TextStyle(fontSize: 13)),
                        childrenPadding:
                            const EdgeInsets.only(bottom: 8),
                        children: [
                          const Text(
                            'サインインを開始したあと、ブラウザに表示された認可コードを貼り付けてください。',
                            style: TextStyle(fontSize: 12, height: 1.6),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _codeCtrl,
                            decoration: const InputDecoration(
                              labelText: '認可コード',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed:
                                _cgBusy ? null : _chatGptSignInWithCode,
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
            // 4. 詳細・動作確認（開発者向け診断・テスト・モデル名を折りたたみへ隔離）
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
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: apiBusy ? null : _verifyConnection,
                        child: Text(
                          _connection == null ? 'キーとモデルの接続を確認' : '接続を確認中…',
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: nanoBusy ? null : () => _runDiagnosis(),
                        child: Text(_checking ? '確認中…' : '状態を確認する'),
                      ),
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
                          child: const Text('Nanoで質問を試す'),
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
                      if (_sampleQuestion case final question?) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'Gemini Nanoで生成できました',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
    );
  }
}
