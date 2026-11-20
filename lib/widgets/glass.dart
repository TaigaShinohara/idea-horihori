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

/// 入力面の fill（R5, v0.1.2）。ART の入力ガラス（ライト84%／ダーク20%）に
/// 寄せたテーマ連動値。ダーク時に明るい文字が白面に沈まないようにする。
Color glassInputFill(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Colors.white.withValues(alpha: dark ? 0.20 : 0.84);
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(stage.emoji, style: TextStyle(fontSize: emojiSize)),
            const SizedBox(width: 5),
            Text(
              stage.label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: kAccentDeep,
              ),
            ),
          ],
        ),
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
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
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
          child: child,
        ),
      ),
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: card,
    );
  }
}

/// Simple Glass: 読み物ガラス（企画メモ用 58%相当＋ぼかし強め）。
class ReadingGlass extends StatelessWidget {
  final Widget child;
  const ReadingGlass({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.all(18),
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
class GlassBackground extends StatelessWidget {
  final Widget child;
  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Container(color: dark ? const Color(0xFF17181C) : const Color(0xFFF2F0EC)),
        Positioned(
          top: -80,
          right: -60,
          child: _glow(kAccent.withValues(alpha: dark ? 0.25 : 0.35)),
        ),
        Positioned(
          bottom: -100,
          left: -70,
          child: _glow(const Color(0xFF7FB069).withValues(alpha: dark ? 0.18 : 0.28)),
        ),
        child,
      ],
    );
  }

  Widget _glow(Color color) => Container(
        width: 240,
        height: 240,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color, blurRadius: 90, spreadRadius: 30)],
        ),
      );
}

/// 成長バー（アイコン＋細いバーだけ。％は出さない）。
///
/// K6: [stage] を渡すと段階名と成長度を Semantics で読み上げ可能にする。
/// K2: [animate] が true の時だけ 0 から現在値まで伸びるアニメーションを
/// 付ける（メモ完成の瞬間専用。常時は静止させ、装飾過剰にしない）。
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
    final Widget bar;
    if (animate) {
      bar = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: v),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, animatedValue, _) => _bar(animatedValue),
      );
    } else {
      bar = _bar(v);
    }
    return Semantics(
      container: true,
      label: stage != null
          ? growthSemanticsLabel(stage!, v)
          : '成長度は${(v * 100).round()}パーセント',
      child: ExcludeSemantics(child: bar),
    );
  }

  Widget _bar(double v) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: v,
        minHeight: 6,
        backgroundColor: Colors.black.withValues(alpha: 0.08),
        valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
      ),
    );
  }
}
