/// 深掘りの「今どのモードで動いているか」を表す純ロジック（K1）。
/// UI・バックエンド双方から使え、単体テストで検証できる形に寄せている。
library;

/// 深掘りの現在モード。
enum DigModeKind {
  /// オンデバイスAI（Gemini Nano）が質問している（v0.3.0 PoC）。
  onDevice,

  /// Gemini（AI）が質問している。
  ai,

  /// 定型モード: APIキー未設定のため最初からローカル。
  templateNoKey,

  /// 定型モード: キーはあるが API に失敗してローカルへ切り替わった。
  templateFailed,
}

/// キー有無と直近のリモート失敗から現在モードを決める。
DigModeKind digModeKind({required bool hasKey, required bool remoteFailed}) {
  if (!hasKey) return DigModeKind.templateNoKey;
  if (remoteFailed) return DigModeKind.templateFailed;
  return DigModeKind.ai;
}

/// 掘り方のスタイル（v0.2 項目1）。名称は本人の決定どおり。
/// 既存の [DigModeKind]（AI／定型の表示用）とは別物なので混ぜない。
enum DigStyle { friend, boss }

extension DigStyleX on DigStyle {
  /// 永続化用の文字列（`dig_style_v1` に保存する値）。
  String get storageValue => switch (this) {
        DigStyle.friend => 'friend',
        DigStyle.boss => 'boss',
      };

  /// 保存文字列から復元する。未知の値・未保存は既定の friend。
  static DigStyle fromStorage(String? value) =>
      value == 'boss' ? DigStyle.boss : DigStyle.friend;

  /// UI表示名。
  String get label => switch (this) {
        DigStyle.friend => '友達モード',
        DigStyle.boss => '上司モード',
      };

  /// プロンプトへ差し込むペルソナ1文（指示書の文案どおり）。
  String get personaPrompt => switch (this) {
        DigStyle.friend =>
          '友達として並走するインタビュアー。相手の発想を広げ、肯定しながら次の一歩を一緒に考える。否定から入らない。',
        DigStyle.boss =>
          '上司として的確に指摘するレビュアー。甘い前提・曖昧な対象・根拠のない楽観を具体的に突く。ただし人格否定はせず、指摘には必ず改善の方向を添える。',
      };
}

/// 視点掘りの視点（v0.2 項目2）。セッション単位で保持する。
enum DigViewpoint { none, money, tech, user }

extension DigViewpointX on DigViewpoint {
  /// 永続化用の文字列。
  String get storageValue => switch (this) {
        DigViewpoint.none => 'none',
        DigViewpoint.money => 'money',
        DigViewpoint.tech => 'tech',
        DigViewpoint.user => 'user',
      };

  /// 保存文字列から復元する。未知の値・未保存は none。
  static DigViewpoint fromStorage(String? value) => switch (value) {
        'money' => DigViewpoint.money,
        'tech' => DigViewpoint.tech,
        'user' => DigViewpoint.user,
        _ => DigViewpoint.none,
      };

  /// チップ表示名。
  String get label => switch (this) {
        DigViewpoint.none => '通常',
        DigViewpoint.money => 'お金',
        DigViewpoint.tech => '技術',
        DigViewpoint.user => '使う人',
      };

  /// プロンプトへ追加する1文（none のときは null＝追加しない）。
  String? get promptLine => switch (this) {
        DigViewpoint.none => null,
        DigViewpoint.money => '特にお金の視点（誰が・いくら・どう払うか／続けられるか）から掘る',
        DigViewpoint.tech => '特に技術の視点（作れるか・何が難しいか・既存技術で足りるか）から掘る',
        DigViewpoint.user => '特に使う人の視点（誰の・どんな場面の・何が嬉しいか）から掘る',
      };
}

extension DigModeKindX on DigModeKind {
  /// バッジに出す1行。
  String get label => switch (this) {
        DigModeKind.onDevice => 'オンデバイスで深掘り中',
        DigModeKind.ai => 'AIで深掘り中',
        DigModeKind.templateNoKey => '定型モード（キー未設定）',
        DigModeKind.templateFailed => '定型モード（AIにつながらなかった）',
      };

  bool get isAi => this == DigModeKind.ai || this == DigModeKind.onDevice;
}

/// 定型モードにフォールバックした理由（R-04）。
/// 深掘り画面で1行開示し、必要に応じて設定画面へ案内するために使う。
enum FallbackReason {
  onDeviceNeedsDownload(
    '端末AIのモデルが未準備のため定型で進めています。',
    suggestsSettings: true,
  ),
  noRemoteKey(
    'AI設定が未完了のため定型で進めています。',
    suggestsSettings: true,
  ),
  remoteConsentOff(
    'クラウド送信がオフのため定型で進めています。',
    suggestsSettings: true,
  ),
  remoteFailed(
    'クラウドAIに接続できなかったため定型で進めています。',
    suggestsSettings: false,
  ),
  onDeviceUnavailable(
    '端末AIが利用できないため定型で進めています。',
    suggestsSettings: true,
  ),
  manualTemplate(
    '定型モードで進めています。',
    suggestsSettings: false,
  );

  const FallbackReason(this.message, {required this.suggestsSettings});
  final String message;
  final bool suggestsSettings;
}

/// 現在の設定・失敗状態から定型モードの理由を判定する純関数（R-04）。
FallbackReason? fallbackReasonFor({
  required bool isLocalSource,
  required bool hasRemoteKey,
  required bool remoteConsent,
  required bool lastRemoteFailed,
  bool onDeviceNeedsDownload = false,
  bool manualTemplate = false,
}) {
  if (!isLocalSource) return null;
  if (manualTemplate) return FallbackReason.manualTemplate;
  if (lastRemoteFailed) return FallbackReason.remoteFailed;
  if (hasRemoteKey && !remoteConsent) return FallbackReason.remoteConsentOff;
  if (onDeviceNeedsDownload) return FallbackReason.onDeviceNeedsDownload;
  if (!hasRemoteKey) return FallbackReason.noRemoteKey;
  return FallbackReason.onDeviceUnavailable;
}

/// 「1回だけ出す」ための消費フラグ（通知の出しすぎ防止）。
/// 一度 tryConsume が true を返したら、以後は reset するまで false。
class OnceFlag {
  bool _consumed = false;

  bool get consumed => _consumed;

  /// まだ消費していなければ消費して true、消費済みなら false。
  bool tryConsume() {
    if (_consumed) return false;
    _consumed = true;
    return true;
  }

  void reset() => _consumed = false;
}
