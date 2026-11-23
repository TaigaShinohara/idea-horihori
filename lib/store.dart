import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_backend.dart';
import 'app_config.dart';
import 'on_device_backend.dart';
import 'dig_mode.dart';
import 'models.dart';

/// 端末内のみの保存（SharedPreferences に JSON）。アカウント・同期なし。
/// APIキーはここに保存するが、ログには決して出さない。
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;
  static final Map<String, String> _testFallback = {};
  @visibleForTesting
  static void resetForTest() => _testFallback.clear();
  PlatformSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on MissingPluginException {
      return _testFallback[key];
    } on PlatformException {
      return _testFallback[key];
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on MissingPluginException {
      _testFallback[key] = value;
    } on PlatformException {
      _testFallback[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on MissingPluginException {
      _testFallback.remove(key);
    } on PlatformException {
      _testFallback.remove(key);
    }
  }
}

class IdeaStore extends ChangeNotifier {
  final SecretStore _secrets;
  IdeaStore({SecretStore? secrets}) : _secrets = secrets ?? PlatformSecretStore();

  List<Idea> ideas = [];
  String apiKey = '';
  String model = AppConfig.defaultGeminiModel;
  bool loaded = false;
  bool remoteConsent = false;

  /// K3: キー未設定時の初回案内を出したかどうか（1回だけ出す）。
  bool keyGuideShown = false;

  /// 掘り方スタイル（v0.2 項目1）。既定は友達モード。再起動後も保持する。
  DigStyle digStyle = DigStyle.friend;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = await _secrets.read(AppConfig.secureApiKeyKey) ?? '';
    if (apiKey.isEmpty) {
      final legacyKey = prefs.getString(AppConfig.prefsApiKeyKey);
      if (legacyKey != null && legacyKey.isNotEmpty) {
        await _secrets.write(AppConfig.secureApiKeyKey, legacyKey.trim());
        apiKey = legacyKey.trim();
      }
    }
    await prefs.remove(AppConfig.prefsApiKeyKey);
    remoteConsent =
        prefs.getBool(AppConfig.prefsRemoteConsentKey) ?? false;
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
    if (apiKey.isEmpty) {
      await _secrets.delete(AppConfig.secureApiKeyKey);
    } else {
      await _secrets.write(AppConfig.secureApiKeyKey, apiKey);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.prefsApiKeyKey);
    notifyListeners();
  }

  Future<void> deleteApiKey() async {
    apiKey = '';
    await _secrets.delete(AppConfig.secureApiKeyKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.prefsApiKeyKey);
    notifyListeners();
  }

  Future<void> saveRemoteConsent(bool consent) async {
    remoteConsent = consent;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.prefsRemoteConsentKey, consent);
    notifyListeners();
  }

  Future<void> saveModel(String m) async {
    model = m.trim().isEmpty ? AppConfig.defaultGeminiModel : m.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.prefsModelKey, model);
    notifyListeners();
  }

  /// 現在の設定でバックエンドを組む。
  /// v0.3.0 PoC: 優先順は オンデバイス → Gemini（キーがある場合）→ 定型。
  ResilientBackend backend() {
    return ResilientBackend(
      apiKey.isEmpty || !remoteConsent
          ? null
          : GeminiBackend(apiKey: apiKey, model: model),
      onDevice: OnDeviceBackend(),
    );
  }
}
