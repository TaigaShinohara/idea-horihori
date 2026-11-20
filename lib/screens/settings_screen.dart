import 'package:flutter/material.dart';

import '../app_config.dart';
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
                  const Text('Gemini APIキー（BYOK）',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    '自分のキーを入れるとAIが質問します。空でも定型の質問で深掘りできます。キーはこの端末の中だけに保存されます。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'キーは Google AI Studio（aistudio.google.com）で無料で作れます。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 10),
                  // K1: 現在の有効状態（AI有効／定型モード）を常時見せる。
                  AnimatedBuilder(
                    animation: widget.store,
                    builder: (context, _) {
                      final ai = widget.store.hasRemoteKey;
                      return Row(
                        children: [
                          Icon(
                            ai ? Icons.auto_awesome : Icons.list_alt_outlined,
                            size: 16,
                            color: kAccentDeep,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            ai
                                ? '現在の状態：AI有効（Gemini）'
                                : '現在の状態：定型モード（キー未設定）',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: kAccentDeep,
                            ),
                          ),
                        ],
                      );
                    },
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
                  const SizedBox(height: 12),
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
          ],
        ),
      ),
    );
  }
}
