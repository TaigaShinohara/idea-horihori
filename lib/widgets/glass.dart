import 'dart:ui';

import 'package:flutter/material.dart';

import '../models.dart';

/// アプリのアクセント1色（掘る行為と成長バーだけに使う温かい土色）。
/// ART_DIRECTION v0.1 の「色の確定は実装初回で決める」に従いここで確定。
const Color kAccent = Color(0xFFD96C2C);
const Color kAccentDeep = Color(0xFFB34E14);

/// 主ボタンのベタ面色（K7, v0.1.2）。白文字とのコントラスト比は約5.2:1で
/// 読みやすさゲート 4.5:1 を満たす。kAccent（#D96C2C）は約3.3:1 のため
/// 成長バー・光・トナル面にだけ使う。確定は ART_DIRECTION に記録。
const Color kButtonFill = kAccentDeep;

/// ダークモード時のアクセント文字・アイコン色（v0.3.2）。
/// ダーク背景（#17181C＋読み物ガラス白16%）上でコントラスト比 5.6:1 以上を確保。
const Color kAccentOnDark = Color(0xFFF6A97A);

/// テーマに応じたアクセント文字・アイコン色（明暗とも4.5:1以上）。
Color accentTextColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? kAccentOnDark : kAccentDeep;
}

/// テーマに応じたトナルボタン背景色。
Color accentTonalFill(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return kAccent.withValues(alpha: dark ? 0.22 : 0.16);
}

/// テーマに応じたバー・バッジの控えめな背景色。
Color barTrackColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? Colors.white.withValues(alpha: 0.16)
      : Colors.black.withValues(alpha: 0.08);
}

/// 入力面の fill（R5, v0.1.2）。ART の入力ガラス（ライト84%／ダーク20%）に
/// 寄せたテーマ連動値。ダーク時に明るい文字が白面に沈まないようにする。
Color glassInputFill(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Colors.white.withValues(alpha: dark ? 0.20 : 0.84);
}

/// 全画面共通の入力ガラス装飾。
InputDecoration glassInputDecoration(
  BuildContext context, {
  String? hintText,
  String? labelText,
  Widget? suffixIcon,
}) {
  return InputDecoration(
    hintText: hintText,
    labelText: labelText,
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: glassInputFill(context),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  );
}

/// ボトムシート用の共通ガラス面。
class GlassSheetSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const GlassSheetSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: ReadingGlass(padding: padding, child: child),
      ),
    );
  }
}

/// 成長段階の表示（K6）。絵文字だけに頼らず、小さな文字ラベルを併記する。
class StageBadge extends StatelessWidget {
  final GrowthStage stage;
  final double emojiSize;
  const StageBadge({super.key, required this.stage, this.emojiSize = 20});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '成長段階は${stage.label}',
      child: ExcludeSemantics(
        // v0.2.1 ノイズ削減 N2: 見える段階ラベルは絵文字と同義なので消す。
        // 読み上げ名は上の Semantics label に残る。
        child: Text(stage.emoji, style: TextStyle(fontSize: emojiSize)),
      ),
    );
  }
}

/// Simple Glass: 飾りガラス（カード用 40%相当）。
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = Padding(padding: padding, child: child);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: dark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.75),
            ),
          ),
          child: onTap == null
              ? content
              : Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(20),
                    child: content,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Simple Glass: 読み物ガラス（企画メモ用 58%相当＋ぼかし強め）。
class ReadingGlass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const ReadingGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: dark
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.8),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 背景: 中立グレー＋ぼけた光（Simple Glass の土台）。
/// R-05: Scaffold 全体を包む構造で使用し、AppBar 背面まで一体表示する。
class GlassBackground extends StatelessWidget {
  final Widget child;
  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: dark ? const Color(0xFF17181C) : const Color(0xFFF2F0EC),
        ),
        Positioned(
          top: -90,
          right: -70,
          child: _glow(kAccent.withValues(alpha: dark ? 0.18 : 0.22)),
        ),
        Positioned(
          bottom: -110,
          left: -80,
          child: _glow(
            const Color(0xFF7FB069).withValues(alpha: dark ? 0.14 : 0.18),
          ),
        ),
        child,
      ],
    );
  }

  Widget _glow(Color color) => IgnorePointer(
        child: Container(
          width: 340,
          height: 340,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      );
}

/// 成長バー（アイコン＋細いバーだけ。％は出さない）。
///
/// K6: [stage] を渡すと段階名と成長度を Semantics で読み上げ可能にする。
/// K2: [animate] が true の時だけ 0 から現在値まで伸びるアニメーションを
/// 付ける（メモ完成の瞬間専用。常時は静止させ、装飾過剰にしない）。
/// S-01: OS の「アニメーションを減らす」設定を尊重する。
class GrowthBar extends StatelessWidget {
  final double value;
  final GrowthStage? stage;
  final bool animate;
  const GrowthBar({
    super.key,
    required this.value,
    this.stage,
    this.animate = false,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final trackColor = barTrackColor(context);
    final Widget bar;
    if (animate && !reduceMotion) {
      bar = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: v),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, animatedValue, _) => _bar(animatedValue, trackColor),
      );
    } else {
      bar = _bar(v, trackColor);
    }
    return Semantics(
      container: true,
      label: stage != null
          ? growthSemanticsLabel(stage!, v)
          : '成長度は${(v * 100).round()}パーセント',
      child: ExcludeSemantics(child: bar),
    );
  }

  Widget _bar(double v, Color trackColor) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: v,
        minHeight: 6,
        backgroundColor: trackColor,
        valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
      ),
    );
  }
}
