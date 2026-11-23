import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
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
  PlatformSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class StoreFailure implements Exception {
  const StoreFailure(this.message);
  final String message;
}

class IdeaStore extends ChangeNotifier {
  final SecretStore _secrets;
  IdeaStore({SecretStore? secrets})
    : _secrets = secrets ?? PlatformSecretStore();

  List<Idea> ideas = [];
  String _apiKey = '';
  String get apiKey => _apiKey;
  String _model = AppConfig.defaultGeminiModel;
  String get model => _model;
  bool loaded = false;
  bool _loading = false;
  String? loadError;
  bool _remoteConsent = false;
  bool get remoteConsent => _remoteConsent;
  String? keyStorageError;
  String? ideasRecoveryNotice;
  bool _ideasWritable = true;
  final _cloudChanges = ChangeNotifier();
  int _cloudRevision = 0;
  int _consentRevision = 0;
  Future<void> _settingsQueue = Future.value();
  Future<void> _ideasQueue = Future.value();

  /// K3: キー未設定時の初回案内を出したかどうか（1回だけ出す）。
  bool keyGuideShown = false;

  /// 掘り方スタイル（v0.2 項目1）。既定は友達モード。再起動後も保持する。
  DigStyle digStyle = DigStyle.friend;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    loadError = null;
    notifyListeners();
    try {
      await _readPreferences(
        await SharedPreferences.getInstance().timeout(
          const Duration(seconds: 6),
        ),
      );
      loaded = true;
    } catch (_) {
      loadError = '端末のデータを読み込めませんでした。';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _readPreferences(SharedPreferences prefs) async {
    keyStorageError = null;
    _remoteConsent = false;
    _invalidateCloud();
    try {
      await _loadApiKey(prefs);
      _remoteConsent =
          hasRemoteKey && prefs.get(AppConfig.prefsRemoteConsentKey) == true;
    } catch (_) {
      _apiKey = '';
      keyStorageError = 'APIキーを安全な保存先から読み込めませんでした。設定で確認してください。';
    }
    final storedModel = prefs.get(AppConfig.prefsModelKey);
    _model = AppConfig.geminiModel(storedModel is String ? storedModel : null);
    if (storedModel is String && storedModel != _model) {
      try {
        await prefs.setString(AppConfig.prefsModelKey, _model);
      } catch (_) {
        // 次回も読み込み時に旧モデルを移行する。
      }
    }
    keyGuideShown = prefs.get(AppConfig.prefsKeyGuideShownKey) == true;
    final style = prefs.get(AppConfig.prefsDigStyleKey);
    digStyle = DigStyleX.fromStorage(style is String ? style : null);
    await _loadIdeas(prefs);
  }

  Future<void> _loadApiKey(SharedPreferences prefs) async {
    _apiKey = await _readKey() ?? '';
    final legacy = prefs.get(AppConfig.prefsApiKeyKey);
    if (legacy is! String || legacy.isEmpty) return;
    if (_apiKey.isEmpty && legacy.trim().isNotEmpty) {
      await _writeKey(legacy.trim());
      _apiKey = legacy.trim();
    }
    _checkWrite(await prefs.remove(AppConfig.prefsApiKeyKey));
  }

  Future<void> _loadIdeas(SharedPreferences prefs) async {
    ideas = [];
    ideasRecoveryNotice = null;
    _ideasWritable = true;
    final raw = prefs.get(AppConfig.prefsIdeasKey);
    if (raw == null || raw == '') return;
    var damaged = 0;
    try {
      final records = jsonDecode(raw as String) as List;
      for (final record in records) {
        try {
          ideas.add(Idea.fromJson(record as Map<String, dynamic>));
        } catch (_) {
          damaged++;
        }
      }
    } catch (_) {
      damaged++;
    }
    if (damaged == 0) return;
    try {
      final original = raw is String ? raw : jsonEncode(raw);
      final backup = prefs.get(AppConfig.prefsIdeasBackupKey);
      final alreadySaved = backup == original || prefs.getKeys().any(
        (key) => key.startsWith('${AppConfig.prefsIdeasBackupKey}_') &&
            prefs.get(key) == original,
      );
      if (!alreadySaved) {
        final key = backup == null
            ? AppConfig.prefsIdeasBackupKey
            : '${AppConfig.prefsIdeasBackupKey}_${DateTime.now().microsecondsSinceEpoch}';
        _checkWrite(await prefs.setString(key, original));
      }
      ideasRecoveryNotice = '読み込めないアイデアデータを端末内に退避しました。';
    } catch (_) {
      _ideasWritable = false;
      ideasRecoveryNotice = '元データを保護するため、現在は変更を保存できません。';
    }
  }

  Future<void> _saveIdeas() async {
    if (!_ideasWritable) throw StoreFailure(ideasRecoveryNotice!);
    final snapshot = jsonEncode(ideas.map((e) => e.toJson()).toList());
    final prefs = await SharedPreferences.getInstance();
    _checkWrite(await prefs.setString(AppConfig.prefsIdeasKey, snapshot));
  }

  Future<T> _changeIdeas<T>(Future<T> Function() change) {
    final write = _ideasQueue.then((_) => change());
    _ideasQueue = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  static void _checkWrite(bool saved) {
    if (!saved) throw const StoreFailure('端末に保存できませんでした。もう一度お試しください。');
  }

  List<Idea> get visibleIdeas =>
      ideas.where((i) => !i.archived).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<Idea> get archivedIdeas =>
      ideas.where((i) => i.archived).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// リモート（Gemini）を使える設定かどうか。
  bool get hasRemoteKey => apiKey.isNotEmpty;

  Future<Idea> addIdea(String title, String note) => _changeIdeas(() async {
    final now = DateTime.now();
    final idea = Idea(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim(),
      note: note.trim(),
      createdAt: now,
    );
    ideas.add(idea);
    try {
      await _saveIdeas();
    } catch (_) {
      ideas.remove(idea);
      rethrow;
    }
    notifyListeners();
    return idea;
  });

  Future<void> updateIdea(Idea idea) => _changeIdeas(() async {
    if (!ideas.contains(idea)) throw const StoreFailure('アイデアを確認できませんでした。');
    await _saveIdeas();
    notifyListeners();
  });

  Future<void> archiveIdea(Idea idea) => _setArchived(idea, true);

  /// アーカイブから一覧へ戻す。
  Future<void> unarchiveIdea(Idea idea) => _setArchived(idea, false);

  Future<void> _setArchived(Idea idea, bool archived) => _changeIdeas(() async {
    if (!ideas.contains(idea) || idea.archived == archived) return;
    idea.archived = archived;
    try {
      await _saveIdeas();
    } catch (_) {
      idea.archived = !archived;
      rethrow;
    }
    notifyListeners();
  });

  /// 完全に削除する（復元不可。呼び出し側で確認を取ること）。
  Future<void> deleteIdea(Idea idea) => _changeIdeas(() async {
    final index = ideas.indexOf(idea);
    if (index < 0) return;
    ideas.removeAt(index);
    try {
      await _saveIdeas();
    } catch (_) {
      ideas.insert(index, idea);
      rethrow;
    }
    notifyListeners();
  });

  /// K3: 初回案内を表示済みにし、以後は再表示しない。
  Future<void> markKeyGuideShown() async {
    keyGuideShown = true;
    final prefs = await SharedPreferences.getInstance();
    _checkWrite(await prefs.setBool(AppConfig.prefsKeyGuideShownKey, true));
    notifyListeners();
  }

  /// 掘り方スタイルを保存する（v0.2 項目1）。
  Future<void> saveDigStyle(DigStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    _checkWrite(
      await prefs.setString(AppConfig.prefsDigStyleKey, style.storageValue),
    );
    digStyle = style;
    notifyListeners();
  }

  void _invalidateCloud() {
    _cloudRevision++;
    _cloudChanges.notifyListeners();
  }

  Future<void> _saveSettings(Future<void> Function() action) {
    final write = _settingsQueue.then((_) => action());
    _settingsQueue = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _writeKey(String value) async {
    await _secrets
        .write(AppConfig.secureApiKeyKey, value)
        .timeout(const Duration(seconds: 6));
    if (await _readKey() != value) {
      throw const StoreFailure('APIキーを保存先から読み戻せませんでした。');
    }
  }

  Future<String?> _readKey() => _secrets
      .read(AppConfig.secureApiKeyKey)
      .timeout(const Duration(seconds: 6));

  void _revokeCloud() {
    _consentRevision++;
    _remoteConsent = false;
    _invalidateCloud();
  }

  Future<void> saveApiKey(String key) {
    final value = key.trim();
    if (value.isEmpty) return deleteApiKey();
    if (value == _apiKey && keyStorageError == null) return Future.value();
    _revokeCloud();
    return _saveSettings(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        _checkWrite(
          await prefs.setBool(AppConfig.prefsRemoteConsentKey, false),
        );
        await _writeKey(value);
        _checkWrite(await prefs.remove(AppConfig.prefsApiKeyKey));
        _apiKey = value;
        keyStorageError = null;
      } catch (_) {
        keyStorageError = 'APIキーの保存を確認できませんでした。';
        throw StoreFailure(keyStorageError!);
      } finally {
        notifyListeners();
      }
    });
  }

  Future<void> deleteApiKey() {
    _revokeCloud();
    return _saveSettings(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        _checkWrite(
          await prefs.setBool(AppConfig.prefsRemoteConsentKey, false),
        );
        _checkWrite(await prefs.remove(AppConfig.prefsApiKeyKey));
        await _secrets
            .delete(AppConfig.secureApiKeyKey)
            .timeout(const Duration(seconds: 6));
        if (await _readKey() != null) {
          throw const StoreFailure('削除後もキーが残っています。');
        }
        _apiKey = '';
        keyStorageError = null;
      } catch (_) {
        keyStorageError = 'APIキーの削除を確認できませんでした。';
        throw StoreFailure(keyStorageError!);
      } finally {
        notifyListeners();
      }
    });
  }

  Future<void> saveRemoteConsent(bool consent) {
    if (!consent) _revokeCloud();
    final revision = ++_consentRevision;
    return _saveSettings(() async {
      if (consent && (!hasRemoteKey || keyStorageError != null)) {
        throw const StoreFailure('先にAPIキーを保存してください。');
      }
      final prefs = await SharedPreferences.getInstance();
      _checkWrite(
        await prefs.setBool(AppConfig.prefsRemoteConsentKey, consent),
      );
      if (_consentRevision == revision) {
        _remoteConsent = consent;
        notifyListeners();
      }
    });
  }

  Future<void> saveModel(String value) {
    final next = AppConfig.geminiModel(value);
    if (!AppConfig.validGeminiModel(next)) {
      return Future.error(const StoreFailure('モデル名の形式を確認してください。'));
    }
    return _saveSettings(() async {
      final prefs = await SharedPreferences.getInstance();
      _checkWrite(await prefs.setString(AppConfig.prefsModelKey, next));
      if (_model != next) _invalidateCloud();
      _model = next;
      notifyListeners();
    });
  }

  GeminiBackend? _remote() {
    if (!remoteConsent || !hasRemoteKey || keyStorageError != null) return null;
    final grant = _cloudRevision;
    return GeminiBackend(
      apiKey: _apiKey,
      model: _model,
      consentChanges: _cloudChanges,
      maySend: () {
        final state = WidgetsBinding.instance.lifecycleState;
        return remoteConsent &&
            _cloudRevision == grant &&
            (state == null || state == AppLifecycleState.resumed);
      },
    );
  }

  ResilientBackend backend() => ResilientBackend(
    null,
    onDevice: OnDeviceBackend(),
    remoteFactory: _remote,
  );

  @override
  void dispose() {
    _invalidateCloud();
    _cloudChanges.dispose();
    super.dispose();
  }
}
