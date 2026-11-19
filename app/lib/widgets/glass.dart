import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 毛玻璃背景：柔和渐变 + 两团径向光斑，作为整套 UI 的底。
///
/// 光斑用 `RadialGradient` 而不是 `ImageFilter.blur` 画圆 —— 后者在低端机上
/// 每次重绘都要做全屏采样，而渐变是纯 CPU 绘制的，几乎零成本。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final nature = scheme.primary.toARGB32() == AppTheme.nature.seed;

    // 自然主题用米白/浅绿与深墨绿，深邃蓝保持原来的冷色调。
    final colors = dark
        ? (nature
              ? const [Color(0xFF0C1712), Color(0xFF14251C), Color(0xFF0A1410)]
              : const [Color(0xFF0B0F1A), Color(0xFF141A2C), Color(0xFF0A0E17)])
        : (nature
              ? const [Color(0xFFF1F7EF), Color(0xFFFAFBF5), Color(0xFFE7F1E6)]
              : const [
                  Color(0xFFEDF1FF),
                  Color(0xFFF8FAFF),
                  Color(0xFFE8EEFF),
                ]);

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
            ),
          ),
        ),
        Positioned(
          top: -120,
          left: -80,
          child: _Blob(
            size: 320,
            color: scheme.primary.withValues(alpha: dark ? 0.32 : 0.26),
          ),
        ),
        Positioned(
          bottom: -60,
          right: -100,
          child: _Blob(
            size: 360,
            color: scheme.tertiary.withValues(alpha: dark ? 0.26 : 0.20),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃卡片。
///
/// [blur] 为 0 时只做半透明 + 描边，不做实时模糊 —— **列表项应该这样用**。
/// 滚动列表里每个 `BackdropFilter` 都要采样背后整屏，几十个就会明显掉帧；
/// 固定元素（AppBar、底部导航、对话框）才值得开模糊。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.blur = 0,
    this.radius = 16,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double blur;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;

    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: dark ? 0.42 : 0.58),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: (dark ? Colors.white : Colors.white).withValues(
            alpha: dark ? 0.08 : 0.65,
          ),
        ),
      ),
      child: child,
    );

    final layered = blur > 0
        ? ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: content,
            ),
          )
        : content;

    if (onTap == null) return layered;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: layered,
      ),
    );
  }
}
