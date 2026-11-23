/// アプリ全体の定数。アプリ名・IDを変えるときはここだけ直す。
class AppConfig {
  static const String appName = 'アイデアホリホリ'; // 2026-11-20 本人が確定（旧称ホリホリ）。IDは引き継ぎのため horihori のまま
  static const String appId = 'com.taigashinohara.horihori';
  static const String version = '0.2.0';

  /// Gemini の既定モデル。設定で差し替え可能な定数として一元管理。
  static const String defaultGeminiModel = 'gemini-2.0-flash';
  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// 1セッションの質問数の目安（疲れさせない区切り）。
  static const int questionsPerSession = 5;

  // SharedPreferences keys
  static const String prefsIdeasKey = 'ideas_v1';
  static const String prefsIdeasBackupKey = 'ideas_v1_backup';
  static const String prefsApiKeyKey = 'gemini_api_key';
  static const String secureApiKeyKey = 'gemini_api_key_secure';
  static const String prefsRemoteConsentKey = 'gemini_remote_consent_v1';
  static const String prefsModelKey = 'gemini_model';
  static const String prefsKeyGuideShownKey = 'key_guide_shown_v1';

  /// 掘り方スタイル（友達／上司）の保存キー（v0.2 項目1）。
  static const String prefsDigStyleKey = 'dig_style_v1';
}
