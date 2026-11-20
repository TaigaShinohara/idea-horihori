/// 深掘りの「今どのモードで動いているか」を表す純ロジック（K1）。
/// UI・バックエンド双方から使え、単体テストで検証できる形に寄せている。
library;

/// 深掘りの現在モード。
enum DigModeKind {
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

extension DigModeKindX on DigModeKind {
  /// バッジに出す1行。
  String get label => switch (this) {
        DigModeKind.ai => 'AIで深掘り中',
        DigModeKind.templateNoKey => '定型モード（キー未設定）',
        DigModeKind.templateFailed => '定型モード（AIにつながらなかった）',
      };

  bool get isAi => this == DigModeKind.ai;
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
