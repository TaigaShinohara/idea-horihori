import 'package:flutter/material.dart';

import '../app_config.dart';
import '../on_device_backend.dart';
import '../store.dart';
import '../widgets/glass.dart';

/// S5 設定。Gemini APIキーの BYOK 入力・保存。
/// キーは端末内だけに保存し、表示は伏せる。
class SettingsScreen extends StatefulWidget {
  final IdeaStore store;
  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _keyCtrl =
      TextEditingController(text: widget.store.apiKey);
  late final TextEditingController _modelCtrl =
      TextEditingController(text: widget.store.model);
  bool _obscure = true;
  bool _saved = false;

  // v0.3.1: オンデバイスAIの診断表示。
  bool _checking = false;
  OnDeviceCheck? _diag;

  Future<void> _runDiagnosis() async {
    setState(() => _checking = true);
    final result = await OnDeviceBackend().diagnose();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _diag = result;
    });
  }

  String get _diagLabel => switch (_diag?.status) {
        OnDeviceStatus.available => '使える状態です',
        OnDeviceStatus.needsDownload =>
          'モデルのダウンロードが必要です（初回の深掘りで自動で落とします）',
        OnDeviceStatus.unavailable => 'この端末では使えない状態です',
        null => '',
      };

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GlassBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Gemini APIキー',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    '入れるとAIが質問する。空でも定型で掘れる。キーは端末内だけに保存。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'キーは Google AI Studio（aistudio.google.com）で無料で作れます。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      hintText: 'APIキー',
                      filled: true,
                      fillColor: glassInputFill(context),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  // v0.2.1 ノイズ削減: モデル名は通常変更不要の支援項目 → 畳む。
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('詳細', style: TextStyle(fontSize: 13)),
                    children: [
                      TextField(
                        controller: _modelCtrl,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'モデル名',
                          hintText: AppConfig.defaultGeminiModel,
                          filled: true,
                          fillColor: glassInputFill(context),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: kButtonFill),
                    onPressed: () async {
                      await widget.store.saveApiKey(_keyCtrl.text);
                      await widget.store.saveModel(_modelCtrl.text);
                      setState(() => _saved = true);
                    },
                    child: const Text('保存する'),
                  ),
                  if (_saved)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('保存しました', textAlign: TextAlign.center),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('オンデバイスAI',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    '端末の中のAIで深掘りする機能。使えない時は理由を確認できます。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _checking ? null : _runDiagnosis,
                    child: Text(_checking ? '確認中…' : '状態を確認する'),
                  ),
                  if (_diag != null) ...[
                    const SizedBox(height: 10),
                    Text(_diagLabel,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold)),
                    if (_diag!.message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_diag!.message,
                            style: const TextStyle(fontSize: 12, height: 1.6)),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
