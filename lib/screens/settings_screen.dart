import 'package:flutter/material.dart';

import '../ai_backend.dart';
import '../app_config.dart';
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
  late final _nano = OnDeviceBackend(onDownloadProgress: _downloadProgress);
  bool _obscure = true;
  bool _editing = false;
  bool _checking = false;
  bool _testingNano = false;
  double? _progress;
  int _nanoAttempt = 0;
  OnDeviceCheck? _diagnosis;
  DigQuestion? _sampleQuestion;
  GeminiBackend? _connection;
  String? _apiMessage;
  String? _nanoMessage;

  Future<void> _edit(Future<void> Function() change, String success) async {
    if (_editing) return;
    setState(() {
      _editing = true;
      _apiMessage = null;
    });
    try {
      await change();
      if (mounted) setState(() => _apiMessage = success);
    } on StoreFailure catch (failure) {
      if (mounted) setState(() => _apiMessage = failure.message);
    } catch (_) {
      if (mounted) setState(() => _apiMessage = '設定を保存できませんでした。');
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _save() => _edit(() async {
    final model = AppConfig.geminiModel(_model.text);
    if (!AppConfig.validGeminiModel(model)) {
      throw const StoreFailure('モデル名の形式を確認してください。');
    }
    if (_key.text.trim().isNotEmpty || widget.store.hasRemoteKey) {
      await widget.store.saveApiKey(_key.text);
    }
    await widget.store.saveModel(model);
    if (mounted) {
      _model.text = widget.store.model;
      _key.text = widget.store.apiKey;
    }
  }, '設定を保存しました。');

  Future<void> _deleteKey() => _edit(() async {
    await widget.store.deleteApiKey();
    if (mounted) _key.clear();
  }, 'APIキーを削除しました。');

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

  Future<void> _runDiagnosis() async {
    setState(() {
      _checking = true;
      _sampleQuestion = null;
      _nanoMessage = null;
    });
    final result = await _nano.diagnose();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _diagnosis = result;
    });
  }

  void _downloadProgress(double? value) {
    if (mounted && _testingNano) setState(() => _progress = value);
  }

  Future<void> _verifyNano() async {
    final attempt = ++_nanoAttempt;
    setState(() {
      _testingNano = true;
      _diagnosis = null;
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
          () => _nanoMessage = 'Gemini Nanoで生成できませんでした。 ${error.message}',
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
      _testingNano = false;
      _nanoMessage = '端末AIの確認を中止しました。';
    });
  }

  String get _diagnosisLabel => switch (_diagnosis?.status) {
    OnDeviceStatus.available => 'モデルの準備ができています',
    OnDeviceStatus.needsDownload => 'モデルの準備が必要です。「Nanoで質問を試す」で取得を始めます。',
    OnDeviceStatus.unavailable => '現在は利用できません。対応機種とAndroid AICoreの更新を確認してください。',
    OnDeviceStatus.checkFailed => 'AICoreの状態を確認できませんでした。少し待って再確認してください。',
    null => '',
  };

  @override
  void dispose() {
    _connection?.cancelPending();
    _nano.cancelPending();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiBusy = _editing || _connection != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Colors.transparent,
      ),
      body: GlassBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'オンデバイスAI',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text('対応するAndroidではGemini Nanoを優先します。'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _checking || _testingNano ? null : _runDiagnosis,
                    child: Text(_checking ? '確認中…' : '状態を確認する'),
                  ),
                  if (_testingNano) ...[
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text(
                      _progress == null
                          ? 'モデルの準備状況を確認し、サンプル質問を生成しています。'
                          : 'モデル取得中 ${(_progress! * 100).round()}%',
                    ),
                    TextButton(
                      onPressed: _cancelNano,
                      child: const Text('中止する'),
                    ),
                  ] else
                    OutlinedButton(
                      onPressed: _checking ? null : _verifyNano,
                      child: const Text('Nanoで質問を試す'),
                    ),
                  if (_diagnosis case final diagnosis?) ...[
                    const SizedBox(height: 8),
                    Text(_diagnosisLabel),
                    if (diagnosis.message.isNotEmpty)
                      Text(
                        diagnosis.message,
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                  if (_sampleQuestion case final question?) ...[
                    const Text('Gemini Nanoで生成できました'),
                    Text(question.text),
                  ],
                  if (_nanoMessage case final message?) Text(message),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'クラウド送信',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('端末AIが使えないときにGemini APIを使う'),
                      value: widget.store.remoteConsent,
                      onChanged:
                          apiBusy ||
                              (!widget.store.hasRemoteKey &&
                                  !widget.store.remoteConsent)
                          ? null
                          : (value) => _edit(
                              () => widget.store.saveRemoteConsent(value),
                              value ? 'クラウド送信を有効にしました。' : 'クラウド送信を停止しました。',
                            ),
                    ),
                  ),
                  const Text(
                    '質問・企画メモの生成では、タイトル、関連する最近の質問と回答、最新の企画メモをGoogleへ送ります。'
                    '質問では入力した補足、名前候補ではタイトルと最新の企画メモを使います。'
                    '無料枠では、利用地域に応じて入力と出力がGoogleのサービス改善や人による確認に使われる場合があります。',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Gemini APIキー（任意）',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _key,
                    enabled: !apiBusy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
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
                  Material(
                    type: MaterialType.transparency,
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('モデル設定'),
                      children: [
                        TextField(
                          controller: _model,
                          enabled: !apiBusy,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(labelText: 'モデル名'),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    onPressed: apiBusy ? null : _save,
                    child: const Text('保存する'),
                  ),
                  OutlinedButton(
                    onPressed: apiBusy ? null : _verifyConnection,
                    child: Text(
                      _connection == null ? 'キーとモデルの接続を確認' : '接続を確認中…',
                    ),
                  ),
                  if (widget.store.hasRemoteKey ||
                      widget.store.keyStorageError != null)
                    TextButton(
                      onPressed: apiBusy ? null : _deleteKey,
                      child: const Text('キーを削除する'),
                    ),
                  if ((_apiMessage ?? widget.store.keyStorageError)
                      case final message?)
                    Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
