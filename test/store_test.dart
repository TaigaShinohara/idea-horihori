import 'package:flutter_test/flutter_test.dart';
import 'package:horihori/app_config.dart';
import 'package:horihori/on_device_backend.dart';
import 'package:horihori/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('アーカイブ復元・削除', () {
    test('アーカイブすると visible から消え archived に出る', () async {
      final store = IdeaStore();
      await store.load();
      final idea = await store.addIdea('テストアイデア', '');
      expect(store.visibleIdeas.length, 1);
      expect(store.archivedIdeas, isEmpty);

      await store.archiveIdea(idea);
      expect(store.visibleIdeas, isEmpty);
      expect(store.archivedIdeas.length, 1);
      expect(store.archivedIdeas.first.id, idea.id);
    });

    test('戻すと一覧に再表示される（永続化も往復する）', () async {
      final store = IdeaStore();
      await store.load();
      final idea = await store.addIdea('戻したいアイデア', '');
      await store.archiveIdea(idea);
      await store.unarchiveIdea(idea);
      expect(store.visibleIdeas.length, 1);
      expect(store.archivedIdeas, isEmpty);

      // 再読み込みしても戻った状態が保たれる
      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.visibleIdeas.length, 1);
      expect(reloaded.archivedIdeas, isEmpty);
    });

    test('アーカイブ状態も永続化される', () async {
      final store = IdeaStore();
      await store.load();
      final idea = await store.addIdea('しまうアイデア', '');
      await store.archiveIdea(idea);

      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.visibleIdeas, isEmpty);
      expect(reloaded.archivedIdeas.length, 1);
    });

    test('完全に削除するとどこにも残らない', () async {
      final store = IdeaStore();
      await store.load();
      final a = await store.addIdea('消すアイデア', '');
      await store.addIdea('残すアイデア', '');
      await store.archiveIdea(a);
      await store.deleteIdea(a);
      expect(store.archivedIdeas, isEmpty);
      expect(store.visibleIdeas.length, 1);
      expect(store.ideas.length, 1);

      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.ideas.length, 1);
      expect(reloaded.visibleIdeas.first.title, '残すアイデア');
    });
  });

  group('hasRemoteKey', () {
    test('キー未設定なら false、保存すると true', () async {
      final store = IdeaStore(secrets: FakeSecretStore());
      await store.load();
      expect(store.hasRemoteKey, isFalse);
      await store.saveApiKey('dummy-key');
      expect(store.hasRemoteKey, isTrue);
    });
    test('secure storageへ保存し旧SharedPreferences値を削除する', () async {
      final secrets = FakeSecretStore();
      SharedPreferences.setMockInitialValues({
        AppConfig.prefsApiKeyKey: 'legacy-key',
      });
      final store = IdeaStore(secrets: secrets);
      await store.load();
      expect(store.apiKey, 'legacy-key');
      expect(secrets.values[AppConfig.secureApiKeyKey], 'legacy-key');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.prefsApiKeyKey), isNull);

      await store.saveApiKey('new-key');
      expect(secrets.values[AppConfig.secureApiKeyKey], 'new-key');

      await store.deleteApiKey();
      expect(store.apiKey, isEmpty);
      expect(secrets.values[AppConfig.secureApiKeyKey], isNull);
    });
    test('リモート同意なしではbackendにGeminiを渡さない', () async {
      final secrets = FakeSecretStore();
      final store = IdeaStore(secrets: secrets);
      await store.load();
      await store.saveApiKey('dummy-key');
      expect(store.backend().remote, isNull);
      await store.saveRemoteConsent(true);
      expect(store.backend().remote, isNotNull);
    });
  });

  group('データ消失ガード', () {
    test('壊れたJSONはバックアップキーへ退避してから空で開始する', () async {
      SharedPreferences.setMockInitialValues({
        AppConfig.prefsIdeasKey: '{broken json',
      });
      final store = IdeaStore();
      await store.load();
      expect(store.ideas, isEmpty);
      expect(store.loaded, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.prefsIdeasBackupKey), '{broken json');

      // その後の保存で新しいデータが書け、退避した原文は残る
      await store.addIdea('新しいアイデア', '');
      expect(prefs.getString(AppConfig.prefsIdeasBackupKey), '{broken json');
      final reloaded = IdeaStore();
      await reloaded.load();
      expect(reloaded.visibleIdeas.length, 1);
    });

    test('正常なJSONは退避されない', () async {
      final store = IdeaStore();
      await store.load();
      await store.addIdea('普通のアイデア', '');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.prefsIdeasBackupKey), isNull);
    });

    test('退避成功（ideasWritable == true）のときだけ復旧通知を閉じられる（R-06）', () async {
      SharedPreferences.setMockInitialValues({
        AppConfig.prefsIdeasKey: '{broken json',
      });
      final store = IdeaStore();
      await store.load();
      expect(store.ideasWritable, isTrue);
      expect(store.ideasRecoveryNotice, isNotNull);
      expect(store.dismissRecoveryNotice(), isTrue);
      expect(store.ideasRecoveryNotice, isNull);
      // 既に空なら false
      expect(store.dismissRecoveryNotice(), isFalse);
    });
  });

  group('端末AI状態キャッシュ（R-04）', () {
    test('updateOnDeviceStatusCache / clearOnDeviceStatusCache が動作する', () {
      final store = IdeaStore(secrets: FakeSecretStore());
      expect(store.cachedOnDeviceStatus, isNull);
      store.updateOnDeviceStatusCache(
        const OnDeviceCheck(OnDeviceStatus.unavailable, 'not supported'),
      );
      expect(store.cachedOnDeviceStatus?.status, OnDeviceStatus.unavailable);
      store.clearOnDeviceStatusCache();
      expect(store.cachedOnDeviceStatus, isNull);
    });
  });

  group('ChatGPT 送信同意', () {
    test('未サインインで同意をオンにすると失敗し、サインイン後のみ有効化できる', () async {
      var signedIn = false;
      final store = IdeaStore(
        secrets: FakeSecretStore(),
        chatGptChecker: () async => signedIn,
      );
      await store.load();
      expect(store.chatGptSignedIn, isFalse);
      expect(store.chatGptConsent, isFalse);
      expect(store.backend().chatGpt, isNull);

      await expectLater(
        store.saveChatGptConsent(true),
        throwsA(
          isA<StoreFailure>().having(
            (e) => e.message,
            'message',
            '先にChatGPTでサインインしてください。',
          ),
        ),
      );
      expect(store.chatGptConsent, isFalse);

      signedIn = true;
      await store.refreshChatGptStatus();
      expect(store.chatGptSignedIn, isTrue);
      expect(store.chatGptConsent, isFalse);
      expect(store.backend().chatGpt, isNull);

      await store.saveChatGptConsent(true);
      expect(store.chatGptConsent, isTrue);
      expect(store.backend().chatGpt, isNotNull);

      // 再読み込み後も同意が維持される
      final reloaded = IdeaStore(
        secrets: FakeSecretStore(),
        chatGptChecker: () async => true,
      );
      await reloaded.load();
      expect(reloaded.chatGptConsent, isTrue);
      expect(reloaded.backend().chatGpt, isNotNull);

      // サインアウト検知時は同意も false に落ちる
      signedIn = false;
      await store.refreshChatGptStatus();
      expect(store.chatGptSignedIn, isFalse);
      expect(store.chatGptConsent, isFalse);
      expect(store.backend().chatGpt, isNull);
    });
  });
}
