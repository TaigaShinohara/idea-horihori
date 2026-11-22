import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_backend.dart';
import 'app_config.dart';
import 'dig_mode.dart';
import 'models.dart';

/// 端末内のみの保存（SharedPreferences に JSON）。アカウント・同期なし。
/// APIキーはここに保存するが、ログには決して出さない。
class IdeaStore extends ChangeNotifier {
  List<Idea> ideas = [];
  String apiKey = '';
  String model = AppConfig.defaultGeminiModel;
  bool loaded = false;

  /// K3: キー未設定時の初回案内を出したかどうか（1回だけ出す）。
  bool keyGuideShown = false;

  /// 掘り方スタイル（v0.2 項目1）。既定は友達モード。再起動後も保持する。
  DigStyle digStyle = DigStyle.friend;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = prefs.getString(AppConfig.prefsApiKeyKey) ?? '';
    model = prefs.getString(AppConfig.prefsModelKey) ?? AppConfig.defaultGeminiModel;
    keyGuideShown = prefs.getBool(AppConfig.prefsKeyGuideShownKey) ?? false;
    digStyle =
        DigStyleX.fromStorage(prefs.getString(AppConfig.prefsDigStyleKey));
    final raw = prefs.getString(AppConfig.prefsIdeasKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        ideas = list
            .map((e) => Idea.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        // パース失敗でデータを握りつぶさない: 原文を別キーへ退避してから
        // 空で開始する（次の保存で壊れた原文ごと消える事故を防ぐ）。
        await prefs.setString(AppConfig.prefsIdeasBackupKey, raw);
        ideas = [];
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _saveIdeas() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConfig.prefsIdeasKey,
      jsonEncode(ideas.map((e) => e.toJson()).toList()),
    );
  }

  List<Idea> get visibleIdeas =>
      ideas.where((i) => !i.archived).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<Idea> get archivedIdeas =>
      ideas.where((i) => i.archived).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// リモート（Gemini）を使える設定かどうか。
  bool get hasRemoteKey => apiKey.isNotEmpty;

  Future<Idea> addIdea(String title, String note) async {
    final idea = Idea(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim(),
      note: note.trim(),
      createdAt: DateTime.now(),
    );
    ideas.add(idea);
    await _saveIdeas();
    notifyListeners();
    return idea;
  }

  Future<void> updateIdea(Idea idea) async {
    await _saveIdeas();
    notifyListeners();
  }

  Future<void> archiveIdea(Idea idea) async {
    idea.archived = true;
    await _saveIdeas();
    notifyListeners();
  }

  /// アーカイブから一覧へ戻す。
  Future<void> unarchiveIdea(Idea idea) async {
    idea.archived = false;
    await _saveIdeas();
    notifyListeners();
  }

  /// 完全に削除する（復元不可。呼び出し側で確認を取ること）。
  Future<void> deleteIdea(Idea idea) async {
    ideas.remove(idea);
    await _saveIdeas();
    notifyListeners();
  }

  /// K3: 初回案内を表示済みにし、以後は再表示しない。
  Future<void> markKeyGuideShown() async {
    keyGuideShown = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.prefsKeyGuideShownKey, true);
    notifyListeners();
  }

  /// 掘り方スタイルを保存する（v0.2 項目1）。
  Future<void> saveDigStyle(DigStyle style) async {
    digStyle = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.prefsDigStyleKey, style.storageValue);
    notifyListeners();
  }

  Future<void> saveApiKey(String key) async {
    apiKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.prefsApiKeyKey, apiKey);
    notifyListeners();
  }

  Future<void> saveModel(String m) async {
    model = m.trim().isEmpty ? AppConfig.defaultGeminiModel : m.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.prefsModelKey, model);
    notifyListeners();
  }

  /// 現在の設定でバックエンドを組む。キー未設定ならローカルのみ。
  ResilientBackend backend() {
    if (apiKey.isEmpty) return ResilientBackend(null);
    return ResilientBackend(GeminiBackend(apiKey: apiKey, model: model));
  }
}
