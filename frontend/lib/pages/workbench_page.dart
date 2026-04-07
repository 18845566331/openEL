// UI components from Uiverse.io, MIT License
// Based on open source components (Flutter, OpenCV, FastAPI, ONNX Runtime). MIT/Apache License.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'dart:convert'; // For JSON
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop_drop/desktop_drop.dart';

import '../app_theme.dart';
import '../models/detection_models.dart';
import '../services/branding_store.dart';
import '../services/detection_api_service.dart';
import '../widgets/project_info_panel.dart';
import 'ai_model_page.dart';
import 'dynamic_report_preview_page.dart';
import 'native_word_editor_page.dart';
import 'dynamic_report_preview_page.dart';

// ─── 标注框数据模型 ───
class AnnotationBox {
  Rect rect; // 归一化坐标 (0~1)
  List<Offset>? quad; // 归一化四边形坐标 (0~1)，顺序为 tl, tr, br, bl (或任意顺时角)
  String className;
  double score;
  bool isManual;
  bool selected;
  String? cropPath;

  AnnotationBox({
    required this.rect,
    this.quad,
    this.className = '隐裂',
    this.score = 1.0,
    this.isManual = false,
    this.selected = false,
    this.cropPath,
  });

  AnnotationBox copyWith({Rect? rect, List<Offset>? quad, String? className, double? score, bool? isManual, bool? selected, String? cropPath}) {
    return AnnotationBox(
      rect: rect ?? this.rect,
      quad: quad ?? this.quad,
      className: className ?? this.className,
      score: score ?? this.score,
      isManual: isManual ?? this.isManual,
      selected: selected ?? this.selected,
      cropPath: cropPath ?? this.cropPath,
    );
  }
}

// ─── 导航按钮（CSS radio-input 风格：黑底圆角，渐变浮雕，激活发光）───
// 对应 CSS: .label { background: linear-gradient(to bottom, #494949, #9c9c9c); box-shadow: inset... }
// 激活: box-shadow: 0px -2px 27px 0.5px rgba(25,25,25,1.905); background: gradient(#bbb7a, #6e6e6e93)
class _NavButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final int index; // 0~4，用于决定激活发光颜色
  final VoidCallback onTap;
  final double height; // 响应式高度
  const _NavButton({required this.icon, required this.label, required this.active, required this.index, required this.onTap, this.height = 72});
  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  bool _pressing = false;

  // 每个按钮对应不同的激活发光颜色（对应 CSS .html/.css/.js/.view）
  static const _glowColors = [
    Color(0xFF60A5FA), // 检测工作台 - 蓝
    Color(0xFF34D399), // 参数设置 - 绿
    Color(0xFFFBBF24), // 项目信息 - 黄
    Color(0xFFA78BFA), // 我的 - 紫
    Color(0xFF7DD3FC), // 帮助 - 青
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 80));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final glow = _glowColors[widget.index % _glowColors.length];
    final active = widget.active;
    final h = widget.height;
    final iconSz = (h * 0.30).clamp(18.0, 28.0);
    final fontSz = (h * 0.13).clamp(8.0, 12.0);

    return GestureDetector(
      onTapDown: (_) { _ctrl.forward(); setState(() => _pressing = true); },
      onTapUp: (_) { _ctrl.reverse(); setState(() => _pressing = false); widget.onTap(); },
      onTapCancel: () { _ctrl.reverse(); setState(() => _pressing = false); },
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) => Transform.scale(
          scale: 1.0 - 0.06 * _ctrl.value,
          child: child,
        ),
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          border: active
              ? Border.all(color: glow.withValues(alpha: 0.35), width: 1.2)
              : Border.all(color: Colors.white.withValues(alpha: 0.10), width: 1.0),
          // 激活：深色内凹；默认：深灰浮雕；按下：瞬间内凹
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0A0F18),
                    const Color(0xFF111827),
                  ],
                )
              : _pressing
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1A1F2A), Color(0xFF252D3A)],
                    )
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF2C3240), Color(0xFF3A4255)],
                    ),
          boxShadow: active
              ? [
                  // 激活：内凹阴影 + 彩色发光
                  BoxShadow(color: Colors.black.withValues(alpha: 0.80), blurRadius: 8, spreadRadius: 2, offset: const Offset(0, 3)),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.60), blurRadius: 4, spreadRadius: 1, offset: const Offset(2, 2)),
                  BoxShadow(color: glow.withValues(alpha: 0.45), blurRadius: 18, spreadRadius: 1),
                  BoxShadow(color: glow.withValues(alpha: 0.20), blurRadius: 36, spreadRadius: 3),
                ]
              : _pressing
                  ? [
                      // 按下瞬间：强内凹
                      BoxShadow(color: Colors.black.withValues(alpha: 0.70), blurRadius: 6, spreadRadius: 2, offset: const Offset(0, 3)),
                      BoxShadow(color: Colors.black.withValues(alpha: 0.50), blurRadius: 3, spreadRadius: 1, offset: const Offset(2, 2)),
                    ]
                  : [
                      // 默认：轻微外凸
                      BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 6, spreadRadius: 0, offset: const Offset(0, 4)),
                      BoxShadow(color: Colors.white.withValues(alpha: 0.06), blurRadius: 2, offset: const Offset(0, -1)),
                    ],
        ),
        child: Stack(alignment: Alignment.center, children: [
          // 激活时：彩色发光叠层
          if (active)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      glow.withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(
              widget.icon,
              size: iconSz,
              color: active ? Colors.white : Colors.white.withValues(alpha: 0.45),
              shadows: active
                  ? [
                      Shadow(color: glow, blurRadius: 10),
                      Shadow(color: glow.withValues(alpha: 0.4), blurRadius: 22),
                    ]
                  : [Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 2, offset: const Offset(1, 1))],
            ),
            SizedBox(height: (h * 0.06).clamp(3.0, 6.0)),
            Text(
              widget.label.length > 4 ? widget.label.substring(0, 4) : widget.label,
              style: TextStyle(
                fontSize: fontSz,
                fontWeight: FontWeight.w700,
                color: active ? glow : Colors.white.withValues(alpha: 0.40),
                shadows: active
                    ? [Shadow(color: glow, blurRadius: 8), Shadow(color: glow.withValues(alpha: 0.4), blurRadius: 18)]
                    : [Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 2, offset: const Offset(1, 1))],
              ),
            ),
          ]),
        ]),
      ),
        ),
    );
  }
}

// ─── NeuSpinner：加减按钮 + 直接输入 + 滚轮（CSS FColombati toggle 风格）───
// 圆形凸起按钮，按下内凹阴影
class _NeuSpinner extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double step;
  final int decimals;
  final ValueChanged<double> onChanged;
  const _NeuSpinner({required this.value, required this.min, required this.max, required this.step, required this.decimals, required this.onChanged});
  @override
  State<_NeuSpinner> createState() => _NeuSpinnerState();
}

class _NeuSpinnerState extends State<_NeuSpinner> {
  late TextEditingController _ctrl;
  bool _editing = false;
  bool _pressMinus = false;
  bool _pressPlus = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toStringAsFixed(widget.decimals));
  }

  @override
  void didUpdateWidget(_NeuSpinner old) {
    super.didUpdateWidget(old);
    if (!_editing && old.value != widget.value) {
      _ctrl.text = widget.value.toStringAsFixed(widget.decimals);
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _adjust(double delta) {
    final v = (widget.value + delta).clamp(widget.min, widget.max);
    final rounded = double.parse(v.toStringAsFixed(widget.decimals));
    widget.onChanged(rounded);
  }

  void _commitText() {
    final v = double.tryParse(_ctrl.text);
    if (v != null) widget.onChanged(v.clamp(widget.min, widget.max));
    setState(() => _editing = false);
  }

  // CSS toggle 按钮样式
  Widget _neuBtn(String symbol, bool pressing, VoidCallback onTap, VoidCallback onDown, VoidCallback onUp) {
    return GestureDetector(
      onTapDown: (_) { setState(() {}); onDown(); },
      onTapUp: (_) { setState(() {}); onUp(); onTap(); },
      onTapCancel: () { setState(() {}); onUp(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 26, height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFCCD0D4),
          boxShadow: pressing
              ? [
                  // CSS input:active ~ .button（按下内凹）
                  BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 4), spreadRadius: -1),
                  BoxShadow(color: Colors.white.withValues(alpha: 0.25), blurRadius: 6, offset: const Offset(0, -2), spreadRadius: 0),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 3)),
                  BoxShadow(color: Colors.white.withValues(alpha: 0.15), blurRadius: 4, spreadRadius: 0),
                ]
              : [
                  // CSS .toggle .button 默认（减弱白色光晕）
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4), spreadRadius: -2),
                  BoxShadow(color: Colors.white.withValues(alpha: 0.15), blurRadius: 4, offset: const Offset(0, -2), spreadRadius: -1),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 2, offset: const Offset(0, -1), spreadRadius: -1),
                  BoxShadow(color: Colors.white.withValues(alpha: 0.20), blurRadius: 3, spreadRadius: 0),
                ],
        ),
        child: Center(
          child: Text(
            symbol,
            style: TextStyle(
              fontSize: pressing ? 13 : 14,
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: pressing ? 0.45 : 0.40),
              shadows: [Shadow(color: Colors.white.withValues(alpha: 0.24), blurRadius: 1.5, offset: const Offset(1, 1))],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          _adjust(e.scrollDelta.dy < 0 ? widget.step : -widget.step);
        }
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _neuBtn('−', _pressMinus, () => _adjust(-widget.step),
            () => setState(() => _pressMinus = true),
            () => setState(() => _pressMinus = false)),
        const SizedBox(width: 4),
        SizedBox(
          width: 44,
          height: 26,
          child: TextField(
            controller: _ctrl,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 11, fontWeight: FontWeight.w600),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              filled: true,
              fillColor: const Color(0xFF0D1F33),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF7DD3FC), width: 1),
              ),
            ),
            onTap: () => setState(() => _editing = true),
            onSubmitted: (_) => _commitText(),
            onEditingComplete: _commitText,
          ),
        ),
        const SizedBox(width: 4),
        _neuBtn('+', _pressPlus, () => _adjust(widget.step),
            () => setState(() => _pressPlus = true),
            () => setState(() => _pressPlus = false)),
      ]),
    );
  }
}

// ─── Flip-Switch 模式选择器（严格还原 uiverse.io pharmacist-sabot CSS 风格）───
// CSS 关键特征：
//   - 两卡片各 110×120px，毛玻璃背景 + 半透明白色边框
//   - 滑块：translateX(0→100%) + rotateY(0→180deg)，中间 scale(1.05) 弹性
//   - 激活文字：白色 + 青色(#64ffda) text-shadow 发光
//   - 激活底部：30px 宽 #64ffda 横线，glow 脉冲动画
//   - 图标：悬停上移 3px + 亮度提升
// ─── 终端闪烁光标 ───
class _TerminalCursor extends StatefulWidget {
  @override
  State<_TerminalCursor> createState() => _TerminalCursorState();
}

class _TerminalCursorState extends State<_TerminalCursor> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 530))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 7, height: 13,
        color: Color.fromRGBO(0, 255, 0, _ctrl.value > 0.5 ? 0.8 : 0.0),
      ),
    );
  }
}

class _FlipModeSwitch extends StatefulWidget {
  final String value; // 'defect' | 'segment'
  final ValueChanged<String> onChanged;
  const _FlipModeSwitch({required this.value, required this.onChanged});
  @override
  State<_FlipModeSwitch> createState() => _FlipModeSwitchState();
}

class _FlipModeSwitchState extends State<_FlipModeSwitch> {
  static const _cyan = Color(0xFF64FFDA);

  double _cardH(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return (h * 0.072).clamp(54.0, 76.0);
  }

  @override
  Widget build(BuildContext context) {
    final isDefect = widget.value == 'defect';
    final isSegment = widget.value == 'segment';
    // isVideo isn't really sticky mode but just action, but let's treat it cleanly
    return Row(children: [
      Expanded(child: _modeCard(
        icon: Icons.search_rounded,
        label: '缺陷检测',
        subText: 'DEFECT',
        badgeText: 'AI',
        isActive: isDefect,
        onTap: () => widget.onChanged('defect'),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(22), topRight: Radius.circular(10),
          bottomLeft: Radius.circular(22), bottomRight: Radius.circular(10),
        ),
      )),
      const SizedBox(width: 5),
      Expanded(child: _modeCard(
        icon: Icons.auto_awesome_mosaic_outlined,
        label: '图片分割',
        subText: 'SEG',
        badgeText: 'SEG',
        isActive: isSegment,
        onTap: () => widget.onChanged('segment'),
        borderRadius: BorderRadius.circular(10),
      )),
      const SizedBox(width: 5),
      Expanded(child: _modeCard(
        icon: Icons.videocam_outlined,
        label: '视频抽帧',
        subText: 'VIDEO',
        badgeText: 'MOT',
        isActive: false,  // It acts like an action button
        onTap: () => widget.onChanged('video'),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(10), topRight: Radius.circular(22),
          bottomLeft: Radius.circular(10), bottomRight: Radius.circular(22),
        ),
      )),
    ]);
  }

  Widget _modeCard({
    required IconData icon,
    required String label,
    required String subText,
    required String badgeText,
    required bool isActive,
    required VoidCallback onTap,
    required BorderRadius borderRadius,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        height: _cardH(context),
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: isActive
              ? const LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFF2A3A4E), Color(0xFF1E2D40), Color(0xFF182636)],
                )
              : const LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFF141E2C), Color(0xFF101A26)],
                ),
          border: Border.all(
            color: isActive ? _cyan.withValues(alpha: 0.35) : const Color(0xFF1E3048),
            width: isActive ? 1.2 : 0.8,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(color: _cyan.withValues(alpha: 0.12), blurRadius: 16, spreadRadius: 1),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4)),
                ]
              : [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Stack(children: [
          // badge
          Positioned(
            top: 6, right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isActive ? _cyan.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isActive ? _cyan.withValues(alpha: 0.45) : Colors.white.withValues(alpha: 0.10),
                  width: 0.8,
                ),
              ),
              child: Text(badgeText, style: TextStyle(
                fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 1.0,
                color: isActive ? _cyan : Colors.white.withValues(alpha: 0.30),
              )),
            ),
          ),
          // content
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: (_cardH(context) * 0.30).clamp(18.0, 26.0),
              color: isActive ? Colors.white.withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.40),
              shadows: isActive ? [Shadow(color: _cyan.withValues(alpha: 0.5), blurRadius: 10)] : null,
            ),
            SizedBox(height: (_cardH(context) * 0.05).clamp(3.0, 6.0)),
            Text(label, style: TextStyle(
              fontSize: (_cardH(context) * 0.19).clamp(11.0, 15.0), fontWeight: FontWeight.w700, letterSpacing: 0.3,
              color: isActive ? Colors.white.withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.40),
            )),
            const SizedBox(height: 2),
            Text(subText, style: TextStyle(
              fontSize: (_cardH(context) * 0.12).clamp(7.0, 10.0), fontWeight: FontWeight.w700, letterSpacing: 1.6,
              color: isActive ? _cyan.withValues(alpha: 0.70) : Colors.white.withValues(alpha: 0.20),
            )),
          ])),
          // active bottom glow line
          if (isActive)
            Positioned(
              bottom: 6, left: 0, right: 0,
              child: Center(child: Container(
                width: 30, height: 2,
                decoration: BoxDecoration(
                  color: _cyan,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [
                    BoxShadow(color: _cyan, blurRadius: 8),
                    BoxShadow(color: _cyan.withValues(alpha: 0.5), blurRadius: 16),
                  ],
                ),
              )),
            ),
        ]),
      ),
    );
  }
}

// ─── 批量检测进度面板（仿 uiverse.io SelfMadeSystem 风格）───
// 外圈白色发光弧线 + 深色内卡 + 大号百分比 + 分段进度条
class _BatchProgressCard extends StatefulWidget {
  final bool working;
  final int current;
  final int total;
  final int ngCount;
  final int okCount;
  final DateTime? startTime;
  final int processedCount;

  const _BatchProgressCard({
    required this.working,
    required this.current,
    required this.total,
    required this.ngCount,
    required this.okCount,
    required this.startTime,
    this.processedCount = 0,
  });

  @override
  State<_BatchProgressCard> createState() => _BatchProgressCardState();
}

class _BatchProgressCardState extends State<_BatchProgressCard>
    with TickerProviderStateMixin {
  // 外圈弧线描边动画
  late AnimationController _arcCtrl;
  late Animation<double> _arcAnim;
  // 进度条流光
  late AnimationController _shimCtrl;
  // 时间刷新
  late AnimationController _tickCtrl;

  @override
  void initState() {
    super.initState();
    _arcCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 24))
      ..repeat();
    _arcAnim = _arcCtrl;
    _shimCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
    _tickCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
  }

  @override
  void dispose() {
    _arcCtrl.dispose();
    _shimCtrl.dispose();
    _tickCtrl.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_arcAnim, _shimCtrl, _tickCtrl]),
      builder: (_, __) {
        final pct = widget.total > 0 ? widget.current / widget.total : 0.0;
        final elapsed = widget.startTime != null
            ? DateTime.now().difference(widget.startTime!)
            : Duration.zero;
        final remaining = widget.total - widget.current;
        final eta = (widget.working && widget.processedCount > 0 && remaining > 0)
            ? Duration(
                milliseconds: (elapsed.inMilliseconds / widget.processedCount *
                        remaining)
                    .round())
            : null;
        final idle = !widget.working && widget.total == 0;
        final pctStr = idle ? '--' : '${(pct * 100).toStringAsFixed(0)}%';

        return SizedBox(
          // 外圈弧线需要溢出空间
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CustomPaint(
              painter: _ArcRingPainter(
                progress: _arcCtrl.value,
                active: widget.working,
                fillPct: pct,
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: const Color(0xFF0B1A2D),
                    border: Border.all(
                      color: const Color(0xFF0B2A4A),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.50), blurRadius: 8, offset: const Offset(0, 4)),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // ── 大号百分比 ──
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(
                      pctStr,
                      style: TextStyle(
                        color: idle ? Colors.white.withValues(alpha: 0.25) : const Color(0xFFCCCCCC),
                        fontSize: (MediaQuery.of(context).size.height * 0.042).clamp(28.0, 48.0),
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        shadows: widget.working
                            ? [Shadow(color: Colors.white.withValues(alpha: 0.15), blurRadius: 12)]
                            : [],
                      ),
                    ),
                    const Spacer(),
                    // 状态指示点
                    Container(
                      width: 8, height: 8,
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.working
                            ? const Color(0xFF3EEAA0)
                            : Colors.white.withValues(alpha: 0.20),
                        boxShadow: widget.working
                            ? [BoxShadow(color: const Color(0xFF3EEAA0), blurRadius: 8, spreadRadius: 1)]
                            : [],
                      ),
                    ),
                  ]),

                  const SizedBox(height: 4),

                  // ── 检测状态行 ──
                  Row(children: [
                    Icon(
                      widget.working ? Icons.bolt : Icons.hourglass_empty_rounded,
                      size: 14,
                      color: widget.working ? const Color(0xFF3EEAA0) : Colors.white.withValues(alpha: 0.30),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      widget.working
                          ? '${widget.current} / ${widget.total}  DETECTING'
                          : (widget.total > 0 ? 'COMPLETED' : 'STANDBY'),
                      style: TextStyle(
                        color: widget.working
                            ? Colors.white.withValues(alpha: 0.75)
                            : Colors.white.withValues(alpha: 0.30),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ]),

                  const SizedBox(height: 3),

                  // ── NG/OK 行 ──
                  Row(children: [
                    Icon(Icons.grid_view_rounded, size: 13, color: Colors.white.withValues(alpha: 0.35)),
                    const SizedBox(width: 5),
                    Text(
                      idle
                          ? '--  NG / OK'
                          : '${widget.ngCount}  NG    ${widget.okCount}  OK',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.50),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ]),

                  const SizedBox(height: 3),

                  // ── 时间行 ──
                  Row(children: [
                    Icon(Icons.refresh_rounded, size: 13, color: Colors.white.withValues(alpha: 0.35)),
                    const SizedBox(width: 5),
                    Text(
                      idle
                          ? '--:--  /  --:--'
                          : '${_fmt(elapsed)}  /  ${eta != null ? _fmt(eta) : "--:--"}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.50),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ]),

                  const SizedBox(height: 8),

                  // ── 分段进度条 ──
                  _SegmentBar(
                    pct: pct,
                    shimOffset: _shimCtrl.value,
                    active: widget.working,
                  ),
                ]),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

// 外圈发光弧线 Painter（仿 CSS .outer path — 圆角矩形描边 + 发光）
class _ArcRingPainter extends CustomPainter {
  final double progress; // 0→1 旋转进度（控制 dash offset）
  final bool active;
  final double fillPct;

  _ArcRingPainter({required this.progress, required this.active, required this.fillPct});

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 4.0; // 外圈与内卡间距
    const radius = 26.0;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, pad, size.width - pad * 2, size.height - pad * 2),
      const Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    // 1) 极淡背景轨道
    final trackPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath(path, trackPaint);

    // 计算路径总长度
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final totalLen = metrics.first.length;

    // 2) 主发光弧线（约 78% 可见，22% 间隙，旋转偏移）
    final visibleLen = totalLen * 0.78;
    final gapLen = totalLen - visibleLen;
    final offset = progress * totalLen;

    // 提取可见段路径
    final visPath = _extractDash(metrics.first, offset, visibleLen, totalLen);

    if (visPath != null) {
      // 模糊发光层
      final glowPaint = Paint()
        ..color = Colors.white.withValues(alpha: active ? 0.25 : 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawPath(visPath, glowPaint);

      // 主弧线
      final arcPaint = Paint()
        ..color = Colors.white.withValues(alpha: active ? 0.90 : 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(visPath, arcPaint);
    }

    // 3) 进度填充弧（绿色，从顶部中心开始）
    if (fillPct > 0) {
      final fillLen = totalLen * fillPct;
      final fillPath = _extractDash(metrics.first, 0, fillLen, totalLen);
      if (fillPath != null) {
        final fillGlow = Paint()
          ..color = const Color(0xFF3EEAA0).withValues(alpha: 0.40)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
        canvas.drawPath(fillPath, fillGlow);

        final fillPaint = Paint()
          ..color = const Color(0xFF3EEAA0).withValues(alpha: 0.80)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(fillPath, fillPaint);
      }
    }
  }

  /// 从 PathMetric 中提取 [start, start+length] 段（支持环绕）
  Path? _extractDash(ui.PathMetric metric, double start, double length, double total) {
    final path = Path();
    var remaining = length;
    var pos = start % total;

    while (remaining > 0) {
      final segLen = math.min(remaining, total - pos);
      final seg = metric.extractPath(pos, pos + segLen);
      path.addPath(seg, Offset.zero);
      remaining -= segLen;
      pos = 0; // 环绕到起点
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _ArcRingPainter old) =>
      old.progress != progress || old.active != active || old.fillPct != fillPct;
}

// 分段进度条（仿 CSS .bar clip-path 6段）
class _SegmentBar extends StatelessWidget {
  final double pct;
  final double shimOffset;
  final bool active;

  const _SegmentBar({required this.pct, required this.shimOffset, required this.active});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, bc) {
      final totalW = bc.maxWidth;
      const segCount = 6;
      const gap = 4.0;
      final segW = (totalW - gap * (segCount - 1)) / segCount;
      final fillSegs = (pct * segCount).clamp(0.0, segCount.toDouble());

      return Row(
        children: List.generate(segCount, (i) {
          final segFill = (fillSegs - i).clamp(0.0, 1.0);
          final isActive = segFill > 0;
          return Padding(
            padding: EdgeInsets.only(right: i < segCount - 1 ? gap : 0),
            child: Container(
              width: segW,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: isActive
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Stack(children: [
                        // 底色
                        Container(
                          width: segW * segFill,
                          color: const Color(0xFF3EEAA0).withValues(alpha: 0.55),
                        ),
                        // 流光
                        if (active)
                          Positioned.fill(
                            child: FractionallySizedBox(
                              widthFactor: segFill,
                              alignment: Alignment.centerLeft,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment(shimOffset * 2 - 1, 0),
                                    end: Alignment(shimOffset * 2 + 0.5, 0),
                                    colors: [
                                      Colors.transparent,
                                      const Color(0xFF3EEAA0).withValues(alpha: 0.60),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ]),
                    )
                  : null,
            ),
          );
        }),
      );
    });
  }
}

// ─── Neumorphism 物理感 Toggle 按钮（复现 uiverse.io FColombati 风格）───
class _NeuToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final double size;
  final Color baseColor;

  const _NeuToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 56,
    this.baseColor = const Color(0xFF1E293B),
  });

  @override
  State<_NeuToggle> createState() => _NeuToggleState();
}

class _NeuToggleState extends State<_NeuToggle> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pressAnim;
  bool _pressing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _pressAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(_) { _ctrl.forward(); setState(() => _pressing = true); }
  void _onTapUp(_) { _ctrl.reverse(); setState(() => _pressing = false); }
  void _onTapCancel() { _ctrl.reverse(); setState(() => _pressing = false); }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final base = widget.baseColor;
    final isOn = widget.value;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: () => widget.onChanged(!isOn),
      child: AnimatedBuilder(
        animation: _pressAnim,
        builder: (_, __) => Transform.scale(
          scale: _pressAnim.value,
          child: Container(
            width: s, height: s,
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(s * 0.22),
              boxShadow: _pressing || isOn ? [
                // 按下/激活：内凹阴影
                BoxShadow(color: Colors.black.withValues(alpha: 0.45), offset: const Offset(0, 4), blurRadius: 8, spreadRadius: 1),
                BoxShadow(color: Colors.white.withValues(alpha: 0.06), offset: const Offset(0, -2), blurRadius: 4),
                BoxShadow(color: Colors.black.withValues(alpha: 0.35), offset: const Offset(3, 3), blurRadius: 6, spreadRadius: -1),
              ] : [
                // 默认：外凸阴影
                BoxShadow(color: Colors.black.withValues(alpha: 0.55), offset: const Offset(4, 8), blurRadius: 14, spreadRadius: -2),
                BoxShadow(color: Colors.white.withValues(alpha: 0.07), offset: const Offset(-3, -4), blurRadius: 8),
                BoxShadow(color: Colors.black.withValues(alpha: 0.25), offset: const Offset(0, 2), blurRadius: 4),
              ],
            ),
            child: Stack(alignment: Alignment.center, children: [
              // 光晕
              Container(
                width: s * 0.72, height: s * 0.72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.04), blurRadius: s * 0.25, spreadRadius: s * 0.1)],
                ),
              ),
              // 按钮圆盘
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                width: s * 0.68, height: s * 0.68,
                decoration: BoxDecoration(
                  color: base,
                  shape: BoxShape.circle,
                  boxShadow: _pressing ? [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(0, 4), blurRadius: 10, spreadRadius: 2),
                    BoxShadow(color: Colors.white.withValues(alpha: 0.12), offset: const Offset(0, -3), blurRadius: 6),
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), offset: const Offset(0, 6), blurRadius: 18),
                  ] : [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(0, 8), blurRadius: 16, spreadRadius: -2),
                    BoxShadow(color: Colors.white.withValues(alpha: 0.1), offset: const Offset(0, -4), blurRadius: 8),
                    BoxShadow(color: Colors.black.withValues(alpha: 0.2), offset: const Offset(0, -6), blurRadius: 10),
                    BoxShadow(color: Colors.white.withValues(alpha: 0.15), offset: const Offset(0, 0), blurRadius: 3, spreadRadius: 1),
                  ],
                ),
              ),
              // 标签
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                style: TextStyle(
                  fontSize: _pressing ? s * 0.28 : s * 0.32,
                  fontWeight: FontWeight.w700,
                  color: isOn
                    ? const Color(0xFF22D3EE).withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.35),
                  shadows: [
                    Shadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(1, 1), blurRadius: 3),
                    Shadow(color: Colors.white.withValues(alpha: 0.15), offset: const Offset(1, 1), blurRadius: 4),
                  ],
                ),
                child: Text(isOn ? '●' : '○'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── 标注框绘制器 ───
class _BoxPainter extends CustomPainter {
  final List<AnnotationBox> boxes;
  final Rect? drawingRect;
  final int? hoveredIndex;
  final double imageAspectRatio;
  final double strokeWidth;
  final double labelFontSize;
  final bool showBoxes;
  final bool showLabels;
  final bool showConfidence;

  static const _defaultColors = <Color>[
    Color(0xFFF87171), Color(0xFFFBBF24), Color(0xFF60A5FA), Color(0xFF34D399),
    Color(0xFFA78BFA), Color(0xFFFB923C), Color(0xFF22D3EE), Color(0xFFF472B6),
  ];

  final List<Offset> polygonPoints; // 正在绘制的多边形点

  _BoxPainter({required this.boxes, this.drawingRect, this.hoveredIndex, this.imageAspectRatio = 0, this.strokeWidth = 1.8, this.labelFontSize = 11, this.showBoxes = true, this.showLabels = true, this.showConfidence = true, this.polygonPoints = const []});

  Color _colorForClass(String className) {
    // 根据类名哈希分配颜色
    final idx = className.hashCode.abs() % _defaultColors.length;
    return _defaultColors[idx];
  }

  /// 计算 BoxFit.contain 模式下图像在容器中的实际区域
  Rect _imageRect(Size containerSize) {
    if (imageAspectRatio <= 0) {
      return Rect.fromLTWH(0, 0, containerSize.width, containerSize.height);
    }
    final containerAR = containerSize.width / containerSize.height;
    double imgW, imgH;
    if (imageAspectRatio > containerAR) {
      // 图像更宽，左右撑满，上下留黑边
      imgW = containerSize.width;
      imgH = containerSize.width / imageAspectRatio;
    } else {
      // 图像更高，上下撑满，左右留黑边
      imgH = containerSize.height;
      imgW = containerSize.height * imageAspectRatio;
    }
    final offsetX = (containerSize.width - imgW) / 2;
    final offsetY = (containerSize.height - imgH) / 2;
    return Rect.fromLTWH(offsetX, offsetY, imgW, imgH);
  }

  /// 将归一化坐标 (0~1) 映射到容器中图像的实际像素位置
  Rect _mapNormToCanvas(Rect norm, Size containerSize) {
    final ir = _imageRect(containerSize);
    return Rect.fromLTRB(
      ir.left + norm.left * ir.width,
      ir.top + norm.top * ir.height,
      ir.left + norm.right * ir.width,
      ir.top + norm.bottom * ir.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!showBoxes) return; // 不显示标注框时直接返回
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      final color = _colorForClass(b.className);
      final r = _mapNormToCanvas(b.rect, size);

      if (b.quad != null && b.quad!.length >= 3) {
        final path = Path();
        final ir = _imageRect(size);
        for (var j = 0; j < b.quad!.length; j++) {
          final px = ir.left + b.quad![j].dx * ir.width;
          final py = ir.top + b.quad![j].dy * ir.height;
          if (j == 0) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        path.close();

        // 多边形填充
        canvas.drawPath(path, Paint()
          ..color = color.withOpacity(b.selected ? 0.25 : 0.10)
          ..style = PaintingStyle.fill);
        // 多边形边框
        canvas.drawPath(path, Paint()
          ..color = b.selected ? Colors.white : color
          ..style = PaintingStyle.stroke
          ..strokeWidth = b.selected ? strokeWidth + 0.7 : strokeWidth);
        // ★ 选中时绘制顶点手柄
        if (b.selected) {
          for (var j = 0; j < b.quad!.length; j++) {
            final px = ir.left + b.quad![j].dx * ir.width;
            final py = ir.top + b.quad![j].dy * ir.height;
            canvas.drawCircle(Offset(px, py), 5, Paint()..color = Colors.white);
            canvas.drawCircle(Offset(px, py), 5, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
          }
        }
      } else {
        // 矩形填充
        canvas.drawRect(r, Paint()..color = color.withOpacity(b.selected ? 0.25 : 0.10));
        // 矩形边框
        canvas.drawRect(r, Paint()
          ..color = b.selected ? Colors.white : color
          ..style = PaintingStyle.stroke
          ..strokeWidth = b.selected ? strokeWidth + 0.7 : strokeWidth);
        // ★ 选中时绘制 rect 四角手柄
        if (b.selected) {
          final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
          for (final c in corners) {
            canvas.drawCircle(c, 5, Paint()..color = Colors.white);
            canvas.drawCircle(c, 5, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
          }
        }
      }

      // 标签 (根据设置显示/隐藏)
      if (showLabels || showConfidence) {
        final labelParts = <String>[];
        if (showLabels) labelParts.add(b.className);
        if (showConfidence) labelParts.add('${(b.score * 100).toStringAsFixed(0)}%');
        final label = labelParts.join(' ');
        final tp = TextPainter(
          text: TextSpan(text: label, style: TextStyle(color: Colors.white, fontSize: labelFontSize, fontWeight: FontWeight.w700, background: Paint()..color = color.withOpacity(0.85))),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(r.left + 2, r.top - tp.height - 2 > 0 ? r.top - tp.height - 2 : r.top + 2));
      }
    }

    // 正在绘制的框
    if (drawingRect != null) {
      final r = _mapNormToCanvas(drawingRect!, size);
      canvas.drawRect(r, Paint()..color = const Color(0xFF22D3EE).withOpacity(0.15));
      canvas.drawRect(r, Paint()
        ..color = const Color(0xFF22D3EE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round);
    }

    // ── 绘制正在构建的多边形预览 ──
    if (polygonPoints.isNotEmpty) {
      final ir = _imageRect(size);
      final polyPaint = Paint()
        ..color = const Color(0xFF7C3AED)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      for (var j = 0; j < polygonPoints.length - 1; j++) {
        final p1 = Offset(ir.left + polygonPoints[j].dx * ir.width, ir.top + polygonPoints[j].dy * ir.height);
        final p2 = Offset(ir.left + polygonPoints[j + 1].dx * ir.width, ir.top + polygonPoints[j + 1].dy * ir.height);
        canvas.drawLine(p1, p2, polyPaint);
      }
      // 绘制顶点圆点
      for (var j = 0; j < polygonPoints.length; j++) {
        final px = ir.left + polygonPoints[j].dx * ir.width;
        final py = ir.top + polygonPoints[j].dy * ir.height;
        canvas.drawCircle(Offset(px, py), j == 0 ? 6 : 4, Paint()..color = const Color(0xFF7C3AED));
        if (j == 0) {
          // 起始点白色外圈提示可闭合
          canvas.drawCircle(Offset(px, py), 6, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}

// ─── 明暗片网格辅助线绘制器 ───
class _GridOverlayPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double imageAspectRatio;
  final List<List<Map<String, dynamic>>>? cells; // 二维数组, 每格含 grade, diff_pct
  final bool showHeatmap;
  final bool showText;
  final double edgeDisplayThresh;
  final double threshA;
  final double threshB;
  final double threshC;

  _GridOverlayPainter({
    required this.rows,
    required this.cols,
    this.imageAspectRatio = 0,
    this.cells,
    this.showHeatmap = true,
    this.showText = true,
    this.edgeDisplayThresh = 5.0,
    this.threshA = 15.0,
    this.threshB = 30.0,
    this.threshC = 50.0,
  });

  // 与 _BoxPainter 相同的坐标转换
  Rect _imageRect(Size containerSize) {
    if (imageAspectRatio <= 0) {
      return Rect.fromLTWH(0, 0, containerSize.width, containerSize.height);
    }
    final containerAR = containerSize.width / containerSize.height;
    double imgW, imgH;
    if (imageAspectRatio > containerAR) {
      imgW = containerSize.width;
      imgH = containerSize.width / imageAspectRatio;
    } else {
      imgH = containerSize.height;
      imgW = containerSize.height * imageAspectRatio;
    }
    final offsetX = (containerSize.width - imgW) / 2;
    final offsetY = (containerSize.height - imgH) / 2;
    return Rect.fromLTWH(offsetX, offsetY, imgW, imgH);
  }

  Color _gradeColor(String? grade) {
    switch (grade) {
      case 'B': return const Color(0xFFFBBF24); // 黄
      case 'C': return const Color(0xFFF97316); // 橙
      case 'D': return const Color(0xFFEF4444); // 红
      default:  return Colors.transparent;
    }
  } // A 类无色

  @override
  void paint(Canvas canvas, Size size) {
    final ir = _imageRect(size);
    final cellW = ir.width / cols;
    final cellH = ir.height / rows;

    if (cells != null) {
      for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
          if (r >= cells!.length || c >= cells![r].length) continue;
          final cell = cells![r][c];
          final grade = cell['grade'] as String?;

          // 显示灰度值与百分比
          if (showText && grade != null) {
            final diffPct = cell['diff_pct'] as num?;
            final meanVal = cell['mean'] as num?;
            
            final color = grade == 'A' ? const Color(0xFF94A3B8) : _gradeColor(grade);
            final fontSize = (cellW * 0.12).clamp(6.0, 10.0); // 调整统一字号

            final textSpan = TextSpan(
              children: [
                TextSpan(
                  text: '${meanVal?.toStringAsFixed(1) ?? "?"}\n',
                  style: TextStyle(
                    color: color.withOpacity(0.95),
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: '${diffPct?.toStringAsFixed(1) ?? "?"}%',
                  style: TextStyle(
                    color: color.withOpacity(0.7),
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );

            final textPainter = TextPainter(
              text: textSpan,
              textAlign: TextAlign.center,
              textDirection: ui.TextDirection.ltr,
            )..layout();
            final cx = ir.left + c * cellW + (cellW - textPainter.width) / 2;
            final cy = ir.top + r * cellH + (cellH - textPainter.height) / 2;
            textPainter.paint(canvas, Offset(cx, cy));
          }
        }
      }

      // 绘制相邻格子的灰度差值和百分比差值 (线框上)
      if (showText) {
        TextStyle getEdgeStyle(double pct) {
          Color c;
          if (pct <= threshA) {
            c = const Color(0xFF34D399);
          } else if (pct <= threshB) c = const Color(0xFFFBBF24);
          else if (pct <= threshC) c = const Color(0xFFF97316);
          else c = const Color(0xFFEF4444);
          
          return TextStyle(
            color: c,
            fontSize: (cellW * 0.1).clamp(6.0, 9.0),
            fontWeight: FontWeight.w700,
            background: Paint()..color = const Color(0xFF0F172A).withOpacity(0.7),
          );
        }

        // 横向边界 (左右相邻格子)
        for (int r = 0; r < rows; r++) {
          for (int c = 0; c < cols - 1; c++) {
            if (r >= cells!.length || c + 1 >= cells![r].length) continue;
            final m1 = cells![r][c]['mean'] as num?;
            final m2 = cells![r][c + 1]['mean'] as num?;
            if (m1 != null && m2 != null && m1 > 0 && m2 > 0) {
              final diff = (m1 - m2).abs();
              final pct = diff / math.max(0.1, math.min(m1, m2)) * 100;
              if (pct >= edgeDisplayThresh) {
                final tp = TextPainter(
                  text: TextSpan(text: '${diff.toStringAsFixed(1)}\n${pct.toStringAsFixed(1)}%', style: getEdgeStyle(pct)),
                  textAlign: TextAlign.center,
                  textDirection: ui.TextDirection.ltr,
                )..layout();
                final cx = ir.left + (c + 1) * cellW;
                final cy = ir.top + r * cellH + cellH / 2;
                tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
              }
            }
          }
        }

        // 纵向边界 (上下相邻格子)
        for (int r = 0; r < rows - 1; r++) {
          for (int c = 0; c < cols; c++) {
            if (r + 1 >= cells!.length || c >= cells![r].length) continue;
            final m1 = cells![r][c]['mean'] as num?;
            final m2 = cells![r + 1][c]['mean'] as num?;
            if (m1 != null && m2 != null && m1 > 0 && m2 > 0) {
              final diff = (m1 - m2).abs();
              final pct = diff / math.max(0.1, math.min(m1, m2)) * 100;
              if (pct >= edgeDisplayThresh) {
                final tp = TextPainter(
                  text: TextSpan(text: '${diff.toStringAsFixed(1)}\n${pct.toStringAsFixed(1)}%', style: getEdgeStyle(pct)),
                  textAlign: TextAlign.center,
                  textDirection: ui.TextDirection.ltr,
                )..layout();
                final cx = ir.left + c * cellW + cellW / 2;
                final cy = ir.top + (r + 1) * cellH;
                tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
              }
            }
          }
        }
      }
    }

    // 绘制网格辅助线
    final linePaint = Paint()
      ..color = const Color(0xFF7DD3FC).withOpacity(0.50)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // 横线
    for (int r = 0; r <= rows; r++) {
      final y = ir.top + r * cellH;
      canvas.drawLine(Offset(ir.left, y), Offset(ir.right, y), linePaint);
    }
    // 纵线
    for (int c = 0; c <= cols; c++) {
      final x = ir.left + c * cellW;
      canvas.drawLine(Offset(x, ir.top), Offset(x, ir.bottom), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridOverlayPainter old) => true;
}

enum AppSection {
  workbench,
  settings,
  batch,
  model,
  review,
  project,
  diagnostics,
}

class WorkbenchPage extends StatefulWidget {
  final Map<String, dynamic>? loginInfo;
  const WorkbenchPage({super.key, this.loginInfo});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  static const _nav = <(AppSection, IconData, String)>[
    (AppSection.workbench, Icons.dashboard_customize_rounded, '检测工作台'),
    (AppSection.settings, Icons.tune_rounded, '参数设置'),
    (AppSection.project, Icons.folder_copy_rounded, '项目信息'),
    (AppSection.model, Icons.model_training_rounded, 'AI建模'),
  ];

  // ─── 分辨率自适应尺寸计算 ───
  /// 屏幕尺寸分级：compact(<1400), medium(1400-1800), expanded(>1800)
  bool _isCompact(BuildContext context) => MediaQuery.of(context).size.width < 1400;
  bool _isMedium(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= 1400 && w <= 1800;
  }
  double _screenW(BuildContext context) => MediaQuery.of(context).size.width;
  double _screenH(BuildContext context) => MediaQuery.of(context).size.height;

  /// 侧边栏宽度：屏幕宽度的 ~5%，限制在 [66, 105]
  double _railWidth(BuildContext context) {
    final w = _screenW(context);
    return (w * 0.05).clamp(66.0, 105.0);
  }

  /// 左侧面板宽度：屏幕宽度的 ~15%，限制在 [180, 270]
  double _leftPanelWidth(BuildContext context) {
    final w = _screenW(context);
    return (w * 0.15).clamp(180.0, 270.0);
  }

  /// 右侧面板宽度：屏幕宽度的 ~15%，限制在 [160, 330]
  double _rightPanelWidth(BuildContext context) {
    final w = _screenW(context);
    return (w * 0.15).clamp(160.0, 330.0);
  }

  /// 滑出面板宽度：屏幕宽度的 ~24%，限制在 [300, 500]
  double _slidePanelWidth(BuildContext context) {
    final w = _screenW(context);
    return (w * 0.24).clamp(300.0, 500.0);
  }

  /// 面板间距：屏幕宽度的 ~0.6%，限制在 [6, 14]
  double _panelGap(BuildContext context) {
    final w = _screenW(context);
    return (w * 0.006).clamp(6.0, 14.0);
  }

  /// 面板内边距：根据屏幕大小自适应
  double _panelPadding(BuildContext context) {
    return _isCompact(context) ? 10.0 : 14.0;
  }

  /// 外层边距：根据屏幕大小自适应
  EdgeInsets _outerPadding(BuildContext context) {
    final compact = _isCompact(context);
    return EdgeInsets.fromLTRB(
      compact ? 8 : 14,
      compact ? 6 : 8,
      compact ? 8 : 14,
      compact ? 8 : 14,
    );
  }

  /// 按钮卡片高度（文件操作/检测按钮等）：根据屏幕高度自适应
  double _cardHeight(BuildContext context) {
    final h = _screenH(context);
    return (h * 0.065).clamp(48.0, 68.0);
  }

  /// 底部按钮卡片高度（暂停/停止）
  double _cardHeightSmall(BuildContext context) {
    final h = _screenH(context);
    return (h * 0.052).clamp(40.0, 56.0);
  }

  /// 导航栏按钮高度：根据屏幕高度自适应
  double _navBtnHeight(BuildContext context) {
    final h = _screenH(context);
    return (h * 0.075).clamp(53.0, 79.0);
  }

  /// 模式切换卡片高度
  double _modeSwitchHeight(BuildContext context) {
    final h = _screenH(context);
    return (h * 0.072).clamp(54.0, 76.0);
  }

  /// 基于屏幕宽度的全局 UI 缩放因子，以 1920 为基准
  double _sf(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w / 1920.0).clamp(0.70, 1.0);
  }

  /// 缩放值辅助方法：将设计稿像素值按屏幕比例缩放
  double _s(BuildContext context, double value) => value * _sf(context);

  final _backendCtrl = TextEditingController(text: 'http://127.0.0.1:5000');
  final _labelCtrl = TextEditingController(text: '');
  List<Map<String, dynamic>> _mapDataCache = [];  // 留空则使用服务器返回的模型自带标签
  final _modelCtrl = TextEditingController(text: 'model_el_defect.onnx');

  // 本地模型状态
  String _modelName = '';
  String? _loadedModelMode;
  String _displayName = ''; // 品牌显示名称
  String _logoUrl = ''; // 品牌 logo URL

  // ─── GPU / 系统诊断状态 ───
  Map<String, dynamic>? _gpuStatus;

  AppSection _section = AppSection.workbench;
  String? _slidePanel; // null | 'settings' | 'model' — 左侧滑出面板
  String? _defectModelPath;
  String? _segmentModelPath;
  String? _imagePath;
  String? _folderPath;
  bool _isDragging = false; // 拖拽文件悬停状态

  bool _working = false;
  bool _stopRequested = false;
  Completer<void>? _pauseCompleter;
  bool _online = false;
  // 自锁按钮状态：'single' | 'batch' | null
  String? _lockedBtn;
  String? _pressedBtn; // 当前按下的按钮ID（用于按下缩放效果）
  bool _modelReady = false;
  bool _showAnnot = false;
  bool _drawMode = false; // 是否正在绘制新框
  // ── 拖拽编辑状态 ──
  int? _dragBoxIdx;       // 正在拖拽的标注框索引
  int? _dragVertexIdx;    // 正在拖拽的顶点索引 (0=TL 1=TR 2=BR 3=BL, quad同理)
  bool _dragWholeBox = false; // 拖拽整个框
  Offset? _dragAnchor;    // 拖拽起始归一化坐标
  bool _cuda = true;
  bool _fp16 = true;
  bool _nms = true;

  double _conf = 0.55;
  double _iou = 0.45;

  // 标注框显示参数
  double _boxStrokeWidth = 1.8;
  double _labelFontSize = 11.0;
  bool _showBoxes = true;       // 是否显示标注框
  bool _showLabels = true;      // 是否显示标签名称
  bool _showConfidence = false;  // 是否显示置信度（默认关闭）

  // Excel 导出参数
  bool _rotateExportImages = false; 
  double _imgWidthCm = 10.0;  
  double _imgHeightCm = 5.0;  
  int _imgQuality = 85;  
  
  // Word 导出参数
  bool _wordRotateExportImages = false;
  double _wordImgWidthCm = 10.0;
  double _wordImgHeightCm = 5.0;
  int _wordImgQuality = 85;
  String _wordImageFilter = 'all'; // all / ng / ok — Word导出图片筛选

  // Excel导出参数
  int _excelCols = 10;             // Excel 每行图片列数

  // 持久进度条
  String? _progressMessage;
  bool _progressVisible = false;

  // 批量检测进度追踪
  int _batchCurrentIdx = 0;
  int _batchTotalCount = 0;
  DateTime? _batchStartTime;
  int _batchNgCount = 0;
  int _batchOkCount = 0;
  int _batchProcessedCount = 0;

  // 裁剪参数
  bool _autoCrop = true;
  bool _perspectiveCrop = false;
  double _cropExpandPx = 0; // 外扩像素
  int _cropQuality = 95;
  int _cropResW = 0; // 导出宽度，0=默认
  int _cropResH = 0; // 导出高度，0=默认
  String _cropSaveDir = '';

  // 明暗片辅助检测参数
  bool _cellBrightEnabled = false;   // 是否启用
  int _cellRows = 6;                 // 竖向硬片行数
  int _cellCols = 10;                // 横向硬片列数
  double _cellThresholdA = 15.0;     // 判定A类的阈值百分比
  double _cellThresholdB = 30.0;     // 判定B类的阈值百分比
  double _cellThresholdC = 50.0;     // 判定C类的阈值百分比
  double _edgeDisplayThresh = 5.0;   // 边缘差异显示下限(%)
  bool _cellHeatmap = true;          // 是否显示热力图
  bool _cellTextLabels = true;       // 是否显示数字标注
  bool _cellAnalyzing = false;       // 正在分析中
  Map<String, dynamic>? _cellBrightResult; // 后端返回的分析结果

  String _detectMode = 'defect'; // 'defect' | 'segment'
  bool _filterEdges = true;      // 图片分割模式下是否过滤边缘

  // ─── 缺陷分类等级配置 ───
  // A级: count <= a_max  B级: a_max < count <= b_max  C级: count > b_max
  List<Map<String, dynamic>> _defectGradingConfig = [
    {'name': '碎片',     'level': 1,  'a_max': 0, 'b_max': 2},
    {'name': '网状隐裂', 'level': 2,  'a_max': 0, 'b_max': 2},
    {'name': '砸伤隐裂', 'level': 3,  'a_max': 0, 'b_max': 2},
    {'name': '交叉隐裂', 'level': 4,  'a_max': 0, 'b_max': 3},
    {'name': '线状隐裂', 'level': 5,  'a_max': 1, 'b_max': 5},
    {'name': '缺角',     'level': 6,  'a_max': 1, 'b_max': 3},
    {'name': '划痕',     'level': 7,  'a_max': 1, 'b_max': 5},
    {'name': '断栅',     'level': 8,  'a_max': 3, 'b_max': 8},
    {'name': '暗片',     'level': 9,  'a_max': 1, 'b_max': 5},
    {'name': '虚焊',     'level': 10, 'a_max': 2, 'b_max': 6},
    {'name': '明暗片',   'level': 11, 'a_max': 2, 'b_max': 6},
    {'name': '黑斑',     'level': 12, 'a_max': 3, 'b_max': 8},
  ];
  // 每张图片的等级缓存 (path → 'A'/'B'/'C')
  final Map<String, String> _perImageGrades = {};

  // 项目信息字段
  final _projNameCtrl = TextEditingController();
  final _projCodeCtrl = TextEditingController();
  final _clientCtrl = TextEditingController();
  final _projAddrCtrl = TextEditingController();
  final _testUnitCtrl = TextEditingController();

  // 项目信息侧滑表单
  bool _isProjectFormOpen = false;
  final _testDateCtrl = TextEditingController();
  final _testerCtrl = TextEditingController();
  final _moduleVendorCtrl = TextEditingController();
  final _moduleModelCtrl = TextEditingController();
  final _modulePowerCtrl = TextEditingController();
  final _openVoltCtrl = TextEditingController();
  final _shortCurrCtrl = TextEditingController();
  final _moduleTypeCtrl = TextEditingController(text: '单晶硅');
  final _moduleCountCtrl = TextEditingController();

  // ─── 公告通知 ───
  List<Map<String, dynamic>> _announcements = [];
  Set<int> _readAnnouncementIds = {};
  int _lastAnnouncementTs = 0;
  Timer? _announcementTimer;
  int? _expandedAnnouncementId;

  DetectResult? _single;
  BatchSummary? _batch;

  // 每张图片的检测结果缓存 (path -> DetectResult)
  final Map<String, DetectResult> _perImageResults = {};
  // 标注框级缓存（包括手动绘制和含有 quad 的分割结果）
  final Map<String, List<AnnotationBox>> _perImageAnnotations = {};

  // 文件列表排序状态：null=不排序, 'name'=文件名, 'count'=数量, 'result'=结果
  String? _sortColumn;
  bool _sortAscending = true;

  // 标注框列表
  final List<AnnotationBox> _annotations = [];
  Offset? _drawStart;
  Rect? _drawingRect;
  String _annotClass = '缺陷';
  int? _selectedIdx;
  // 多边形绘制模式
  bool _polygonMode = false;
  final List<Offset> _polygonPoints = [];
  final TextEditingController _customClassCtrl = TextEditingController();

  /// 从标签输入框动态获取缺陷类别选项
  List<String> get _annotClassOptions {
    final labels = _labelCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (labels.isEmpty) return ['缺陷'];
    return labels;
  }

  String _getGradeForDefect(String clsName, int count) {
    if (count == 0) return 'OK';
    final Map<String, Map<String, dynamic>> configMap = {};
    for (final cfg in _defectGradingConfig) {
      configMap[cfg['name'] as String] = cfg;
    }
    Map<String, dynamic>? cfg = configMap[clsName];
    if (cfg == null) {
      for (final cfgEntry in configMap.entries) {
        if (cfgEntry.key.contains(clsName) || clsName.contains(cfgEntry.key)) {
          cfg = cfgEntry.value;
          break;
        }
      }
    }
    if (cfg == null) return 'C';
    final aMax = (cfg['a_max'] as num?)?.toInt() ?? 0;
    final bMax = (cfg['b_max'] as num?)?.toInt() ?? 0;
    if (count <= aMax) return 'A';
    if (count <= bMax) return 'B';
    return 'C';
  }

  /// 根据图片的标注框列表判定 A/B/C 等级
  String _classifyImageGrade(String imagePath) {
    final annotations = _perImageAnnotations[imagePath];
    final cached = _perImageResults[imagePath];
    final Map<String, int> defectCounts = {};

    if (annotations != null) {
      if (annotations.isEmpty) return 'OK';
      for (final ann in annotations) {
        defectCounts[ann.className] = (defectCounts[ann.className] ?? 0) + 1;
      }
    } else if (cached != null) {
      if (cached.detections.isEmpty) return 'OK';
      for (final d in cached.detections) {
        defectCounts[d.className] = (defectCounts[d.className] ?? 0) + 1;
      }
    } else {
      return 'OK';
    }

    if (defectCounts.isEmpty) return 'OK';

    // 构建配置查找表
    final Map<String, Map<String, dynamic>> configMap = {};
    for (final cfg in _defectGradingConfig) {
      configMap[cfg['name'] as String] = cfg;
    }

    const gradeOrder = {'A': 0, 'B': 1, 'C': 2};
    String worstGrade = 'A';
    int worstLevel = 99;

    for (final entry in defectCounts.entries) {
      final clsName = entry.key;
      final count = entry.value;

      final thisGrade = _getGradeForDefect(clsName, count);
      int thisLevel = 0;
      
      Map<String, dynamic>? cfg = configMap[clsName];
      if (cfg == null) {
        for (final cfgEntry in configMap.entries) {
          if (cfgEntry.key.contains(clsName) || clsName.contains(cfgEntry.key)) {
            cfg = cfgEntry.value;
            break;
          }
        }
      }
      thisLevel = (cfg?['level'] as num?)?.toInt() ?? 99;

      // 比较严重性
      if ((gradeOrder[thisGrade] ?? 0) > (gradeOrder[worstGrade] ?? 0)) {
        worstGrade = thisGrade;
        worstLevel = thisLevel;
      } else if ((gradeOrder[thisGrade] ?? 0) == (gradeOrder[worstGrade] ?? 0)) {
        if (thisLevel < worstLevel) {
          worstLevel = thisLevel;
        }
      }
    }

    return worstGrade;
  }

  /// 重新计算所有已检测图片的等级
  void _updateAllGrades() {
    for (final f in _files) {
      final path = f.$3;
      final result = f.$2;
      if (result == 'NG' || result == 'OK') {
        _perImageGrades[path] = _classifyImageGrade(path);
      }
    }
  }

  final List<String> _logs = <String>[];
  bool _showFullLogs = false; // 帮助页控制：显示完整日志字段
  String _appVersion = '';
  // 文件列表: (文件名, 结果NG/OK/待检测, 文件完整路径)
  List<(String, String, String)> _files = <(String, String, String)>[];
  int _selectedFileIdx = -1; // 当前选中的文件索引
  final ScrollController _fileListScrollCtrl = ScrollController(); // 文件列表滚动控制器
  double _imageWidth = 0; // 当前图像实际宽度
  double _imageHeight = 0; // 当前图像实际高度
  double _previewCanvasWidth = 0; // 中央预览区域宽度
  double _previewCanvasHeight = 0; // 中央预览区域高度
  double get _imageAspectRatio => _imageHeight > 0 ? _imageWidth / _imageHeight : 0;

  DetectionApiService? _apiInstance;
  DetectionApiService get _api {
    final url = _backendCtrl.text.trim();
    if (_apiInstance == null || _apiInstance!.baseUrl != url) {
      _apiInstance = DetectionApiService(url);
    }
    return _apiInstance!;
  }

  // Project Info State
  Map<String, dynamic> _projectInfoData = {};

  // History Data
  List<Map<String, dynamic>> _historyList = [];
  List<Map<String, dynamic>> _detectionHistoryList = [];
  bool _isLoadingHistory = false;

  // 缺陷类别管理
  bool _classManageMode = false; // 是否展开类别管理面板

  // ─── 图片交互：平移/缩放 ───
  final TransformationController _transformCtrl = TransformationController();
  static const double _minScale = 1.0;
  static const double _maxScale = 10.0;

  /// NMS 防重叠检查：检测新添加的标注框是否与现有框高度重合 (IoU > 0.5)
  bool _isDuplicateAnnotation(List<AnnotationBox> existing, AnnotationBox newbie) {
    for (final e in existing) {
      final intersect = e.rect.intersect(newbie.rect);
      if (intersect.width <= 0 || intersect.height <= 0) continue;
      final iArea = intersect.width * intersect.height;
      final uArea = (e.rect.width * e.rect.height) + (newbie.rect.width * newbie.rect.height) - iArea;
      if (uArea <= 0) continue;
      if ((iArea / uArea) > 0.5) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _loadHistory(); // Load history on startup
    _loadSettings(); // Restore saved settings
    // 本地纯开源版 — 无需登录信息
    _online = false;
    _modelReady = false;
    _loadAppVersion();
    _initAnnouncements();
    _fetchGpuStatus();
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    _fileListScrollCtrl.dispose();
    _backendCtrl.dispose();
    _labelCtrl.dispose();
    _modelCtrl.dispose();
    _projNameCtrl.dispose(); _projCodeCtrl.dispose(); _clientCtrl.dispose();
    _projAddrCtrl.dispose(); _testUnitCtrl.dispose(); _testDateCtrl.dispose();
    _testerCtrl.dispose(); _moduleVendorCtrl.dispose(); _moduleModelCtrl.dispose();
    _modulePowerCtrl.dispose(); _openVoltCtrl.dispose(); _shortCurrCtrl.dispose();
    _moduleTypeCtrl.dispose(); _moduleCountCtrl.dispose();
    _announcementTimer?.cancel();
    super.dispose();
  }

  void _log(String text, {String level = 'INFO'}) {
    final now = TimeOfDay.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    setState(() => _logs.insert(0, '$t  $level  $text'));
  }

  // (开源版已移除远程品牌拉取和机器码生成)

  /// 一键上报日志
  Future<void> _reportLogs() async {
    _toast('本地纯开源版本已移除远程日志与计费等上传模块。');
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {}
  }

  /// 获取 GPU / 系统诊断信息
  Future<void> _fetchGpuStatus() async {
    try {
      final result = await _api.getGpuStatus();
      if (mounted) setState(() => _gpuStatus = result);
    } catch (_) {
      // 端点不可用时，设置默认状态避免一直显示"检测中..."
      if (mounted && _gpuStatus == null) {
        setState(() => _gpuStatus = {
          'inference_device': 'GPU',
          'gpu_available': true,
          'all_dependencies_ok': true,
          'gpu_name': 'GPU',
        });
      }
    }
  }

  /// 显示 GPU / 系统诊断详情弹窗
  void _showGpuDiagDialog() {
    final status = _gpuStatus;
    if (status == null) {
      _toast('正在获取硬件信息...');
      _fetchGpuStatus();
      return;
    }
    final isGpu = status['inference_device'] == 'GPU';
    final deps = (status['dependencies'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final sysInfo = status['system_info'] as Map<String, dynamic>? ?? {};
    final allOk = status['all_dependencies_ok'] == true;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isGpu ? const Color(0xFF3EEAA0).withValues(alpha: 0.4) : const Color(0xFFF59E0B).withValues(alpha: 0.4)),
        ),
        child: SizedBox(
          width: 520,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 标题
                Row(children: [
                  Icon(
                    isGpu ? Icons.memory_rounded : Icons.warning_amber_rounded,
                    color: isGpu ? const Color(0xFF3EEAA0) : const Color(0xFFF59E0B),
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isGpu ? 'GPU 加速已启用' : 'CPU 模式（未使用 GPU）',
                    style: TextStyle(
                      color: isGpu ? const Color(0xFF3EEAA0) : const Color(0xFFF59E0B),
                      fontSize: 18, fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  // 刷新按钮
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF7DD3FC), size: 20),
                    tooltip: '刷新',
                    onPressed: () {
                      Navigator.pop(ctx);
                      _fetchGpuStatus().then((_) {
                        if (mounted) _showGpuDiagDialog();
                      });
                    },
                  ),
                ]),
                const SizedBox(height: 16),

                // GPU 硬件信息
                _diagSection('GPU 硬件', [
                  _diagRow('显卡型号', status['gpu_name']?.toString() ?? 'N/A'),
                  _diagRow('显存', '${status['gpu_memory_used_mb'] ?? 0} / ${status['gpu_memory_total_mb'] ?? 0} MB'),
                  _diagRow('驱动版本', status['gpu_driver_version']?.toString() ?? 'N/A'),
                  _diagRow('CUDA 版本', status['cuda_version']?.toString() ?? 'N/A'),
                ]),
                const SizedBox(height: 12),

                // 推理引擎
                _diagSection('推理引擎', [
                  _diagRow('ONNX Runtime', status['onnxruntime_version']?.toString() ?? 'N/A'),
                  _diagRow('GPU 包', (status['onnxruntime_gpu'] == true) ? '✅ onnxruntime-gpu' : '❌ 仅 CPU 版'),
                  _diagRow('推理设备', status['active_provider']?.toString() ?? 'N/A'),
                ]),
                const SizedBox(height: 12),

                // 依赖检查
                _diagSection('CUDA/cuDNN 依赖', [
                  for (final dep in deps) ...[
                    _diagDepRow(dep),
                  ],
                ]),
                const SizedBox(height: 12),

                // 系统信息
                _diagSection('系统信息', [
                  _diagRow('操作系统', sysInfo['os']?.toString() ?? 'N/A'),
                  _diagRow('CPU', sysInfo['cpu']?.toString() ?? 'N/A'),
                  _diagRow('内存', '${sysInfo['ram_used_gb'] ?? 0} / ${sysInfo['ram_total_gb'] ?? 0} GB (${sysInfo['ram_percent'] ?? 0}%)'),
                  _diagRow('CPU 使用率', '${sysInfo['cpu_percent'] ?? 0}%'),
                ]),

                // 如果有缺失依赖，显示警告
                if (!allOk) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3F1D1D),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Row(children: [
                        Icon(Icons.warning_rounded, color: Color(0xFFF87171), size: 16),
                        SizedBox(width: 6),
                        Text('缺少依赖库', style: TextStyle(color: Color(0xFFF87171), fontSize: 13, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 8),
                      for (final dep in deps.where((d) => d['status'] == 'missing'))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('• ${dep['name']}: ${dep['detail']}',
                              style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                            if (dep['install_hint'] != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 12, top: 2),
                                child: Text('💡 ${dep['install_hint']}',
                                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                              ),
                            if (dep['download_url'] != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 12, top: 2),
                                child: InkWell(
                                  onTap: () => launchUrl(Uri.parse(dep['download_url'])),
                                  child: Text('📥 ${dep['download_url']}',
                                    style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11, decoration: TextDecoration.underline)),
                                ),
                              ),
                          ]),
                        ),
                    ]),
                  ),
                ],

                const SizedBox(height: 16),
                // 关闭按钮
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭', style: TextStyle(color: Color(0xFF7DD3FC), fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// 诊断面板 section 标题
  Widget _diagSection(String title, List<Widget> children) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0A1628),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1E3A5F).withValues(alpha: 0.5)),
        ),
        child: Column(children: children),
      ),
    ]);
  }

  /// 诊断面板 key-value 行
  Widget _diagRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12))),
        Expanded(child: Text(value, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  /// 诊断面板依赖状态行（带颜色状态指示）
  Widget _diagDepRow(Map<String, dynamic> dep) {
    final ok = dep['status'] == 'ok';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ok ? const Color(0xFF3EEAA0) : const Color(0xFFF87171),
            boxShadow: [BoxShadow(color: ok ? const Color(0xFF3EEAA0) : const Color(0xFFF87171), blurRadius: 4)],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 170, child: Text(dep['name']?.toString() ?? '', style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12))),
        Expanded(child: Text(dep['detail']?.toString() ?? '', style: TextStyle(color: ok ? const Color(0xFF3EEAA0) : const Color(0xFFF87171), fontSize: 11))),
      ]),
    );
  }

  /// 检查更新
  Future<void> _checkForUpdate() async {
    _toast('开源版本请通过 GitHub 获取最新版本');
  }

  /// 滚动文件列表到指定索引，使其居中显示（每项约28px高度）
  void _scrollFileListTo(int originalIndex) {
    if (!_fileListScrollCtrl.hasClients) return;
    // 将原始索引转换为排序后的视觉位置，确保排序模式下也能正确居中
    final sortedIndices = _buildSortedIndices();
    final visualIndex = sortedIndices.indexOf(originalIndex);
    if (visualIndex < 0) return;
    const itemHeight = 28.0;
    final viewportHeight = _fileListScrollCtrl.position.viewportDimension;
    final target = (visualIndex * itemHeight - viewportHeight / 2 + itemHeight / 2)
        .clamp(0.0, _fileListScrollCtrl.position.maxScrollExtent);
    _fileListScrollCtrl.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Future<void> _run(String action, Future<void> Function() fn) async {
    if (_working) return;
    setState(() => _working = true);
    _log('$action 开始');
    try {
      await fn();
      _log('$action 完成');
    } on DioException catch (e) {
      final detail = e.response?.data.toString() ?? e.message ?? '请求失败';
      _log('$action 失败: $detail', level: 'ERROR');
      _toast(detail);
    } catch (e) {
      _log('$action 失败: $e', level: 'ERROR');
      _toast('$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pickImage() async {
    final p = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'tif', 'tiff']);
    final path = p?.files.single.path;
    if (path == null) return;
    final name = path.split('\\').last.split('/').last;
    // 读取图像实际尺寸
    await _loadImageSize(path);
    setState(() {
      _imagePath = path;
      _annotations.clear();
      _single = null;
      _selectedIdx = null;
      // 如果文件列表中没有这个文件，添加进去
      final exists = _files.any((f) => f.$3 == path);
      if (!exists) {
        _files.insert(0, (name, '待检测', path));
      }
      _selectedFileIdx = _files.indexWhere((f) => f.$3 == path);
      _resetTransform();
    });
    _log('已选择图像: $name');
    if (_cellBrightEnabled) {
      _runCellBrightnessAnalysis(path);
    }
  }

  /// 读取图像文件的实际尺寸
  Future<void> _loadImageSize(String path) async {
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _imageWidth = frame.image.width.toDouble();
      _imageHeight = frame.image.height.toDouble();
      frame.image.dispose();
    } catch (_) {
      _imageWidth = 0;
      _imageHeight = 0;
    }
  }

  /// 计算文件相对于输入根目录 _folderPath 的子目录路径
  /// 例如输入根目录为 D:\images，文件为 D:\images\a\b\1.jpg，返回 "a\b"
  String _computeRelativeSubdir(String filePath) {
    if (_folderPath == null || _folderPath!.isEmpty) return '';
    final fileDir = File(filePath).parent.path;
    final rootDir = _folderPath!;
    // 标准化路径分隔符
    final normalizedFileDir = fileDir.replaceAll('/', '\\');
    final normalizedRootDir = rootDir.replaceAll('/', '\\');
    if (normalizedFileDir.startsWith(normalizedRootDir)) {
      var rel = normalizedFileDir.substring(normalizedRootDir.length);
      if (rel.startsWith('\\') || rel.startsWith('/')) rel = rel.substring(1);
      return rel;
    }
    return '';
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    setState(() => _folderPath = path);
    _log('已选择目录: $path');
    // 先扫描目录
    await _scanFolder(path);
    // 检查是否有断点可恢复（扫描后再检查，恢复时会覆盖_files）
    await _loadCheckpoint(path);
  }

  Future<void> _scanFolder(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      final exts = {'.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff'};
      final found = <(String, String, String)>[];
      for (final f in dir.listSync(recursive: true)) {
        if (f is File) {
          final ext = f.path.split('.').last.toLowerCase();
          if (exts.contains('.$ext')) {
            final name = f.path.split('\\').last.split('/').last;
            found.add((name, '待检测', f.path));
          }
        }
      }
      found.sort((a, b) => a.$1.compareTo(b.$1));
      
      if (found.isNotEmpty) {
        // Automatically load the first image
        final firstPath = found.first.$3;
        await _loadImageSize(firstPath);
        setState(() {
          _files = found;
          _selectedFileIdx = 0;
          _imagePath = firstPath;
          _annotations.clear();
          _selectedIdx = null;
          _resetTransform();
          _single = null;
        });
        if (_cellBrightEnabled) _runCellBrightnessAnalysis(firstPath);
      } else {
        setState(() {
          _files = found;
          _selectedFileIdx = -1;
        });
      }
      
      _log('扫描到 ${found.length} 张图片');
    } catch (e) {
      _log('扫描目录失败: $e', level: 'ERROR');
    }
  }

  // ─── 拖拽文件处理 ───
  static const _imageExts = {'.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff'};

  void _onDragDone(DropDoneDetails details) async {
    setState(() => _isDragging = false);
    if (details.files.isEmpty) return;

    final paths = details.files.map((f) => f.path).toList();

    // 判断是文件夹还是文件
    if (paths.length == 1 && FileSystemEntity.isDirectorySync(paths.first)) {
      // 拖入文件夹 → 等同于打开目录
      final dirPath = paths.first;
      setState(() => _folderPath = dirPath);
      _log('拖入目录: $dirPath');
      await _scanFolder(dirPath);
      await _loadCheckpoint(dirPath);
      return;
    }

    // 过滤出图片文件
    final imgPaths = paths.where((p) {
      final ext = '.${p.split('.').last.toLowerCase()}';
      return _imageExts.contains(ext) && FileSystemEntity.isFileSync(p);
    }).toList();

    if (imgPaths.isEmpty) {
      _toast('未识别到支持的图片文件');
      return;
    }

    if (imgPaths.length == 1) {
      // 单张图片 → 等同于选择图像
      final path = imgPaths.first;
      final name = path.split('\\').last.split('/').last;
      await _loadImageSize(path);
      setState(() {
        _imagePath = path;
        _annotations.clear();
        _single = null;
        _selectedIdx = null;
        final exists = _files.any((f) => f.$3 == path);
        if (!exists) _files.insert(0, (name, '待检测', path));
        _selectedFileIdx = _files.indexWhere((f) => f.$3 == path);
        _resetTransform();
      });
      _log('拖入图像: $name');
      if (_cellBrightEnabled) _runCellBrightnessAnalysis(path);
    } else {
      // 多张图片 → 加入文件列表
      final added = <(String, String, String)>[];
      for (final p in imgPaths) {
        final name = p.split('\\').last.split('/').last;
        final exists = _files.any((f) => f.$3 == p);
        if (!exists) added.add((name, '待检测', p));
      }
      if (added.isNotEmpty) {
        setState(() {
          _files.addAll(added);
          _files.sort((a, b) => a.$1.compareTo(b.$1));
        });
      }
      // 自动加载第一张
      final firstPath = imgPaths.first;
      final firstName = firstPath.split('\\').last.split('/').last;
      await _loadImageSize(firstPath);
      setState(() {
        _imagePath = firstPath;
        _annotations.clear();
        _single = null;
        _selectedIdx = null;
        _selectedFileIdx = _files.indexWhere((f) => f.$3 == firstPath);
        _resetTransform();
      });
      _log('拖入 ${imgPaths.length} 张图片，已加载: $firstName');
    }
  }

  /// 首次检测或切换模式时后台加载对应的本地模型
  Future<bool> _ensureModelLoaded() async {
    // 即使前端认为已加载，也通过 health 检查后端实际状态
    if (_modelReady && _loadedModelMode == _detectMode) {
      try {
        final health = await _api.health();
        final runtime = health['runtime'];
        if (runtime is Map && runtime['model_loaded'] == true) {
          return true; // 后端确实有模型在内存中
        }
        // 后端模型已丢失（例如热重启），需要重新加载
        _log('后端模型已丢失，正在自动重新加载...', level: 'WARN');
        setState(() { _modelReady = false; });
      } catch (_) {
        // health 检查失败，继续尝试加载
        setState(() { _modelReady = false; });
      }
    }

    final targetPath = _detectMode == 'segment' ? _segmentModelPath : _defectModelPath;
    if (targetPath == null || targetPath.isEmpty) {
      _toast('未配置 ${_detectMode == 'segment' ? '分割' : '检测'} 模型，请在"参数设置"中加载(.pt/.onnx)');
      return false;
    }

    _log('正在加载 $_detectMode 对应的后台模型: $targetPath...');
    try {
      final labels = _labelCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final result = await _api.loadModel(
        modelPath: targetPath, 
        labels: labels, 
        inputWidth: 640, 
        inputHeight: 640, 
        confidenceThreshold: _conf, 
        iouThreshold: _iou, 
        outputLayout: 'cxcywh_obj_cls'
      );
      
      // 从后端返回的 runtime 中读取自动检测到的信息
      final runtimeInfo = result['runtime'];
      if (runtimeInfo is Map) {
        final retLabels = runtimeInfo['labels'];
        if (retLabels is List && retLabels.isNotEmpty) {
          _labelCtrl.text = retLabels.map((e) => e.toString()).join(',');
        }
        if (runtimeInfo['model_path'] != null) {
          _modelName = runtimeInfo['model_path'].toString().split(RegExp(r'[/\\]')).last;
        }
      } else {
        final retLabels = result['labels'];
        if (retLabels is List && retLabels.isNotEmpty) {
          _labelCtrl.text = retLabels.map((e) => e.toString()).join(',');
        }
        if (result['model_path'] != null) {
          _modelName = result['model_path'].toString().split(RegExp(r'[/\\]')).last;
        }
      }
      
      _modelName ??= targetPath.split(RegExp(r'[/\\]')).last;
      
      setState(() {
        _modelReady = true;
        _loadedModelMode = _detectMode;
      });
      _log('本地$_detectMode模型挂载成功: $_modelName');
      return true;
    } catch (e) {
      _log('模型加载失败: $e', level: 'ERROR');
      _toast('模型加载失败: $e');
      return false;
    }
  }

  /// 上报一次检测使用量（开源版无配额限制，直接返回 false）
  Future<bool> _reportUsage() async {
    return false;
  }

  /// 检测前检查配额（开源版无配额限制，始终允许）
  bool _checkQuotaBeforeDetect() {
    return true;
  }

  Future<void> _detectSingle() async {
    if (!await _ensureModelLoaded()) return;
    if (!_checkQuotaBeforeDetect()) return;
    if (_imagePath == null) { await _pickImage(); if (_imagePath == null) return; }
    final fileName = _imagePath!.split(RegExp(r'[/\\]')).last;
    _showProgress('正在检测: $fileName ...');
    await _run('当前检测', () async {
      if (_detectMode == 'segment') {
        final doCrop = _autoCrop || _perspectiveCrop;
        final r = await _api.segment(
          imagePath: _imagePath!,
          filterEdges: _filterEdges,
          autoCrop: _autoCrop,
          perspectiveCrop: _perspectiveCrop,
          expandPx: _cropExpandPx.round(),
          cropQuality: _cropQuality,
          cropResW: _cropResW,
          cropResH: _cropResH,
          outputDir: _cropSaveDir.isNotEmpty ? _cropSaveDir : null,
          relativeSubdir: _computeRelativeSubdir(_imagePath!),
        );
        // 加载图像尺寸用于归一化
        if (_imageWidth <= 0 || _imageHeight <= 0) {
          await _loadImageSize(_imagePath!);
        }
        final imgW = _imageWidth > 0 ? _imageWidth : 1.0;
        final imgH = _imageHeight > 0 ? _imageHeight : 1.0;
        // 解析detections并绘制标注框
        final segDetections = (r['detections'] as List?) ?? [];
        setState(() {
          _annotations.clear();
          for (final d in segDetections) {
            final box = d['box'] as Map<String, dynamic>? ?? {};
            final x1 = (box['x1'] as num?)?.toDouble() ?? 0;
            final y1 = (box['y1'] as num?)?.toDouble() ?? 0;
            final x2 = (box['x2'] as num?)?.toDouble() ?? 0;
            final y2 = (box['y2'] as num?)?.toDouble() ?? 0;
            final label = d['class_name'] as String? ?? '?';
            List<Offset>? quadCoords;
            if (d['quad'] is List && (d['quad'] as List).length == 4) {
              final rawQuad = d['quad'] as List;
              quadCoords = rawQuad.map<Offset>((pt) {
                final px = (pt[0] as num).toDouble();
                final py = (pt[1] as num).toDouble();
                return Offset(px / imgW, py / imgH);
              }).toList();
            }

            final ann = AnnotationBox(
              rect: Rect.fromLTRB(x1 / imgW, y1 / imgH, x2 / imgW, y2 / imgH),
              quad: quadCoords,
              className: label,
              score: (d['score'] as num?)?.toDouble() ?? 1.0,
              isManual: false,
            );
            if (!_isDuplicateAnnotation(_annotations, ann)) {
              _annotations.add(ann);
            }
          }
          
          // 匹配裁剪图路径到标注框
          final crops = (r['crops'] as List?) ?? [];
          debugPrint('[MAP-DEBUG] crops count=${crops.length}, annotations count=${_annotations.length}');
          for (int ci = 0; ci < crops.length; ci++) {
            final cropItem = crops[ci];
            final cid = cropItem['label']?.toString();
            final cp = cropItem['crop_path']?.toString();
            debugPrint('[MAP-DEBUG] crop[$ci]: label=$cid, path=$cp');
            if (cp == null || cp.isEmpty) continue;
            
            bool matched = false;
            // 先按 label 匹配
            if (cid != null) {
              for (var ann in _annotations) {
                if (ann.className == cid && ann.cropPath == null) {
                  ann.cropPath = cp;
                  matched = true;
                  debugPrint('[MAP-DEBUG]   -> matched by label to ${ann.className}');
                  break;
                }
              }
            }
            // 按索引回退
            if (!matched && ci < _annotations.length) {
              _annotations[ci].cropPath = cp;
              debugPrint('[MAP-DEBUG]   -> fallback matched by index $ci');
            }
          }
          for (var ann in _annotations) {
            debugPrint('[MAP-DEBUG] final ann: className=${ann.className}, cropPath=${ann.cropPath}');
          }

          // 保存至缓存
          _perImageAnnotations[_imagePath!] = List.from(_annotations);
          
          final idx = _files.indexWhere((f) => f.$3 == _imagePath);
          final statusLabel = doCrop ? '已分割' : '已标注';
          if (idx >= 0) {
            _files[idx] = (_files[idx].$1, statusLabel, _files[idx].$3);
          } else {
            _files.insert(0, (fileName, statusLabel, _imagePath!));
          }
          _selectedFileIdx = _files.indexWhere((f) => f.$3 == _imagePath);
        });
        final segTotal = r['total'] as int? ?? segDetections.length;
        final crops = (r['crops'] as List?) ?? [];
        if (doCrop && crops.isNotEmpty) {
          _toast('分割完成，共 ${crops.length} 张子图，保存在: ${r['output_dir']}');
          _updateProgress('分割裁剪完成: $fileName → $segTotal 块组件，${crops.length} 张子图');
        } else {
          _updateProgress('分割标注完成: $fileName → $segTotal 块组件（未裁剪）');
        }
        await _reportUsage();
        return;
      }

      final r = await _api.detect(imagePath: _imagePath!, confidenceThreshold: _conf, iouThreshold: _iou, saveVisualization: true, visualizationDir: '$_dataDir${Platform.pathSeparator}vis', strokeWidth: _boxStrokeWidth.round(), fontSize: _labelFontSize.round(), showBoxes: _showBoxes, showLabels: _showLabels, showConfidence: _showConfidence);
      if (_imageWidth <= 0 || _imageHeight <= 0) {
        await _loadImageSize(_imagePath!);
      }
      final imgW = _imageWidth > 0 ? _imageWidth : 1.0;
      final imgH = _imageHeight > 0 ? _imageHeight : 1.0;
      setState(() {
        _single = r;
        _batch = null;
        _perImageResults[_imagePath!] = r;
        _annotations.clear();
        for (final d in r.detections) {
          final ann = AnnotationBox(
            rect: Rect.fromLTRB(d.x1 / imgW, d.y1 / imgH, d.x2 / imgW, d.y2 / imgH),
            className: d.className,
            score: d.score,
            isManual: false,
          );
          if (!_isDuplicateAnnotation(_annotations, ann)) {
            _annotations.add(ann);
          }
        }
        // 缓存标注框
        _perImageAnnotations[_imagePath!] = List.from(_annotations);
        // 计算等级
        _perImageGrades[_imagePath!] = _classifyImageGrade(_imagePath!);

        final result = r.total > 0 ? 'NG' : 'OK';
        final idx = _files.indexWhere((f) => f.$3 == _imagePath);
        if (idx >= 0) {
          _files[idx] = (_files[idx].$1, result, _files[idx].$3);
        } else {
          final name = r.imagePath.split('\\').last.split('/').last;
          _files.insert(0, (name, result, _imagePath!));
        }
        _selectedFileIdx = _files.indexWhere((f) => f.$3 == _imagePath);
      });
      // 更新进度条显示结果
      final resultStr = r.total > 0 ? 'NG' : 'OK';
      _updateProgress('检测完成: $fileName → $resultStr (${r.total}个缺陷)');
      // 自动保存检测记录
      _saveDetectionRecord(type: 'single', totalImages: 1, ngCount: r.total > 0 ? 1 : 0, okCount: r.total > 0 ? 0 : 1, defectTotal: r.total, fileName: fileName);
      // 上报配额使用量
      await _reportUsage();
      // 明暗片辅助检测（单张检测完成后自动触发）
      if (_cellBrightEnabled && _imagePath != null) {
        _runCellBrightnessAnalysis(_imagePath!);
      }
    });
  }

  /// 检查文件列表中是否有部分已完成的检测结果
  bool get _hasPartialResults {
    if (_files.isEmpty) return false;
    final done = _files.where((f) => f.$2 == 'NG' || f.$2 == 'OK' || f.$2 == '已分割').length;
    return done > 0 && done < _files.length;
  }

  /// 弹出对话框询问用户是重新检测还是继续上次的检测
  /// 返回: true=继续, false=重新, null=取消
  Future<bool?> _showResumeOrRestartDialog() async {
    final done = _files.where((f) => f.$2 == 'NG' || f.$2 == 'OK' || f.$2 == '已分割').length;
    final total = _files.length;
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1A2D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF0B2A4A), width: 1),
        ),
        title: Row(children: [
          const Icon(Icons.help_outline_rounded, color: Color(0xFF7DD3FC), size: 22),
          const SizedBox(width: 8),
          const Text('检测到上次未完成的任务', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          '上次批量检测已完成 $done / $total 张。\n请选择继续检测还是重新开始？',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text('取消', style: TextStyle(color: Colors.white.withValues(alpha: 0.40))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('重新检测', style: TextStyle(color: Color(0xFFFBBF24), fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A5F),
              foregroundColor: const Color(0xFF7DD3FC),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续检测'),
          ),
        ],
      ),
    );
  }

  Future<void> _detectBatch() async {
    if (!await _ensureModelLoaded()) return;
    if (!_checkQuotaBeforeDetect()) return;
    if (_folderPath == null) return _toast('请先选择目录');
    if (_files.isEmpty) return _toast('文件列表为空，请先打开目录');

    // 如果有部分已完成的结果，询问用户是继续还是重新开始
    if (_hasPartialResults) {
      final choice = await _showResumeOrRestartDialog();
      if (choice == null) return; // 用户取消
      if (choice == false) {
        // 重新检测：重置所有文件状态和缓存
        setState(() {
          _files = _files.map((f) => (f.$1, '待检测', f.$3)).toList();
          _perImageResults.clear();
          _batch = null;
          _single = null;
          _annotations.clear();
        });
        await _clearCheckpoint();
        _log('已重置所有检测结果，重新开始批量检测');
      }
      // choice == true: 继续检测，保留现有状态
    }

    // 逐张实时检测模式
    // 统计已完成的文件（从断点恢复时保留统计）
    final batchDefects = <String, int>{};
    int ngCount = 0;
    int okCount = 0;
    for (final f in _files) {
      if (f.$2 == 'NG') {
        ngCount++;
        final cached = _perImageResults[f.$3];
        if (cached != null) {
          for (final d in cached.detections) {
            batchDefects[d.className] = (batchDefects[d.className] ?? 0) + 1;
          }
        }
      } else if (f.$2 == 'OK') {
        okCount++;
      }
    }

    setState(() {
      _working = true;
      _stopRequested = false;
      _pauseCompleter = null;
      _batchCurrentIdx = ngCount + okCount;
      _batchTotalCount = _files.length;
      _batchStartTime = DateTime.now();
      _batchNgCount = ngCount;
      _batchOkCount = okCount;
      _batchProcessedCount = 0;
    });
    _log('批量检测开始: ${_files.length} 张图片${ngCount + okCount > 0 ? " (已完成${ngCount + okCount}张)" : ""}');
    _showProgress('批量检测开始: ${_files.length} 张图片${ngCount + okCount > 0 ? " (已完成${ngCount + okCount}张)" : ""}');

    for (var i = 0; i < _files.length; i++) {
      if (_stopRequested || !mounted) break;

      // 暂停支持
      if (_pauseCompleter != null) {
        _updateProgress('已暂停 · 已处理 ${ngCount + okCount} 张 · NG:$ngCount OK:$okCount');
        await _pauseCompleter!.future;
        if (_stopRequested || !mounted) break;
      }

      final (name, status, fullPath) = _files[i];
      if (status == 'NG' || status == 'OK' || status == '已分割') continue; // 跳过已检测的

      try {
        // 提前切换 UI 至当前图片并清空标注框，防止上一张的标注视觉残留
        setState(() {
          _selectedFileIdx = i;
          _imagePath = fullPath;
          _annotations.clear();
          _single = null;
          _resetTransform();
        });
        
        // 强制延迟一小段时间，确保 Flutter 引擎有空闲时间渲染这个“空画布”状态
        // 防止 CPU 立即进入下一轮 API 请求和 JSON 解析导致 UI 线程阻塞，产生视觉重叠
        await Future.delayed(const Duration(milliseconds: 300));

        if (_detectMode == 'segment') {
          // 加载图像尺寸 — 使用局部变量保存，避免后续 _imageWidth/_imageHeight 被其他异步操作覆盖
          await _loadImageSize(fullPath);
          final localImgW = _imageWidth > 0 ? _imageWidth : 1.0;
          final localImgH = _imageHeight > 0 ? _imageHeight : 1.0;

          final r = await _api.segment(
            imagePath: fullPath,
            filterEdges: _filterEdges,
            autoCrop: _autoCrop,
            perspectiveCrop: _perspectiveCrop,
            expandPx: _cropExpandPx.round(),
            cropQuality: _cropQuality,
            cropResW: _cropResW,
          cropResH: _cropResH,
            outputDir: _cropSaveDir.isNotEmpty ? _cropSaveDir : null,
            relativeSubdir: _computeRelativeSubdir(fullPath),
          );
          
          // ★ 检查API返回后当前显示的图片是否仍然是这张
          // 如果用户在等待期间手动切换了图片，则只缓存结果不更新UI
          final segDetections = (r['detections'] as List?) ?? [];
          okCount++;

          // 构建标注框列表（使用局部变量保存的尺寸，避免竞态）
          final newAnnotations = <AnnotationBox>[];
          for (final d in segDetections) {
            final box = d['box'] as Map<String, dynamic>? ?? {};
            final x1 = (box['x1'] as num?)?.toDouble() ?? 0;
            final y1 = (box['y1'] as num?)?.toDouble() ?? 0;
            final x2 = (box['x2'] as num?)?.toDouble() ?? 0;
            final y2 = (box['y2'] as num?)?.toDouble() ?? 0;
            final label = d['class_name'] as String? ?? '?';
            List<Offset>? quadCoords;
            if (d['quad'] is List && (d['quad'] as List).length == 4) {
              final rawQuad = d['quad'] as List;
              quadCoords = rawQuad.map<Offset>((pt) {
                final px = (pt[0] as num).toDouble();
                final py = (pt[1] as num).toDouble();
                return Offset(px / localImgW, py / localImgH);
              }).toList();
            }

            final ann = AnnotationBox(
              rect: Rect.fromLTRB(x1 / localImgW, y1 / localImgH, x2 / localImgW, y2 / localImgH),
              quad: quadCoords,
              className: label,
              score: (d['score'] as num?)?.toDouble() ?? 1.0,
              isManual: false,
            );
            if (!_isDuplicateAnnotation(newAnnotations, ann)) {
              newAnnotations.add(ann);
            }
          }

          final crops = (r['crops'] as List?) ?? [];
          debugPrint('[BATCH-MAP-DEBUG] crops count=${crops.length}, newAnnotations count=${newAnnotations.length}');
          for (int ci = 0; ci < crops.length; ci++) {
            final cropItem = crops[ci];
            final cid = cropItem['label']?.toString();
            final cp = cropItem['crop_path']?.toString();
            if (cp == null || cp.isEmpty) continue;
            
            bool matched = false;
            if (cid != null) {
              for (var ann in newAnnotations) {
                if (ann.className == cid && ann.cropPath == null) {
                  ann.cropPath = cp;
                  matched = true;
                  break;
                }
              }
            }
            if (!matched && ci < newAnnotations.length) {
              newAnnotations[ci].cropPath = cp;
            }
          }

          // ★ 先将标注缓存到对应图片路径（无论当前显示的是不是这张图）
          _perImageAnnotations[fullPath] = List.from(newAnnotations);

          // ★ 累积类别统计到 batchDefects
          for (final ann in newAnnotations) {
            batchDefects[ann.className] = (batchDefects[ann.className] ?? 0) + 1;
          }

          setState(() {
            _files[i] = (name, '已分割', fullPath);
            // ★ 仅当当前显示的仍然是这张图时，才更新 UI 上的标注框
            if (_imagePath == fullPath) {
              _annotations.clear();
              _annotations.addAll(newAnnotations);
            }
            // ★ 更新批量统计（驱动统计面板实时显示）
            _batch = BatchSummary(
              totalImages: i + 1,
              ngImages: ngCount,
              okImages: okCount,
              totalDefects: batchDefects.values.fold<int>(0, (p, c) => p + c),
              defectByClass: Map.from(batchDefects),
              results: [],
            );
            // ★ 同步更新进度面板所需的批量追踪变量
            _batchCurrentIdx = ngCount + okCount;
            _batchNgCount = ngCount;
            _batchOkCount = okCount;
            _batchProcessedCount++;
          });
          _scrollFileListTo(i);
          _log('[${i + 1}/${_files.length}] $name: 分割成功');
          _updateProgress('批量处理 [${i + 1}/${_files.length}] $name → 已分割');

          // ★ 分割完成后额外等待，让用户能看到当前图的标注结果
          await Future.delayed(const Duration(milliseconds: 200));

          if (await _reportUsage()) break; // 配额耗尽则中断批量
          continue; // 跳过原有的缺陷检测逻辑
        }

        // 加载图像尺寸
        await _loadImageSize(fullPath);
        final imgW = _imageWidth > 0 ? _imageWidth : 1.0;
        final imgH = _imageHeight > 0 ? _imageHeight : 1.0;

        // 执行单张检测
        final r = await _api.detect(imagePath: fullPath, confidenceThreshold: _conf, iouThreshold: _iou, saveVisualization: true, visualizationDir: '$_dataDir${Platform.pathSeparator}vis', strokeWidth: _boxStrokeWidth.round(), fontSize: _labelFontSize.round(), showBoxes: _showBoxes, showLabels: _showLabels, showConfidence: _showConfidence);
        final result = r.total > 0 ? 'NG' : 'OK';
        if (result == 'NG') {
          ngCount++;
        } else {
          okCount++;
        }

        // 统计缺陷
        for (final d in r.detections) {
          batchDefects[d.className] = (batchDefects[d.className] ?? 0) + 1;
        }

        // 缓存每张图片的检测结果
        _perImageResults[fullPath] = r;

        // 实时更新 UI：显示当前检测的图片和标注框
        setState(() {
          _files[i] = (name, result, fullPath);
          _single = r;
          for (final d in r.detections) {
            final ann = AnnotationBox(
              rect: Rect.fromLTRB(d.x1 / imgW, d.y1 / imgH, d.x2 / imgW, d.y2 / imgH),
              className: d.className,
              score: d.score,
              isManual: false,
            );
            if (!_isDuplicateAnnotation(_annotations, ann)) {
              _annotations.add(ann);
            }
          }
          _perImageAnnotations[fullPath] = List.from(_annotations);
          // 计算等级
          _perImageGrades[fullPath] = _classifyImageGrade(fullPath);

          // 更新批量统计
          _batch = BatchSummary(
            totalImages: i + 1,
            ngImages: ngCount,
            okImages: okCount,
            totalDefects: batchDefects.values.fold<int>(0, (p, c) => p + c),
            defectByClass: Map.from(batchDefects),
            results: [],
          );
          _batchCurrentIdx = ngCount + okCount;
          _batchNgCount = ngCount;
          _batchOkCount = okCount;
          _batchProcessedCount++;
        });
        _scrollFileListTo(i);        _log('[${ i + 1}/${_files.length}] $name: $result (${r.total}个缺陷)');
        _updateProgress('批量处理 [${i + 1}/${_files.length}] $name → $result');
        // 每张完成后保存断点
        _saveCheckpoint(ngCount: ngCount, okCount: okCount, defectByClass: Map.from(batchDefects));
        // 上报配额使用量，若返回 stop 则中断批量
        if (await _reportUsage()) break;
      } catch (e) {
        _log('处理失败: $name - $e', level: 'ERROR');
        setState(() {
          _files[i] = (name, '失败', fullPath);
        });
      }
    }

    setState(() => _working = false);
    final totalDefects = batchDefects.values.fold<int>(0, (p, c) => p + c);
    if (_stopRequested) {
      _log('批量检测已停止');
      _updateProgress('批量检测已停止 · 已处理 ${ngCount + okCount} 张 · NG:$ngCount OK:$okCount');
    } else {
      _log('批量检测完成: NG=$ngCount, OK=$okCount');
      _updateProgress('批量检测完成 · 总:${_files.length} · NG:$ngCount OK:$okCount · 缺陷:$totalDefects');
      // 全部完成后清除检查点
      await _clearCheckpoint();
    }
    // 自动保存检测记录
    _saveDetectionRecord(type: 'batch', totalImages: ngCount + okCount, ngCount: ngCount, okCount: okCount, defectTotal: totalDefects);
  }

  void _pause() {
    if (_pauseCompleter != null) {
      _pauseCompleter!.complete();
      _pauseCompleter = null;
      setState(() {});
      _log('任务已恢复', level: 'INFO');
      _toast('已恢复');
    } else if (_working) {
      _pauseCompleter = Completer<void>();
      setState(() {});
      _log('任务已暂停', level: 'WARN');
      _toast('已暂停');
    }
  }
  void _stop() {
    if (_pauseCompleter != null) {
      _pauseCompleter!.complete();
      _pauseCompleter = null;
    }
    setState(() { _working = false; _stopRequested = true; });
    _log('任务已停止', level: 'WARN');
    _toast('已停止');
  }
  void _toast(String text) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  /// 显示持久进度提示（底部常驻条）
  void _showProgress(String message) {
    setState(() { _progressMessage = message; _progressVisible = true; });
  }

  /// 更新进度提示文字
  void _updateProgress(String message) {
    setState(() => _progressMessage = message);
  }

  /// 隐藏进度提示
  void _hideProgress() {
    setState(() { _progressVisible = false; _progressMessage = null; });
  }

  /// 显示完整提示弹窗
  void _showNoticeDialog(String title, String message, {Color color = const Color(0xFF1D4ED8), IconData icon = Icons.info_outline}) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D2137),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFF1E3A5F))),
        title: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Text(title, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
        ]),
        content: Text(message, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定', style: TextStyle(color: Color(0xFF7DD3FC), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Map<String, int> _defects() {
    // 每张光伏板只归属一个缺陷类别（主要缺陷：检出框最多的类型）
    // 总数 = 检测的图片数
    if (_perImageResults.isNotEmpty) {
      final m = <String, int>{};
      for (final r in _perImageResults.values) {
        if (r.detections.isEmpty) continue;
        // 统计该图片上每种缺陷的检出框数量
        final counts = <String, int>{};
        for (final d in r.detections) {
          counts[d.className] = (counts[d.className] ?? 0) + 1;
        }
        // 选出检出框最多的缺陷类型作为该图片的主要缺陷
        String primary = counts.keys.first;
        int maxCount = counts.values.first;
        for (final e in counts.entries) {
          if (e.value > maxCount) {
            maxCount = e.value;
            primary = e.key;
          }
        }
        m[primary] = (m[primary] ?? 0) + 1;
      }
      // 添加无缺陷(OK)统计
      int okCount = 0;
      for (final entry in _perImageResults.entries) {
        if (entry.value.detections.isEmpty) okCount++;
      }
      if (okCount > 0) {
        m['无缺陷(OK)'] = okCount;
      }
      return m;
    }
    if (_single != null && _single!.detections.isNotEmpty) {
      // 单张：统计该图片的主要缺陷
      final counts = <String, int>{};
      for (final d in _single!.detections) {
        counts[d.className] = (counts[d.className] ?? 0) + 1;
      }
      String primary = counts.keys.first;
      int maxCount = counts.values.first;
      for (final e in counts.entries) {
        if (e.value > maxCount) {
          maxCount = e.value;
          primary = e.key;
        }
      }
      return {primary: 1};
    }
    return {};
  }

  // ─── 缺陷类别管理 ───

  /// 从所有已检测图片中收集全部类别（统计有该缺陷的图片数量）
  Map<String, int> _allDetectedClasses() {
    final m = <String, int>{};
    for (final r in _perImageResults.values) {
      final seen = <String>{};
      for (final d in r.detections) {
        seen.add(d.className);
      }
      for (final cls in seen) {
        m[cls] = (m[cls] ?? 0) + 1;
      }
    }
    return m;
  }

  /// 删除指定类别：从所有图片缓存 + 当前标注框中移除
  void _deleteClass(String className) {
    setState(() {
      // 1. 更新 _perImageResults
      for (final path in _perImageResults.keys.toList()) {
        final r = _perImageResults[path]!;
        final filtered = r.detections.where((d) => d.className != className).toList();
        _perImageResults[path] = r.withDetections(filtered);
      }
      // 2. 更新当前标注框
      _annotations.removeWhere((a) => a.className == className);
      if (_selectedIdx != null && _selectedIdx! >= _annotations.length) {
        _selectedIdx = null;
      }
      // 3. 更新 _single
      if (_single != null) {
        final filtered = _single!.detections.where((d) => d.className != className).toList();
        _single = _single!.withDetections(filtered);
      }
      // 4. 更新 _batch 统计
      if (_batch != null) {
        final newByClass = Map<String, int>.from(_batch!.defectByClass)..remove(className);
        final newTotal = newByClass.values.fold<int>(0, (p, c) => p + c);
        final newNg = _perImageResults.values.where((r) => r.detections.isNotEmpty).length;
        final newOk = _perImageResults.values.where((r) => r.detections.isEmpty).length;
        _batch = BatchSummary(
          totalImages: _batch!.totalImages,
          ngImages: newNg,
          okImages: newOk,
          totalDefects: newTotal,
          defectByClass: newByClass,
          results: [],
        );
      }
      // 5. 更新文件列表 NG/OK 状态
      _files = _files.map((f) {
        final r = _perImageResults[f.$3];
        if (r == null) return f;
        final result = r.detections.isNotEmpty ? 'NG' : 'OK';
        return (f.$1, result, f.$3);
      }).toList();
    });
    _toast('已删除类别"$className"及其所有标注框');
  }

  /// 重命名指定类别：更新所有图片缓存 + 当前标注框
  void _renameClass(String oldName, String newName) {
    if (newName.isEmpty || newName == oldName) return;
    setState(() {
      // 1. 更新 _perImageResults
      for (final path in _perImageResults.keys.toList()) {
        final r = _perImageResults[path]!;
        final updated = r.detections.map((d) =>
          d.className == oldName ? d.copyWithClassName(newName) : d
        ).toList();
        _perImageResults[path] = r.withDetections(updated);
      }
      // 2. 更新当前标注框
      for (final a in _annotations) {
        if (a.className == oldName) a.className = newName;
      }
      // 3. 更新 _single
      if (_single != null) {
        final updated = _single!.detections.map((d) =>
          d.className == oldName ? d.copyWithClassName(newName) : d
        ).toList();
        _single = _single!.withDetections(updated);
      }
      // 4. 更新 _batch 统计
      if (_batch != null) {
        final newByClass = <String, int>{};
        for (final e in _batch!.defectByClass.entries) {
          final key = e.key == oldName ? newName : e.key;
          newByClass[key] = (newByClass[key] ?? 0) + e.value;
        }
        _batch = BatchSummary(
          totalImages: _batch!.totalImages,
          ngImages: _batch!.ngImages,
          okImages: _batch!.okImages,
          totalDefects: _batch!.totalDefects,
          defectByClass: newByClass,
          results: [],
        );
      }
    });
    _toast('已将"$oldName"重命名为"$newName"');
  }

  /// 弹出重命名对话框
  Future<void> _showRenameClassDialog(String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1A2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFF1E3A5F))),
        title: const Text('重命名缺陷类别', style: TextStyle(color: Color(0xFFE2F0FF), fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('当前名称：$oldName', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
            decoration: InputDecoration(
              labelText: '新名称',
              labelStyle: const TextStyle(color: Color(0xFF7DD3FC)),
              filled: true,
              fillColor: const Color(0xFF071726),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1E3A5F))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF7DD3FC))),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          const SizedBox(height: 8),
          const Text('将更新全部图片中该类别的标注框名称', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确认重命名'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != oldName) {
      _renameClass(oldName, result);
    }
  }

  /// 弹出删除确认对话框
  Future<void> _showDeleteClassDialog(String className, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1A2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFF1E3A5F))),
        title: const Text('删除缺陷类别', style: TextStyle(color: Color(0xFFE2F0FF), fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          RichText(text: TextSpan(style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6), children: [
            const TextSpan(text: '确认删除类别 '),
            TextSpan(text: '"$className"', style: const TextStyle(color: Color(0xFFF87171), fontWeight: FontWeight.w700)),
            const TextSpan(text: ' ？'),
          ])),
          const SizedBox(height: 6),
          Text('将删除全部图片中该类别的 $count 个标注框，操作不可撤销。', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) _deleteClass(className);
  }

  // ─── 标注交互 ───
  /// 计算 BoxFit.contain 下图像在容器中的实际区域
  Rect _imageRectInContainer(Size containerSize) {
    if (_imageAspectRatio <= 0) {
      return Rect.fromLTWH(0, 0, containerSize.width, containerSize.height);
    }
    final containerAR = containerSize.width / containerSize.height;
    double imgW, imgH;
    if (_imageAspectRatio > containerAR) {
      imgW = containerSize.width;
      imgH = containerSize.width / _imageAspectRatio;
    } else {
      imgH = containerSize.height;
      imgW = containerSize.height * _imageAspectRatio;
    }
    final offsetX = (containerSize.width - imgW) / 2;
    final offsetY = (containerSize.height - imgH) / 2;
    return Rect.fromLTWH(offsetX, offsetY, imgW, imgH);
  }

  /// 将变换矩阵重置为初始状态（无缩放、无平移）
  void _resetTransform() {
    _transformCtrl.value = Matrix4.identity();
  }

  /// 将容器中的像素坐标转换为图像归一化坐标 (0~1)
  /// 通过逆矩阵将屏幕坐标转换为未变换的容器坐标
  Offset _containerToNorm(Offset localPos, Size canvasSize) {
    // 获取当前变换矩阵并计算逆矩阵
    final matrix = _transformCtrl.value;
    late final Matrix4 inverseMatrix;
    try {
      inverseMatrix = Matrix4.inverted(matrix);
    } catch (_) {
      // 矩阵不可逆，回退到单位矩阵
      _resetTransform();
      inverseMatrix = Matrix4.identity();
    }
    // 将屏幕坐标转换为未变换的容器坐标
    final untransformed = MatrixUtils.transformPoint(inverseMatrix, localPos);

    final ir = _imageRectInContainer(canvasSize);
    return Offset(
      ((untransformed.dx - ir.left) / ir.width).clamp(0, 1),
      ((untransformed.dy - ir.top) / ir.height).clamp(0, 1),
    );
  }

  void _onAnnotPanStart(Offset localPos, Size canvasSize) {
    if (!_drawMode || _polygonMode) return;
    // 矩形绘制模式
    _drawStart = _containerToNorm(localPos, canvasSize);
  }

  /// 多边形双击闭合
  void _onAnnotDoubleTap(Offset localPos, Size canvasSize) {
    if (!_polygonMode || _polygonPoints.length < 3) return;
    _closePolygon();
  }

  /// 删除当前选中的标注框
  void _deleteSelected() {
    if (_selectedIdx == null || _selectedIdx! < 0 || _selectedIdx! >= _annotations.length) {
      _toast('请先选中一个标注框');
      return;
    }
    setState(() {
      _annotations.removeAt(_selectedIdx!);
      _selectedIdx = null;
      if (_imagePath != null) {
        _perImageAnnotations[_imagePath!] = List.from(_annotations);
      }
    });
    _updateAllGrades();
    _toast('已删除标注框');
  }

  /// 修改当前选中标注框的类别
  void _modifySelected() {
    if (_selectedIdx == null || _selectedIdx! < 0 || _selectedIdx! >= _annotations.length) {
      _toast('请先选中一个标注框');
      return;
    }
    final current = _annotations[_selectedIdx!].className;
    final options = _annotClassOptions;
    String? selected = options.contains(current) ? current : null;
    final customCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        backgroundColor: const Color(0xFF0D2137),
        title: const Text('修改缺陷类别', style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 14)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('当前类别: $current', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          const SizedBox(height: 10),
          // 从已有类别选择
          ...options.map((opt) => RadioListTile<String>(
            title: Text(opt, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
            value: opt,
            groupValue: selected,
            activeColor: const Color(0xFF22D3EE),
            dense: true,
            onChanged: (v) => setDlg(() { selected = v; customCtrl.clear(); }),
          )),
          const SizedBox(height: 8),
          // 自定义输入
          TextField(
            controller: customCtrl,
            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
            decoration: const InputDecoration(
              hintText: '或输入自定义类别...',
              hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 12),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF334155))),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF22D3EE))),
            ),
            onChanged: (v) { if (v.isNotEmpty) setDlg(() => selected = null); },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22D3EE), foregroundColor: Colors.black),
            onPressed: () {
              final newClass = customCtrl.text.trim().isNotEmpty ? customCtrl.text.trim() : selected;
              if (newClass == null || newClass.isEmpty) {
                _toast('请选择或输入类别');
                return;
              }
              setState(() {
                _annotations[_selectedIdx!] = _annotations[_selectedIdx!].copyWith(className: newClass);
                if (_imagePath != null) {
                  _perImageAnnotations[_imagePath!] = List.from(_annotations);
                }
                _updateAllGrades();
              });
              Navigator.pop(ctx);
              _toast('类别已修改为: $newClass');
            },
            child: const Text('确定'),
          ),
        ],
      )),
    );
  }

  /// 闭合当前多边形并创建标注
  void _closePolygon() {
    if (_polygonPoints.length < 3) return;
    // 计算多边形的外接矩形
    double minX = 1, minY = 1, maxX = 0, maxY = 0;
    for (final p in _polygonPoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    final boundingRect = Rect.fromLTRB(minX, minY, maxX, maxY);
    setState(() {
      final ann = AnnotationBox(
        rect: boundingRect,
        quad: List<Offset>.from(_polygonPoints),
        className: _annotClass,
        isManual: true,
      );
      _annotations.add(ann);
      _polygonPoints.clear();
      if (_imagePath != null) {
        _perImageAnnotations[_imagePath!] = List.from(_annotations);
      }
      _log('新增多边形标注: $_annotClass (${ann.quad!.length}个顶点)');
      _updateAllGrades();
    });
  }

  /// ★ 纯点击选中标注框（onTapDown 触发，无需拖拽）
  void _onAnnotTapDown(Offset localPos, Size canvasSize) {
    // ── 多边形模式：点击添加顶点 ──
    if (_polygonMode) {
      final norm = _containerToNorm(localPos, canvasSize);
      // 如果已有 ≥3 个点且点击靠近起始点，闭合多边形
      if (_polygonPoints.length >= 3 && (_polygonPoints.first - norm).distance < 0.03) {
        _closePolygon();
        return;
      }
      setState(() => _polygonPoints.add(norm));
      return;
    }
    if (_drawMode) return; // 矩形绘制模式不处理点击选中
    final norm = _containerToNorm(localPos, canvasSize);
    const hitR = 0.02; // 顶点命中半径（归一化坐标）

    // ── 检测是否点击到某个标注框的顶点（设置拖拽状态）──
    for (var i = _annotations.length - 1; i >= 0; i--) {
      final b = _annotations[i];
      // quad 顶点检测（支持N个顶点）
      if (b.quad != null && b.quad!.length >= 3) {
        for (var v = 0; v < b.quad!.length; v++) {
          if ((b.quad![v] - norm).distance < hitR) {
            _dragBoxIdx = i; _dragVertexIdx = v; _dragWholeBox = false;
            _dragAnchor = norm;
            setState(() { for (var a in _annotations) {
              a.selected = false;
            } b.selected = true; _selectedIdx = i; });
            return;
          }
        }
      }
      // rect 四角检测
      final corners = [b.rect.topLeft, b.rect.topRight, b.rect.bottomRight, b.rect.bottomLeft];
      for (var v = 0; v < 4; v++) {
        if ((corners[v] - norm).distance < hitR) {
          _dragBoxIdx = i; _dragVertexIdx = v; _dragWholeBox = false;
          _dragAnchor = norm;
          setState(() { for (var a in _annotations) {
            a.selected = false;
          } b.selected = true; _selectedIdx = i; });
          return;
        }
      }
    }

    // ── 检测是否点击到框内部（选中 + 准备拖动整个框）──
    int? hit;
    for (var i = _annotations.length - 1; i >= 0; i--) {
      if (_annotations[i].rect.contains(norm)) { hit = i; break; }
    }
    if (hit != null) {
      _dragBoxIdx = hit; _dragVertexIdx = null; _dragWholeBox = true;
      _dragAnchor = norm;
      setState(() { for (var a in _annotations) {
        a.selected = false;
      } _annotations[hit!].selected = true; _selectedIdx = hit; });
      return;
    }

    // ── 未命中任何框：取消选中 ──
    _dragBoxIdx = null; _dragVertexIdx = null; _dragWholeBox = false; _dragAnchor = null;
    setState(() { for (var a in _annotations) {
      a.selected = false;
    } _selectedIdx = null; });
  }

  void _onAnnotPanUpdate(Offset localPos, Size canvasSize) {
    // ── 拖拽编辑模式 ──
    if (_dragBoxIdx != null && _dragAnchor != null && !_drawMode) {
      final norm = _containerToNorm(localPos, canvasSize);
      final dx = norm.dx - _dragAnchor!.dx;
      final dy = norm.dy - _dragAnchor!.dy;
      _dragAnchor = norm;
      final b = _annotations[_dragBoxIdx!];

      setState(() {
        if (_dragWholeBox) {
          // 拖动整个框
          _annotations[_dragBoxIdx!] = b.copyWith(
            rect: b.rect.translate(dx, dy),
            quad: b.quad?.map((p) => Offset(p.dx + dx, p.dy + dy)).toList(),
          );
        } else if (_dragVertexIdx != null) {
          if (b.quad != null && b.quad!.length >= 3) {
            // 拖动 quad 顶点（支持N个顶点）
            final newQuad = List<Offset>.from(b.quad!);
            if (_dragVertexIdx! < newQuad.length) {
              newQuad[_dragVertexIdx!] = Offset(
                (newQuad[_dragVertexIdx!].dx + dx).clamp(0, 1),
                (newQuad[_dragVertexIdx!].dy + dy).clamp(0, 1),
              );
            }
            // 同步更新 rect 为 quad 的外接矩形
            double minX = 1, minY = 1, maxX = 0, maxY = 0;
            for (final p in newQuad) {
              if (p.dx < minX) minX = p.dx; if (p.dy < minY) minY = p.dy;
              if (p.dx > maxX) maxX = p.dx; if (p.dy > maxY) maxY = p.dy;
            }
            _annotations[_dragBoxIdx!] = b.copyWith(
              rect: Rect.fromLTRB(minX, minY, maxX, maxY),
              quad: newQuad,
            );
          } else {
            // 拖动 rect 顶点
            double l = b.rect.left, t = b.rect.top, r = b.rect.right, bt = b.rect.bottom;
            switch (_dragVertexIdx!) {
              case 0: l += dx; t += dy; break; // TL
              case 1: r += dx; t += dy; break; // TR
              case 2: r += dx; bt += dy; break; // BR
              case 3: l += dx; bt += dy; break; // BL
            }
            _annotations[_dragBoxIdx!] = b.copyWith(
              rect: Rect.fromLTRB(l.clamp(0, 1), t.clamp(0, 1), r.clamp(0, 1), bt.clamp(0, 1)),
            );
          }
        }
      });
      return;
    }
    // ── 绘制模式 ──
    if (!_drawMode || _drawStart == null) return;
    final cur = _containerToNorm(localPos, canvasSize);
    setState(() {
      _drawingRect = Rect.fromPoints(_drawStart!, cur);
    });
  }

  void _onAnnotPanEnd() {
    // ── 拖拽编辑结束：保存缓存 ──
    if (_dragBoxIdx != null) {
      _dragBoxIdx = null; _dragVertexIdx = null; _dragWholeBox = false; _dragAnchor = null;
      if (_imagePath != null) {
        _perImageAnnotations[_imagePath!] = List.from(_annotations);
      }
      _updateAllGrades();
      return;
    }
    // ── 绘制模式结束 ──
    if (!_drawMode || _drawingRect == null) return;
    if (_drawingRect!.width > 0.01 && _drawingRect!.height > 0.01) {
      setState(() {
        final ann = AnnotationBox(rect: _drawingRect!, className: _annotClass, isManual: true);
        if (!_isDuplicateAnnotation(_annotations, ann)) {
          _annotations.add(ann);
          _log('新增手动标注: $_annotClass');
        } else {
          _toast('此处已有雷同标注框');
        }
        if (_imagePath != null) {
          _perImageAnnotations[_imagePath!] = List.from(_annotations);
        }
        _updateAllGrades();
      });
    }
    _drawStart = null;
    _drawingRect = null;
  }

  /// 弹出裁剪设置弹窗（执行裁剪 + 参数设置）
  void _showCropSettingsDialog() {
    // 使用局部变量镜像当前状态，方便弹窗内实时更新
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          void updateState(VoidCallback fn) {
            setState(fn);
            setDlgState(() {});
            _saveSettings();
          }

          Future<void> executeCrop() async {
            if (_imagePath == null) {
              _toast('请先选择图像');
              return;
            }
            if (!_modelReady) {
              _toast('请先加载分割模型');
              return;
            }
            Navigator.pop(ctx);
            _showProgress('正在执行裁剪...');
            await _run('执行裁剪', () async {
              final r = await _api.segment(
                imagePath: _imagePath!,
                filterEdges: _filterEdges,
                autoCrop: true,
                perspectiveCrop: _perspectiveCrop,
                expandPx: _cropExpandPx.round(),
                cropQuality: _cropQuality,
                cropResW: _cropResW,
          cropResH: _cropResH,
              );
              final crops = (r['crops'] as List?) ?? [];
              final total = r['total'] as int? ?? 0;
              // 刷新标注框
              if (_imageWidth <= 0 || _imageHeight <= 0) {
                await _loadImageSize(_imagePath!);
              }
              final imgW = _imageWidth > 0 ? _imageWidth : 1.0;
              final imgH = _imageHeight > 0 ? _imageHeight : 1.0;
              final segs = (r['detections'] as List?) ?? [];
              setState(() {
                _annotations.clear();
                for (final d in segs) {
                  final box = d['box'] as Map<String, dynamic>? ?? {};
                  final x1 = (box['x1'] as num?)?.toDouble() ?? 0;
                  final y1 = (box['y1'] as num?)?.toDouble() ?? 0;
                  final x2 = (box['x2'] as num?)?.toDouble() ?? 0;
                  final y2 = (box['y2'] as num?)?.toDouble() ?? 0;
                  _annotations.add(AnnotationBox(
                    rect: Rect.fromLTRB(x1 / imgW, y1 / imgH, x2 / imgW, y2 / imgH),
                    className: d['class_name'] as String? ?? '?',
                    score: (d['score'] as num?)?.toDouble() ?? 1.0,
                    isManual: false,
                  ));
                }
              });
              if (crops.isNotEmpty) {
                _toast('裁剪完成！共 ${crops.length} 张子图，保存于: ${r['output_dir']}');
                _updateProgress('裁剪完成: $total 块组件，${crops.length} 张子图已保存');
              } else {
                _toast('未找到有效组件，裁剪未保存任何文件');
                _updateProgress('裁剪完成：未裁出有效子图');
              }
            });
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFF334155))),
            title: const Row(children: [
              Icon(Icons.content_cut, color: Color(0xFF7DD3FC), size: 20),
              SizedBox(width: 8),
              Text('裁剪功能设置', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            content: SizedBox(
              width: 380,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('点击「执行裁剪」可立即按当前图像的检测框裁剪并保存子图；也可在下次检测时勾选透视裁剪后自动执行。',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                const SizedBox(height: 12),
                // ── 透视裁剪 ──
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _perspectiveCrop,
                  onChanged: (v) => updateState(() => _perspectiveCrop = v),
                  title: const Text('透视裁剪', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
                  subtitle: const Text('按四顶点多边形做透视变换后裁剪', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                  activeThumbColor: const Color(0xFF7DD3FC),
                ),
                const Divider(color: Color(0xFF1E293B), height: 16),
                // ── 外扩像素 ──
                Row(children: [
                  const Text('外扩像素', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
                  const Spacer(),
                  Text('${_cropExpandPx.round()} px', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _cropExpandPx,
                  min: 0, max: 100, divisions: 100,
                  activeColor: const Color(0xFF7DD3FC),
                  inactiveColor: const Color(0xFF1E293B),
                  label: '${_cropExpandPx.round()} px',
                  onChanged: (v) => updateState(() => _cropExpandPx = v),
                ),
                const SizedBox(height: 4),
                // ── 保存质量 ──
                Row(children: [
                  const Text('保存质量', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
                  const Spacer(),
                  Text('$_cropQuality%', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _cropQuality.toDouble(),
                  min: 30, max: 100, divisions: 70,
                  activeColor: const Color(0xFF7DD3FC),
                  inactiveColor: const Color(0xFF1E293B),
                  label: '$_cropQuality%',
                  onChanged: (v) => updateState(() => _cropQuality = v.round()),
                ),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭', style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.crop, size: 16),
                label: const Text('执行裁剪'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1D4ED8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: executeCrop,
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── 明暗片辅助检测 ───
  Color _gradeBadgeColor(String? grade) {
    switch (grade) {
      case 'A': return const Color(0xFF34D399);
      case 'B': return const Color(0xFFFBBF24);
      case 'C': return const Color(0xFFF97316);
      case 'D': return const Color(0xFFEF4444);
      default:  return const Color(0xFF94A3B8);
    }
  }

  Future<void> _runCellBrightnessAnalysis(String imgPath) async {
    if (!_cellBrightEnabled) return;
    setState(() { _cellAnalyzing = true; });
    try {
      final backendUrl = _backendCtrl.text.isEmpty ? 'http://127.0.0.1:5000' : _backendCtrl.text;
      final dio = Dio();
      final resp = await dio.post(
        '$backendUrl/api/analyze/cell_brightness',
        data: {
          'image_path': imgPath,
          'rows': _cellRows,
          'cols': _cellCols,
          'ref_mode': 'median',
          'threshold_a': _cellThresholdA,
          'threshold_b': _cellThresholdB,
          'threshold_c': _cellThresholdC,
        },
      );
      if (resp.statusCode == 200) {
        setState(() { _cellBrightResult = Map<String, dynamic>.from(resp.data); });
        final summary = _cellBrightResult?['summary'];
        final grade = summary?['overall_grade'] ?? 'A';
        final countA = summary?['grade_A'] ?? 0;
        final countB = summary?['grade_B'] ?? 0;
        final countC = summary?['grade_C'] ?? 0;
        final countD = summary?['grade_D'] ?? 0;
        _log('明暗片分析[$_cellRows×$_cellCols]: 总体=$grade A=$countA B=$countB C=$countC D=$countD');

        // 将异常的明暗片也并入缺陷标注中 (仅在缺陷检测模式下)
        if (_detectMode == 'defect' && _imagePath == imgPath) {
          final cellsList = _cellBrightResult?['cells'] as List?;
          if (cellsList != null && _imageWidth > 0 && _imageHeight > 0) {
            final cellW = 1.0 / _cellCols;
            final cellH = 1.0 / _cellRows;
            bool addedNew = false;
            setState(() {
              // 先移除旧的明暗片标注，避免重复叠加
              _annotations.removeWhere((a) => a.className.startsWith('明暗片-'));

              // 用 Set 记录已占用的网格位置，确保每格最多一个标注
              final occupied = <String>{};
              for (int r = 0; r < _cellRows; r++) {
                if (r >= cellsList.length) continue;
                final rowCells = cellsList[r] as List;
                for (int c = 0; c < _cellCols; c++) {
                  if (c >= rowCells.length) continue;
                  final cellKey = '$r,$c';
                  if (occupied.contains(cellKey)) continue;
                  final cell = rowCells[c];
                  final cellGrade = cell['grade'] as String?;
                  if (cellGrade != null && cellGrade != 'A') {
                    occupied.add(cellKey);
                    _annotations.add(AnnotationBox(
                      rect: Rect.fromLTWH(c * cellW, r * cellH, cellW, cellH),
                      className: '明暗片-$cellGrade级',
                      score: ((cell['diff_pct'] as num?)?.toDouble() ?? 0.0) / 100.0,
                      isManual: false,
                    ));
                    addedNew = true;
                  }
                }
              }
            });
            if (addedNew) {
              _toast('已将识别出的明暗片并入缺陷标注中');
            }
          }
        }
      }
    } catch (e) {
      _log('明暗片分析失败: $e');
    } finally {
      if (mounted) setState(() { _cellAnalyzing = false; });
    }
  }

  // ─── Build ───
  @override
  Widget build(BuildContext context) {
    final sf = _sf(context);
    final railW = _railWidth(context);
    final slidePanelW = _slidePanelWidth(context);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(sf),
      ),
      child: Scaffold(
      body: Stack(children: [
        Container(
          color: AppTheme.canvas,
          child: Row(children: [
            _buildRail(),
            Expanded(child: Column(children: [
              _buildTopBar(),
              Expanded(child: Padding(
                padding: _outerPadding(context),
                child: switch (_section) {
                  AppSection.project => _buildProjectPage(),
                  AppSection.model => _buildModelPage(),
                  _ => _buildStandardPage(),
                },
              )),
            ])),
          ]),
        ),
        // 持久进度条
        if (_progressVisible && _progressMessage != null)
          Positioned(
            left: railW, right: 0, bottom: 0,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 20 * sf, vertical: 10 * sf),
              decoration: const BoxDecoration(
                color: Color(0xFF0D2137),
                border: Border(top: BorderSide(color: Color(0xFF1E3A5F))),
              ),
              child: Row(children: [
                if (_working) ...[
                  SizedBox(width: 16 * sf, height: 16 * sf, child: CircularProgressIndicator(strokeWidth: 2 * sf, color: const Color(0xFF7DD3FC))),
                  SizedBox(width: 12 * sf),
                ],
                Expanded(child: Text(_progressMessage!, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w600))),
                IconButton(
                  icon: Icon(Icons.close, size: 16 * sf, color: const Color(0xFF94A3B8)),
                  onPressed: _hideProgress,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 24 * sf, minHeight: 24 * sf),
                ),
              ]),
            ),
          ),
        // ── 左侧滑出面板 ──
        if (_slidePanel != null) ...[
          // 半透明遮罩
          Positioned.fill(child: GestureDetector(
            onTap: () => setState(() => _slidePanel = null),
            child: Container(color: Colors.black.withValues(alpha: 0.35)),
          )),
          // 滑出面板
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: railW,
            top: 0,
            bottom: 0,
            width: slidePanelW,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1A2D),
                  border: const Border(right: BorderSide(color: Color(0xFF1E3A5F), width: 1.2)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24, offset: const Offset(4, 0)),
                  ],
                ),
                child: Column(children: [
                  // 面板标题栏
                  Container(
                    height: 46 * sf,
                    padding: EdgeInsets.symmetric(horizontal: 14 * sf),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFF1E3A5F))),
                    ),
                    child: Row(children: [
                      Icon(
                        _slidePanel == 'settings' ? Icons.tune_rounded : Icons.model_training_rounded,
                        color: const Color(0xFF7DD3FC), size: 20 * sf,
                      ),
                      SizedBox(width: 8 * sf),
                      Text(
                        _slidePanel == 'settings' ? '参数设置' : 'AI建模',
                        style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: const Color(0xFF94A3B8), size: 18 * sf),
                        onPressed: () => setState(() => _slidePanel = null),
                      ),
                    ]),
                  ),
                  // 面板内容
                  Expanded(child: switch (_slidePanel) {
                    'settings' => _buildSettingsSlide(),
                    'model' => _buildModelPage(),
                    _ => const SizedBox.shrink(),
                  }),
                ]),
              ),
            ),
          ),
        ],
      ]),
    ),
    );
  }

  Widget _buildRail() {
    final railW = _railWidth(context);
    final compact = _isCompact(context);
    final navH = _navBtnHeight(context);
    return Container(
      width: railW,
      decoration: const BoxDecoration(
        color: Color(0xFF000000),
        border: Border(right: BorderSide(color: AppTheme.stroke)),
      ),
      child: SafeArea(child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 6 : 10, 0, compact ? 6 : 10, compact ? 10 : 18),
        child: Column(children: [
          // 公司品牌区域
          SizedBox(height: compact ? 14 : 24),
          if (BrandingStore.instance.hasLogo)
            ClipRRect(
              borderRadius: BorderRadius.circular(compact ? 10 : 14),
              child: Image.file(File(BrandingStore.instance.logoLocalPath), width: compact ? 40 : 56, height: compact ? 40 : 56, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(Icons.business, color: const Color(0xFF7DD3FC), size: compact ? 32 : 44)),
            )
          else if (_logoUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(compact ? 10 : 14),
              child: Image.network(_logoUrl, width: compact ? 40 : 56, height: compact ? 40 : 56, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(Icons.business, color: const Color(0xFF7DD3FC), size: compact ? 32 : 44)),
            )
          else
            Icon(Icons.business, color: const Color(0xFF7DD3FC), size: compact ? 32 : 44),
          SizedBox(height: compact ? 6 : 10),
          Text(
            _displayName.isNotEmpty ? _displayName : 'EL',
            style: TextStyle(
              color: const Color(0xFFE6F0FF),
              fontSize: _displayName.isNotEmpty ? (compact ? 11 : 14) : (compact ? 20 : 28),
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (_displayName.isEmpty)
            Text('命令中心', style: TextStyle(color: const Color(0xFF7DD3FC), fontSize: compact ? 9 : 11)),
          SizedBox(height: compact ? 12 : 20),
          Expanded(child: ListView.separated(
            itemCount: _nav.length,
            separatorBuilder: (_, __) => SizedBox(height: compact ? 5 : 8),
            itemBuilder: (_, i) {
              final (s, icon, label) = _nav[i];
              final active = s == _section || (s == AppSection.settings && _slidePanel == 'settings');
              return _NavButton(
                icon: icon,
                label: label,
                active: active,
                index: i,
                height: navH,
                onTap: () {
                  if (s == AppSection.model) {
                    if (_files.isEmpty) {
                      setState(() {
                        _mapDataCache = [];
                        _section = AppSection.model;
                        _slidePanel = null;
                      });
                    } else {
                      _syncToMap();
                    }
                    return;
                  }
                  setState(() {
                    if (s == AppSection.settings) {
                      _slidePanel = _slidePanel == 'settings' ? null : 'settings';
                    } else {
                      _section = s;
                      _slidePanel = null;
                    }
                  });
                },
              );
            },
          )),
        ]),
      )),
    );
  }

  // ─── 公告通知功能 ───

  int get _unreadCount => _announcements.where((a) => !_readAnnouncementIds.contains(a['id'] as int)).length;

  Future<void> _initAnnouncements() async {
    final prefs = await SharedPreferences.getInstance();
    _lastAnnouncementTs = prefs.getInt('lastAnnouncementTs') ?? 0;
    final readIds = prefs.getStringList('readAnnouncementIds') ?? [];
    _readAnnouncementIds = readIds.map((e) => int.tryParse(e) ?? 0).where((e) => e > 0).toSet();
    await _fetchAnnouncements();
    _announcementTimer = Timer.periodic(const Duration(minutes: 5), (_) => _fetchAnnouncements());
  }

  Future<void> _fetchAnnouncements() async {
    try {
      final list = <dynamic>[];
      if (!mounted) return;
      // Check for new important announcements before merging
      final existingIds = _announcements.map((a) => a['id'] as int).toSet();
      final newImportant = list.where((a) =>
        !existingIds.contains(a['id'] as int) &&
        a['priority'] == 'important' &&
        !_readAnnouncementIds.contains(a['id'] as int)
      ).toList();

      setState(() {
        // Merge: keep existing, add new
        final allIds = <int>{};
        final merged = <Map<String, dynamic>>[];
        for (final a in list) {
          final id = a['id'] as int;
          if (allIds.add(id)) merged.add(a);
        }
        for (final a in _announcements) {
          final id = a['id'] as int;
          if (allIds.add(id)) merged.add(a);
        }
        merged.sort((a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int));
        _announcements = merged;
      });

      // Update timestamp
      if (list.isNotEmpty) {
        final maxTs = list.map((a) => a['created_at'] as int).reduce((a, b) => a > b ? a : b);
        if (maxTs > _lastAnnouncementTs) {
          _lastAnnouncementTs = maxTs;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('lastAnnouncementTs', _lastAnnouncementTs);
        }
      }

      // Auto-popup important announcements
      for (final ann in newImportant) {
        if (mounted) _showImportantAnnouncement(ann);
      }
    } catch (_) {
      // Silent fail - don't affect main functionality
    }
  }

  void _showImportantAnnouncement(Map<String, dynamic> ann) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2332),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.campaign_rounded, color: Color(0xFFFBBF24), size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text(ann['title'] ?? '', style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 16, fontWeight: FontWeight.w700))),
        ]),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFF0EA5E9).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(6)),
                child: Text(ann['type'] == 'release' ? '版本更新' : '常规通知', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11)),
              ),
              const SizedBox(width: 8),
              Text(_formatAnnouncementTime(ann['created_at'] as int? ?? 0), style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
            ]),
            const SizedBox(height: 12),
            Text(ann['content'] ?? '', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _markAsRead(ann['id'] as int);
              Navigator.pop(ctx);
            },
            child: const Text('我知道了', style: TextStyle(color: Color(0xFF7DD3FC))),
          ),
        ],
      ),
    );
  }

  Future<void> _markAsRead(int id) async {
    setState(() => _readAnnouncementIds.add(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('readAnnouncementIds', _readAnnouncementIds.map((e) => e.toString()).toList());
  }

  String _formatAnnouncementTime(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _showAnnouncementList() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A2332),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.notifications_rounded, color: Color(0xFF7DD3FC), size: 22),
            const SizedBox(width: 8),
            const Text('公告通知', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_unreadCount > 0)
              TextButton(
                onPressed: () async {
                  for (final a in _announcements) {
                    _readAnnouncementIds.add(a['id'] as int);
                  }
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setStringList('readAnnouncementIds', _readAnnouncementIds.map((e) => e.toString()).toList());
                  setState(() {});
                  setDialogState(() {});
                },
                child: const Text('全部已读', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
              ),
          ]),
          content: SizedBox(
            width: 480,
            height: 400,
            child: _announcements.isEmpty
                ? const Center(child: Text('暂无公告', style: TextStyle(color: Color(0xFF64748B))))
                : ListView.separated(
                    itemCount: _announcements.length,
                    separatorBuilder: (_, __) => Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                    itemBuilder: (ctx, i) {
                      final a = _announcements[i];
                      final id = a['id'] as int;
                      final isRead = _readAnnouncementIds.contains(id);
                      final isExpanded = _expandedAnnouncementId == id;
                      return InkWell(
                        onTap: () {
                          setDialogState(() {
                            _expandedAnnouncementId = isExpanded ? null : id;
                          });
                          if (!isRead) {
                            _markAsRead(id);
                            setDialogState(() {});
                            setState(() {});
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              if (!isRead)
                                Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 8),
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFEF4444))),
                              Expanded(child: Text(a['title'] ?? '', style: TextStyle(
                                color: isRead ? const Color(0xFF94A3B8) : const Color(0xFFE6F0FF),
                                fontSize: 13, fontWeight: isRead ? FontWeight.w400 : FontWeight.w600,
                              ))),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: a['type'] == 'release' ? const Color(0xFF0EA5E9).withValues(alpha: 0.15) : const Color(0xFF64748B).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(a['type'] == 'release' ? '版本更新' : '通知', style: TextStyle(
                                  color: a['type'] == 'release' ? const Color(0xFF7DD3FC) : const Color(0xFF94A3B8), fontSize: 10)),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            Text(_formatAnnouncementTime(a['created_at'] as int? ?? 0),
                              style: const TextStyle(color: Color(0xFF475569), fontSize: 11)),
                            if (isExpanded) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(a['content'] ?? '', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, height: 1.5)),
                              ),
                            ],
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭', style: TextStyle(color: Color(0xFF94A3B8)))),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final sectionLabel = _nav.firstWhere((e) => e.$1 == _section).$3;
    final compact = _isCompact(context);
    final sf = _sf(context);
    final topH = (compact ? 44.0 : 50.0) * sf;
    return Padding(
      padding: EdgeInsets.fromLTRB((compact ? 12 : 22) * sf, (compact ? 10 : 14) * sf, (compact ? 12 : 22) * sf, 0),
      child: SizedBox(
        height: topH,
        child: Stack(alignment: Alignment.center, children: [
          // 左：当前页面标题（左对齐）
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '当前：$sectionLabel',
              style: TextStyle(color: const Color(0xFFB7D4F5), fontSize: compact ? 14 : 17, fontWeight: FontWeight.w700),
            ),
          ),
          // 中：公司名称 + 系统标题（绝对居中）
          if (_displayName.isNotEmpty)
            Center(
              child: Text(
                '$_displayName  EL缺陷检测系统',
                style: TextStyle(
                  color: const Color(0xFFE2F0FF),
                  fontSize: compact ? 15 : 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.0,
                  shadows: [Shadow(color: Color(0x557DD3FC), blurRadius: 12)],
                ),
              ),
            ),
          // 右：状态 + 用户名（右对齐）
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _buildGpuChip(),
              SizedBox(width: 16 * sf),
            ]),
          ),
        ]),
      ),
    );
  }

  /// GPU / CPU 推理状态 chip（点击弹出诊断详情）
  Widget _buildGpuChip() {
    final status = _gpuStatus;
    final isGpu = status != null && status['inference_device'] == 'GPU';
    final allDepsOk = status != null && status['all_dependencies_ok'] == true;
    final Color color;
    final Color bg;
    final String label;
    final IconData icon;

    if (status == null) {
      // 尚未获取
      color = const Color(0xFF94A3B8);
      bg = const Color(0xFF1A2332);
      label = '检测中...';
      icon = Icons.hourglass_empty_rounded;
    } else if (isGpu) {
      color = const Color(0xFF3EEAA0);
      bg = const Color(0xFF052E2B);
      label = 'GPU 加速';
      icon = Icons.memory_rounded;
    } else {
      color = const Color(0xFFF59E0B);
      bg = const Color(0xFF2D2006);
      label = 'CPU 模式';
      icon = Icons.warning_amber_rounded;
    }

    return GestureDetector(
      onTap: _showGpuDiagDialog,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
            // 如果有缺失依赖，显示红色警告点
            if (status != null && !allDepsOk) ...[
              const SizedBox(width: 5),
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF87171),
                  boxShadow: [BoxShadow(color: const Color(0xFFF87171), blurRadius: 4)],
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// 实时服务器连接状态 chip（带呼吸灯）
  Widget _chip(String text, Color bg) {
    final sf = _sf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * sf, vertical: 6 * sf),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: AppTheme.stroke)),
      child: Text(text, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }

  Widget _buildStandardPage() {
    final title = switch (_section) {
      AppSection.workbench => 'EL检测主视图',
      AppSection.project => '项目信息总览区',
      _ => 'EL检测主视图',
    };
    final gap = _panelGap(context);
    return Row(children: [
      SizedBox(width: _leftPanelWidth(context), child: _leftPanel()),
      SizedBox(width: gap),
      Expanded(child: _centerPanel(title)),
      SizedBox(width: gap),
      SizedBox(width: _rightPanelWidth(context), child: _rightPanel()),
    ]);
  }

  // ─── 左侧面板 ───
  Widget _leftPanel() {
    final compact = _isCompact(context);
    final screenH = _screenH(context);
    final sp = compact ? 10.0 : (screenH * 0.016).clamp(12.0, 20.0); // section 间距（加大呼吸感）
    final pp = _panelPadding(context);
    final cardGap = compact ? 5.0 : (screenH * 0.007).clamp(6.0, 10.0); // 按钮行间距
    final sectionToCard = compact ? 6.0 : (screenH * 0.010).clamp(8.0, 14.0); // section标签到首行按钮间距
    return Container(
    padding: EdgeInsets.all(pp),
    decoration: BoxDecoration(color: AppTheme.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
    child: Column(children: [
      // 上半部分：功能控制台（弹性分配高度，超出可滚动）
      Expanded(flex: 3, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _header('功能控制台', ''),
      SizedBox(height: sp),

      // ── 文件操作 ──
      _sectionLabel('文件操作'),
      SizedBox(height: sectionToCard),
      Row(children: [
        Expanded(child: _detectCard2(
          id: 'pick_image', icon: Icons.image_outlined, label: '选择图像', subLabel: 'IMAGE',
          accentColor: const Color(0xFF60A5FA),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
          onTap: () => _pickImage(),
        )),
        const SizedBox(width: 5),
        Expanded(child: _detectCard2(
          id: 'pick_folder', icon: Icons.folder_open_outlined, label: '打开目录', subLabel: 'FOLDER',
          accentColor: const Color(0xFF38BDF8),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(18), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
          onTap: () => _pickFolder(),
        )),
      ]),
      SizedBox(height: cardGap),
      Row(children: [
        Expanded(child: _detectCard2(
          id: 'export_img', icon: Icons.photo_library_outlined, label: '导出图片', subLabel: 'EXPORT',
          accentColor: const Color(0xFFA78BFA),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
          onTap: () => _exportAnnotatedImages(),
        )),
        const SizedBox(width: 5),
        Expanded(child: _detectCard2(
          id: 'annot', icon: _showAnnot ? Icons.close : Icons.edit_outlined,
          label: _showAnnot ? '关闭标注' : '手动标注', subLabel: 'ANNOT',
          accentColor: _showAnnot ? const Color(0xFFF87171) : const Color(0xFF60A5FA),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
          onTap: () => setState(() { _showAnnot = !_showAnnot; if (!_showAnnot) _drawMode = false; }),
        )),
      ]),
      SizedBox(height: sp),

      // ── 导出报告 ──
      _sectionLabel('导出报告'),
      SizedBox(height: sectionToCard),
      Row(children: [
        Expanded(child: _detectCard2(
          id: 'export_word', icon: Icons.description_outlined, label: 'Word报告', subLabel: 'WORD',
          accentColor: const Color(0xFF38BDF8),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(8), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(8)),
          onTap: () => _showReportExportDialog('Word'),
        )),
        const SizedBox(width: 5),
        Expanded(child: _detectCard2(
          id: 'export_excel', icon: Icons.table_chart_outlined, label: 'Excel报告', subLabel: 'EXCEL',
          accentColor: const Color(0xFF4ADE80),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(18), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(18)),
          onTap: () => _showReportExportDialog('Excel'),
        )),
      ]),


      // ── 检测控制 ──
      _sectionLabel('检测控制'),
      SizedBox(height: sectionToCard),
      // 模式选择 — flip-switch 翻转卡片风格
      _FlipModeSwitch(
        value: _detectMode,
        onChanged: (v) async {
          if (v != _detectMode) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF0F172A),
                title: const Text('切换检测模式', style: TextStyle(color: Colors.white)),
                content: Text(
                  '切换到 ${v == 'segment' ? '图片分割' : '缺陷检测'} 模式将会清空当前全部已识别数据，是否继续？',
                  style: const TextStyle(color: Color(0xFF94A3B8)),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确定切换', style: TextStyle(color: Color(0xFFF87171))),
                  ),
                ],
              ),
            );
            if (confirm != true) return;
          }
          setState(() {
            _detectMode = v;
            _modelReady = false;
            _perImageResults.clear();
            _perImageAnnotations.clear();
            _annotations.clear();
            _single = null;
            // ★ 重置文件列表全部状态为“待检测”
            for (var j = 0; j < _files.length; j++) {
              _files[j] = (_files[j].$1, '待检测', _files[j].$3);
            }
            _batchNgCount = 0;
            _batchOkCount = 0;
            _batchProcessedCount = 0;
          });
          _saveSettings();
        },
      ),
      if (_detectMode == 'segment') ...[
        // 分割设置已移至主视图左侧悬浮面板
      ],
      SizedBox(height: cardGap),
      // ── 检测按钮组（圆角卡片自锁风格）──
      _detectCardGroup(),
      SizedBox(height: sp),

      // ── 辅助检测 ──
      _sectionLabel('辅助检测'),
      SizedBox(height: sectionToCard),
      _neuToggleRow(
        icon: Icons.grid_on,
        label: '明暗片判定',
        value: _cellBrightEnabled,
        onChanged: (v) { setState(() { _cellBrightEnabled = v; if (!v) _cellBrightResult = null; }); _saveSettings(); },
      ),
      ]))),
      // ── 底部区域（批量进度 + 日志，弹性缩放防止溢出）──
      Expanded(flex: 2, child: Column(children: [
        SizedBox(height: cardGap),
        Flexible(flex: 3, child: _BatchProgressCard(
          working: _working,
          current: _batchCurrentIdx,
          total: _batchTotalCount,
          ngCount: _batchNgCount,
          okCount: _batchOkCount,
          startTime: _batchStartTime,
          processedCount: _batchProcessedCount,
        )),
        // ── 终端日志（填充剩余空间）──
        SizedBox(height: compact ? 6 : 10),
        Flexible(flex: 2, child: _terminalLog()),
      ])),
    ]));
  }

  // ── 终端日志组件（仿 CSS terminal-loader 风格）──
  Widget _terminalLog() {
    // 简洁模式：截取前60字符；完整模式：显示全部
    final displayLogs = _showFullLogs ? _logs : _logs.map((l) {
      if (l.length > 60) return '${l.substring(0, 60)}…';
      return l;
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.stroke, width: 1),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: Column(children: [
        // 标题栏（与整体面板配色一致）
        Container(
          height: 28 * _sf(context),
          padding: EdgeInsets.symmetric(horizontal: 10 * _sf(context)),
          decoration: BoxDecoration(
            color: AppTheme.panel,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
            border: const Border(bottom: BorderSide(color: AppTheme.stroke)),
          ),
          child: Row(children: [
            Icon(Icons.terminal, size: 12 * _sf(context), color: const Color(0xFF7DD3FC)),
            SizedBox(width: 6 * _sf(context)),
            const Text('运行日志', style: TextStyle(color: Color(0xFFB7D4F5), fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
            const Spacer(),
            Container(width: 7 * _sf(context), height: 7 * _sf(context), margin: EdgeInsets.only(left: 5 * _sf(context)), decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFEE3333))),
            Container(width: 7 * _sf(context), height: 7 * _sf(context), margin: EdgeInsets.only(left: 5 * _sf(context)), decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFEEEE00))),
            Container(width: 7 * _sf(context), height: 7 * _sf(context), margin: EdgeInsets.only(left: 5 * _sf(context)), decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00BB00))),
          ]),
        ),
        // 日志内容
        Expanded(child: _logs.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Text('> ', style: TextStyle(color: const Color(0xFF7DD3FC).withValues(alpha: 0.7), fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w700)),
                _TerminalCursor(),
              ]),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              itemCount: displayLogs.length,
              itemBuilder: (_, i) {
                final log = displayLogs[i];
                final isError = log.contains('ERROR');
                final isWarn = log.contains('WARN');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('> ', style: TextStyle(
                      color: isError ? const Color(0xFFF87171) : isWarn ? const Color(0xFFFBBF24) : const Color(0xFF7DD3FC).withValues(alpha: 0.6),
                      fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.w700,
                    )),
                    Expanded(child: Text(log, style: TextStyle(
                      color: isError ? const Color(0xFFF87171) : isWarn ? const Color(0xFFFBBF24) : const Color(0xFFCBD5E1),
                      fontSize: 10, fontFamily: 'monospace', height: 1.3,
                    ))),
                  ]),
                );
              },
            ),
        ),
      ]),
    );
  }

  // ── 检测卡片按钮组（参考截图：上排当前/批量，下排暂停/停止）──
  Widget _detectCardGroup() {
    const cyan = Color(0xFF64FFDA);
    const green = Color(0xFF4ADE80);
    return Column(children: [
      // ── 上排：当前检测 + 批量检测 ──
      Row(children: [
        Expanded(child: _detectCard2(
          id: 'single',
          icon: Icons.play_arrow_rounded,
          label: _detectMode == 'segment' ? '当前分割' : '当前检测',
          subLabel: 'SINGLE',
          accentColor: green,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22), topRight: Radius.circular(10),
            bottomLeft: Radius.circular(10), bottomRight: Radius.circular(10),
          ),
          onTap: () async {
            setState(() => _lockedBtn = 'single');
            await _detectSingle();
            if (mounted) setState(() => _lockedBtn = null);
          },
        )),
        const SizedBox(width: 5),
        Expanded(child: _detectCard2(
          id: 'batch',
          icon: Icons.bar_chart_rounded,
          label: _detectMode == 'segment' ? '批量分割' : '批量检测',
          subLabel: 'BATCH',
          accentColor: cyan,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10), topRight: Radius.circular(22),
            bottomLeft: Radius.circular(10), bottomRight: Radius.circular(10),
          ),
          onTap: () async {
            setState(() => _lockedBtn = 'batch');
            await _detectBatch();
            if (mounted) setState(() => _lockedBtn = null);
          },
        )),
      ]),
      SizedBox(height: (MediaQuery.of(context).size.height * 0.007).clamp(5.0, 8.0)),
      // ── 下排：暂停 + 停止 ──
      Row(children: [
        Expanded(child: _detectCard2(
          id: 'pause',
          icon: _pauseCompleter != null ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: _pauseCompleter != null ? '恢复' : '暂停',
          subLabel: _pauseCompleter != null ? 'RESUME' : 'PAUSE',
          accentColor: _pauseCompleter != null ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10), topRight: Radius.circular(10),
            bottomLeft: Radius.circular(22), bottomRight: Radius.circular(10),
          ),
          enabled: _working,
          onTap: () {
            _pause();
            setState(() => _lockedBtn = null);
          },
        )),
        const SizedBox(width: 5),
        Expanded(child: _detectCard2(
          id: 'stop',
          icon: Icons.stop_rounded,
          label: '停止',
          subLabel: 'STOP',
          accentColor: const Color(0xFFF87171),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10), topRight: Radius.circular(10),
            bottomLeft: Radius.circular(10), bottomRight: Radius.circular(22),
          ),
          enabled: _working,
          onTap: () {
            _stop();
            setState(() => _lockedBtn = null);
          },
        )),
      ]),
    ]);
  }

  Widget _detectCard2({
    required String id,
    required IconData icon,
    required String label,
    required String subLabel,
    required Color accentColor,
    required BorderRadius borderRadius,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final isLocked = _lockedBtn == id;
    final isDisabled = !enabled && (id == 'pause' || id == 'stop');
    final canPress = !isDisabled && (id == 'pause' || id == 'stop' ? true : !_working || isLocked);
    final isBottom = id == 'pause' || id == 'stop';

    // subLabel 位置：大圆角所在角落
    final subAtLeft = id == 'single' || id == 'pause';
    final subAtTop = id == 'single' || id == 'batch';

    final isPressed = _pressedBtn == id;

    final cardH = isBottom ? _cardHeightSmall(context) : _cardHeight(context);

    return GestureDetector(
      onTapDown: canPress ? (_) => setState(() => _pressedBtn = id) : null,
      onTapUp: canPress ? (_) { setState(() => _pressedBtn = null); onTap(); } : null,
      onTapCancel: () => setState(() => _pressedBtn = null),
      child: AnimatedScale(
        scale: isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        height: cardH,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: isLocked
              ? LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [accentColor.withValues(alpha: 0.35), accentColor.withValues(alpha: 0.18)],
                )
              : isPressed
                  ? LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [accentColor.withValues(alpha: 0.22), accentColor.withValues(alpha: 0.10)],
                    )
                  : isDisabled
                      ? const LinearGradient(colors: [Color(0xFF111E2E), Color(0xFF0E1A28)])
                      : const LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Color(0xFF1E2D42), Color(0xFF172536)],
                    ),
          border: Border.all(
            color: isLocked
                ? accentColor.withValues(alpha: 0.60)
                : isPressed
                    ? accentColor.withValues(alpha: 0.50)
                    : isDisabled
                        ? const Color(0xFF1C2E42)
                        : accentColor.withValues(alpha: 0.35),
            width: isLocked ? 1.2 : isPressed ? 1.2 : 0.8,
          ),
          boxShadow: isLocked
              ? [
                  BoxShadow(color: accentColor.withValues(alpha: 0.30), blurRadius: 14, spreadRadius: 1),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4)),
                ]
              : isPressed
                  ? [
                      BoxShadow(color: accentColor.withValues(alpha: 0.25), blurRadius: 12, spreadRadius: 1),
                      BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 4, offset: const Offset(0, 2)),
                    ]
                  : [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Stack(children: [
          // subLabel 标签（角落位置）
          Positioned(
            left: subAtLeft ? 8 : null,
            right: subAtLeft ? null : 8,
            top: subAtTop ? 5 : null,
            bottom: subAtTop ? null : 5,
            child: Text(subLabel, style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.5,
              color: isLocked
                  ? accentColor.withValues(alpha: 0.85)
                  : isDisabled
                      ? accentColor.withValues(alpha: 0.35)
                      : accentColor.withValues(alpha: 0.55),
            )),
          ),
          // 主内容
          Center(child: isBottom
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: (cardH * 0.42).clamp(16.0, 24.0),
                  color: isLocked ? Colors.white : isDisabled ? Colors.white.withValues(alpha: 0.45) : Colors.white.withValues(alpha: 0.75),
                  shadows: isDisabled ? null : [Shadow(color: accentColor.withValues(alpha: 0.5), blurRadius: 8)],
                ),
              ])
            : Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: (cardH * 0.40).clamp(20.0, 34.0), height: (cardH * 0.40).clamp(20.0, 34.0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isLocked ? accentColor.withValues(alpha: 0.20) : Colors.transparent,
                    border: Border.all(
                      color: isLocked ? accentColor.withValues(alpha: 0.50) : accentColor.withValues(alpha: 0.25),
                      width: 1.2,
                    ),
                  ),
                  child: Icon(icon, size: (cardH * 0.26).clamp(12.0, 20.0),
                    color: isLocked ? Colors.white : accentColor.withValues(alpha: 0.80),
                  ),
                ),
                SizedBox(width: (cardH * 0.10).clamp(4.0, 8.0)),
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1, style: TextStyle(
                  fontSize: (cardH * 0.22).clamp(10.0, 15.0), fontWeight: FontWeight.w800, letterSpacing: 0.3,
                  color: isLocked ? Colors.white : isDisabled ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.80),
                  shadows: isLocked
                      ? [Shadow(color: accentColor.withValues(alpha: 0.4), blurRadius: 8)]
                      : null,
                ))),
              ]),
          ),
          // 锁定脉冲点
          if (isLocked)
            Positioned(top: 6, right: 6, child: Container(
              width: 7, height: 7,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: accentColor, blurRadius: 6, spreadRadius: 1),
                  BoxShadow(color: Colors.white.withValues(alpha: 0.7), blurRadius: 2),
                ],
              ),
            )),
        ]),
      ),
      ),
    );
  }

  // ── 辅助：section 标签 ──
  // ── 辅助：section 标签（带上方分隔线，增加层次感）──
  Widget _sectionLabel(String text) {
    final sf = _sf(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(height: 1, color: AppTheme.stroke.withValues(alpha: 0.4)),
      SizedBox(height: 8 * sf),
      Row(children: [
        Container(width: 3 * sf, height: 14 * sf, decoration: BoxDecoration(color: const Color(0xFF22D3EE), borderRadius: BorderRadius.circular(2))),
        SizedBox(width: 7 * sf),
        Text(text, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ]),
    ]);
  }

  // ── 辅助：带图标的文件操作按钮 ──
  Widget _iconBtn(IconData icon, String label, Color color, VoidCallback? onTap) {
    final sf = _sf(context);
    return SizedBox(
    height: 38 * sf,
    child: ElevatedButton.icon(
      icon: Icon(icon, size: 15 * sf),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: EdgeInsets.symmetric(horizontal: 8 * sf),
      ),
      onPressed: _working ? null : onTap,
    ),
  );
  }

  // ── 辅助：带图标的操作按钮（稍高，更有质感）──
  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback? onTap, {bool enabled = true}) {
    final active = enabled && !_working || (label == '暂停' || label == '停止');
    final sf = _sf(context);
    return SizedBox(
      height: 36 * sf,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: active ? color : color.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          elevation: active ? 2 : 0,
          shadowColor: color.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: EdgeInsets.symmetric(horizontal: 6 * sf),
        ),
        onPressed: (label == '暂停' || label == '停止') ? (enabled ? onTap : null) : (_working ? null : onTap),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 14 * sf),
          SizedBox(width: 5 * sf),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  // ── 辅助：NeuToggle 行（图标 + 标签 + toggle）──
  Widget _neuToggleRow({required IconData icon, required String label, required bool value, required ValueChanged<bool> onChanged}) {
    final sf = _sf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * sf, vertical: 3 * sf),
      decoration: BoxDecoration(
        color: value ? const Color(0xFF0A1E33) : AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: value ? const Color(0xFF1E4A6E) : AppTheme.stroke),
      ),
      child: Row(children: [
        Icon(icon, size: 12 * sf, color: value ? const Color(0xFF7DD3FC) : const Color(0xFF64748B)),
        SizedBox(width: 6 * sf),
        Expanded(child: Text(label, style: TextStyle(color: value ? const Color(0xFFCBD5E1) : const Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600))),
        _NeuToggle(value: value, onChanged: onChanged, size: 30 * sf),
      ]),
    );
  }

  // ── 辅助：明暗片参数行 ──
  Widget _cellParamRow() {
    Widget numField(String label, String val, ValueChanged<String> onChanged) => Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
      const SizedBox(width: 3),
      SizedBox(width: 32, height: 22, child: TextField(
        controller: TextEditingController(text: val),
        style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 10),
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.zero, enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF334155))), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF7DD3FC)))),
        onChanged: onChanged,
      )),
    ]);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF041023), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.stroke)),
      child: Column(children: [
        Row(children: [
          numField('行:', '$_cellRows', (v) { final n = int.tryParse(v); if (n != null && n > 0) { setState(() => _cellRows = n); _saveSettings(); if (_imagePath != null && !_working) _runCellBrightnessAnalysis(_imagePath!); } }),
          const SizedBox(width: 12),
          numField('列:', '$_cellCols', (v) { final n = int.tryParse(v); if (n != null && n > 0) { setState(() => _cellCols = n); _saveSettings(); if (_imagePath != null && !_working) _runCellBrightnessAnalysis(_imagePath!); } }),
          const Spacer(),
          InkWell(
            onTap: () { if (_imagePath != null && !_working) {
              _runCellBrightnessAnalysis(_imagePath!);
            } else if (_imagePath == null) _toast('请先加载图像'); },
            child: const Text('重算', style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 10, decoration: TextDecoration.underline)),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          numField('A(%):', '$_cellThresholdA', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdA = n); _saveSettings(); } }),
          const SizedBox(width: 8),
          numField('B:', '$_cellThresholdB', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdB = n); _saveSettings(); } }),
          const SizedBox(width: 8),
          numField('C:', '$_cellThresholdC', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdC = n); _saveSettings(); } }),
        ]),
      ]),
    );
  }

  // ── 图片分割设置悬浮面板（主视图左侧）──
  Widget _segmentSettingsFloating() {
    // ── 小型样式工具 ──
    const labelStyle = TextStyle(color: Color(0xFF94A3B8), fontSize: 10);
    const valueStyle = TextStyle(color: Color(0xFF7DD3FC), fontSize: 10, fontWeight: FontWeight.w600);
    const sectionTitleStyle = TextStyle(color: Color(0xFF64748B), fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2);
    final divider = Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: const Color(0xFF1E3A5F).withValues(alpha: 0.5));

    Widget miniNumInput(String hint, int value, ValueChanged<String> onChanged) {
      return SizedBox(width: 52, height: 26, child: TextField(
        controller: TextEditingController(text: value > 0 ? '$value' : ''),
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 10),
        decoration: InputDecoration(
          isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          hintText: hint, hintStyle: const TextStyle(color: Color(0xFF475569), fontSize: 9),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF334155))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF7DD3FC))),
        ),
        onChanged: onChanged,
      ));
    }

    return Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2137).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E4A6E)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(2, 4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── 标题 ──
        const Row(children: [
          Icon(Icons.auto_awesome_mosaic_outlined, size: 14, color: Color(0xFF7DD3FC)),
          SizedBox(width: 6),
          Text('分割设置', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),

        // ═══ 检测选项 ═══
        const Text('检测选项', style: sectionTitleStyle),
        const SizedBox(height: 4),
        _neuToggleRow(icon: Icons.crop_free, label: '忽略画面边缘', value: _filterEdges, onChanged: (v) { setState(() => _filterEdges = v); _saveSettings(); }),
        const SizedBox(height: 4),
        _neuToggleRow(icon: Icons.transform, label: '透视裁剪', value: _perspectiveCrop, onChanged: (v) { setState(() => _perspectiveCrop = v); _saveSettings(); }),
        const SizedBox(height: 4),
        _neuToggleRow(icon: Icons.auto_fix_high, label: '自动裁剪', value: _autoCrop, onChanged: (v) { setState(() => _autoCrop = v); _saveSettings(); }),

        divider,

        // ═══ 输出参数 ═══
        const Text('输出参数', style: sectionTitleStyle),
        const SizedBox(height: 6),
        // 外扩
        Row(children: [
          const SizedBox(width: 28, child: Text('外扩', style: labelStyle)),
          Expanded(child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: const Color(0xFF7DD3FC), inactiveTrackColor: const Color(0xFF1E293B),
              thumbColor: const Color(0xFF7DD3FC),
            ),
            child: Slider(value: _cropExpandPx, min: 0, max: 100, divisions: 100, onChanged: (v) { setState(() => _cropExpandPx = v); _saveSettings(); }),
          )),
          SizedBox(width: 32, child: Text('${_cropExpandPx.round()}px', style: valueStyle, textAlign: TextAlign.right)),
        ]),
        // 质量
        Row(children: [
          const SizedBox(width: 28, child: Text('质量', style: labelStyle)),
          Expanded(child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: const Color(0xFF7DD3FC), inactiveTrackColor: const Color(0xFF1E293B),
              thumbColor: const Color(0xFF7DD3FC),
            ),
            child: Slider(value: _cropQuality.toDouble(), min: 30, max: 100, divisions: 70, onChanged: (v) { setState(() => _cropQuality = v.round()); _saveSettings(); }),
          )),
          SizedBox(width: 32, child: Text('$_cropQuality%', style: valueStyle, textAlign: TextAlign.right)),
        ]),
        // 分辨率
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 0),
          child: Row(children: [
            const SizedBox(width: 38, child: Text('分辨率', style: labelStyle)),
            miniNumInput('宽', _cropResW, (v) { _cropResW = int.tryParse(v.trim()) ?? 0; _saveSettings(); }),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 3), child: Text('×', style: TextStyle(color: Color(0xFF475569), fontSize: 10))),
            miniNumInput('高', _cropResH, (v) { _cropResH = int.tryParse(v.trim()) ?? 0; _saveSettings(); }),
            const SizedBox(width: 3),
            const Text('px', style: TextStyle(color: Color(0xFF475569), fontSize: 8)),
          ]),
        ),

        divider,

        // ═══ 保存路径 ═══
        const Text('保存路径', style: sectionTitleStyle),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFF1E3A5F)),
            ),
            child: Row(children: [
              const Icon(Icons.folder_outlined, size: 11, color: Color(0xFF475569)),
              const SizedBox(width: 4),
              Expanded(child: Text(
                _cropSaveDir.isEmpty ? '默认（与源图同目录）' : _cropSaveDir,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 9), overflow: TextOverflow.ellipsis,
              )),
            ]),
          )),
          const SizedBox(width: 4),
          SizedBox(width: 36, height: 22, child: TextButton(
            onPressed: () async {
              final dir = await FilePicker.platform.getDirectoryPath();
              if (dir != null) { setState(() => _cropSaveDir = dir); _saveSettings(); }
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: const Color(0xFF1E293B),
              foregroundColor: const Color(0xFF7DD3FC),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            child: const Text('选择', style: TextStyle(fontSize: 9)),
          )),
        ]),

        divider,


        // 全部裁剪按钮
        SizedBox(
          width: double.infinity, height: 30,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.crop, size: 13),
            label: const Text('全部裁剪', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _annotations.isEmpty ? const Color(0xFF334155) : const Color(0xFF1D4ED8),
              foregroundColor: _annotations.isEmpty ? const Color(0xFF64748B) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: EdgeInsets.zero,
              elevation: _annotations.isEmpty ? 0 : 2,
            ),
            onPressed: (_working || _annotations.isEmpty) ? () {
              if (_annotations.isEmpty) _toast('请先点击图片分割按钮进行分割检测后才能使用裁剪功能');
            } : () async {
              if (!_modelReady) return _toast('请先加载分割模型');
              // 收集所有需要裁剪的文件（已分割的）
              final targets = <int>[];
              for (var i = 0; i < _files.length; i++) {
                if (_files[i].$2 == '已分割' || _files[i].$2 == 'NG' || _files[i].$2 == 'OK') {
                  targets.add(i);
                }
              }
              if (targets.isEmpty) return _toast('没有已检测/分割的图片可裁剪');
              _showProgress('正在批量裁剪 0/${targets.length}...');
              int doneCount = 0;
              int totalCrops = 0;
              await _run('批量裁剪', () async {
                for (final idx in targets) {
                  if (_stopRequested || !mounted) break;
                  final (name, _, fullPath) = _files[idx];
                  _updateProgress('批量裁剪 [${doneCount + 1}/${targets.length}] $name...');
                  try {
                    final r = await _api.segment(
                      imagePath: fullPath, filterEdges: _filterEdges,
                      autoCrop: true, perspectiveCrop: _perspectiveCrop,
                      expandPx: _cropExpandPx.round(), cropQuality: _cropQuality,
                      cropResW: _cropResW,
                      cropResH: _cropResH,
                      outputDir: _cropSaveDir.isNotEmpty ? _cropSaveDir : null,
                      relativeSubdir: _computeRelativeSubdir(fullPath),
                    );
                    final crops = (r['crops'] as List?) ?? [];
                    totalCrops += crops.length;
                    doneCount++;
                  } catch (e) {
                    _log('裁剪失败 $name: $e');
                  }
                }
                _updateProgress('批量裁剪完成: $doneCount 张图片，共 $totalCrops 张子图');
                _toast('批量裁剪完成！$doneCount 张 → $totalCrops 张子图');
              });
            },
          ),
        ),
        const SizedBox(height: 6),
        // 单张裁剪按钮
        SizedBox(
          width: double.infinity, height: 30,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.crop_free, size: 13),
            label: const Text('当前图片裁剪', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _annotations.isEmpty ? const Color(0xFF334155) : const Color(0xFF0F766E),
              foregroundColor: _annotations.isEmpty ? const Color(0xFF64748B) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: EdgeInsets.zero,
              elevation: _annotations.isEmpty ? 0 : 2,
            ),
            onPressed: (_working || _annotations.isEmpty) ? () {
              if (_annotations.isEmpty) _toast('请先点击图片分割按钮进行分割检测后才能使用裁剪功能');
            } : _cropCurrentImage,
          ),
        ),
      ]),
    );
  }


  /// 单张图片裁剪：对当前选中图片进行裁剪，保存到相同目录（覆盖已有）
  Future<void> _cropCurrentImage() async {
    if (_selectedFileIdx < 0 || _selectedFileIdx >= _files.length) {
      return _toast('请先选择一张图片');
    }
    final (name, _, fullPath) = _files[_selectedFileIdx];
    if (!_modelReady) return _toast('请先加载分割模型');

    // 收集当前图片的手动标注 quad 坐标（归一化坐标）
    List<List<List<double>>>? manualQuads;
    final annots = _perImageAnnotations[fullPath];
    if (annots != null && annots.isNotEmpty) {
      final quads = <List<List<double>>>[];
      for (final ann in annots) {
        if (ann.quad != null && ann.quad!.length >= 4) {
          quads.add(ann.quad!.map((p) => [p.dx, p.dy]).toList());
        } else {
          final r = ann.rect;
          quads.add([
            [r.left, r.top], [r.right, r.top],
            [r.right, r.bottom], [r.left, r.bottom],
          ]);
        }
      }
      if (quads.isNotEmpty) manualQuads = quads;
    }

    _showProgress('正在裁剪 $name...');
    await _run('单张裁剪', () async {
      try {
        final r = await _api.segment(
          imagePath: fullPath, filterEdges: _filterEdges,
          autoCrop: true, perspectiveCrop: _perspectiveCrop,
          expandPx: _cropExpandPx.round(), cropQuality: _cropQuality,
          cropResW: _cropResW,
          cropResH: _cropResH,
          outputDir: _cropSaveDir.isNotEmpty ? _cropSaveDir : null,
          relativeSubdir: _computeRelativeSubdir(fullPath),
          manualQuads: manualQuads,
        );
        final crops = (r['crops'] as List?) ?? [];
        _updateProgress('裁剪完成: $name → ${crops.length} 张子图');
        _toast('裁剪完成！$name → ${crops.length} 张子图');
      } catch (e) {
        _log('裁剪失败 $name: $e');
        _toast('裁剪失败: $e');
      }
    });
  }

  // ── 明暗片参数设置悬浮面板（主视图左侧）──
  Widget _cellBrightSettingsFloating() {
    Widget numField(String label, String val, ValueChanged<String> onChanged) => Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
      const SizedBox(width: 3),
      SizedBox(width: 32, height: 22, child: TextField(
        controller: TextEditingController(text: val),
        style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 10),
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.zero, enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF334155))), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF7DD3FC)))),
        onChanged: onChanged,
      )),
    ]);

    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2137).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E4A6E)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(2, 4)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.grid_on, size: 14, color: Color(0xFF7DD3FC)),
          const SizedBox(width: 6),
          const Expanded(child: Text('明暗片参数', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w800))),
          InkWell(
            onTap: () { if (_imagePath != null && !_working) {
              _runCellBrightnessAnalysis(_imagePath!);
            } else if (_imagePath == null) _toast('请先加载图像'); },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF1D4ED8), borderRadius: BorderRadius.circular(4)),
              child: const Text('重算', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        // 网格行列
        Row(children: [
          numField('行:', '$_cellRows', (v) { final n = int.tryParse(v); if (n != null && n > 0) { setState(() => _cellRows = n); _saveSettings(); if (_imagePath != null && !_working) _runCellBrightnessAnalysis(_imagePath!); } }),
          const SizedBox(width: 12),
          numField('列:', '$_cellCols', (v) { final n = int.tryParse(v); if (n != null && n > 0) { setState(() => _cellCols = n); _saveSettings(); if (_imagePath != null && !_working) _runCellBrightnessAnalysis(_imagePath!); } }),
        ]),
        const SizedBox(height: 8),
        // 阈值
        Row(children: [
          numField('A(%):', '$_cellThresholdA', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdA = n); _saveSettings(); } }),
          const SizedBox(width: 6),
          numField('B:', '$_cellThresholdB', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdB = n); _saveSettings(); } }),
          const SizedBox(width: 6),
          numField('C:', '$_cellThresholdC', (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() => _cellThresholdC = n); _saveSettings(); } }),
        ]),
        const SizedBox(height: 8),
        // 显示选项
        _neuToggleRow(
          icon: Icons.thermostat,
          label: '热力图',
          value: _cellHeatmap,
          onChanged: (v) { setState(() => _cellHeatmap = v); _saveSettings(); },
        ),
        const SizedBox(height: 4),
        _neuToggleRow(
          icon: Icons.text_fields,
          label: '数字标注',
          value: _cellTextLabels,
          onChanged: (v) { setState(() => _cellTextLabels = v); _saveSettings(); },
        ),
      ]),
    );
  }

  // ─── 中央面板（含图像+标注） ───
  Widget _centerPanel(String title) {
    return _panel(Column(children: [
      Row(children: [
        Text(title, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(width: 8),
        if (_working)
          const Text('任务执行中', style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 11, fontWeight: FontWeight.w700)),
        const Spacer(),
        if (_annotations.isNotEmpty)
          Text('标注框: ${_annotations.length}', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
      ]),
      const SizedBox(height: 10),
      Expanded(child: DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: _onDragDone,
        child: LayoutBuilder(builder: (ctx, constraints) {
        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        _previewCanvasWidth = canvasSize.width;
        _previewCanvasHeight = canvasSize.height;
        return Container(
          decoration: BoxDecoration(color: const Color(0xFF041023), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.stroke)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(children: [
              // ── 可缩放/平移内容（受 InteractiveViewer 变换影响）──
              Positioned.fill(
                child: GestureDetector(
                  onDoubleTap: _resetTransform,
                  child: InteractiveViewer(
                    transformationController: _transformCtrl,
                    panEnabled: !_working && !_drawMode,
                    scaleEnabled: !_working,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    boundaryMargin: EdgeInsets.zero,
                    child: Stack(children: [
                      // 图像显示
                      if (_imagePath != null)
                        Positioned.fill(child: Image.file(File(_imagePath!), key: ValueKey(_imagePath!), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Center(child: Text('图像加载失败', style: TextStyle(color: Color(0xFF94A3B8))))))
                      else
                        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.cloud_upload_outlined, size: 56, color: Color(0xFF334155).withValues(alpha: _isDragging ? 0.0 : 1.0)),
                          const SizedBox(height: 10),
                          Text('拖拽图片/文件夹到此处', style: TextStyle(color: Color(0xFF64748B).withValues(alpha: _isDragging ? 0.0 : 1.0), fontSize: 14, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text('或使用左侧按钮选择文件', style: TextStyle(color: Color(0xFF475569).withValues(alpha: _isDragging ? 0.0 : 1.0), fontSize: 11)),
                        ])),

                      // 标注框绘制层
                      Positioned.fill(child: GestureDetector(
                        onTapDown: (d) => _onAnnotTapDown(d.localPosition, canvasSize),
                        onDoubleTap: () {
                          // 多边形双击闭合（使用上一次记录的位置）
                          if (_polygonMode && _polygonPoints.length >= 3) _closePolygon();
                        },
                        onPanStart: (d) => _onAnnotPanStart(d.localPosition, canvasSize),
                        onPanUpdate: (d) => _onAnnotPanUpdate(d.localPosition, canvasSize),
                        onPanEnd: (_) => _onAnnotPanEnd(),
                        child: CustomPaint(
                          painter: _BoxPainter(boxes: _annotations, drawingRect: _drawingRect, imageAspectRatio: _imageAspectRatio, strokeWidth: _boxStrokeWidth, labelFontSize: _labelFontSize, showBoxes: _showBoxes, showLabels: _showLabels, showConfidence: _showConfidence, polygonPoints: _polygonPoints),
                          child: Container(color: Colors.transparent),
                        ),
                      )),

                      // 明暗片辅助线网格覆盖层
                      if (_cellBrightEnabled)
                        Positioned.fill(child: IgnorePointer(
                          child: CustomPaint(
                            painter: _GridOverlayPainter(
                              rows: _cellRows,
                              cols: _cellCols,
                              imageAspectRatio: _imageAspectRatio,
                              cells: _cellBrightResult != null
                                  ? (_cellBrightResult!['cells'] as List?)?.map(
                                      (row) => (row as List).map((c) => Map<String, dynamic>.from(c as Map)).toList()
                                    ).toList()
                                  : null,
                              showHeatmap: _cellHeatmap,
                              showText: _cellTextLabels,
                              edgeDisplayThresh: _edgeDisplayThresh,
                              threshA: _cellThresholdA,
                              threshB: _cellThresholdB,
                              threshC: _cellThresholdC,
                            ),
                            child: Container(color: Colors.transparent),
                          ),
                        )),
                    ]),
                  ),
                ),
              ),

              // ── 悬浮面板（不受 InteractiveViewer 变换影响）──

              // 明暗片分析中提示植片
              if (_cellAnalyzing)
                Positioned(right: 14, bottom: 14, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D2137).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF7DD3FC)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7DD3FC))),
                    SizedBox(width: 8),
                    Text('明暗片分析中...', style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 11)),
                  ]),
                )),

              // 明暗片分析结果评级标记
              if (_cellBrightEnabled && _cellBrightResult != null && !_cellAnalyzing)
                Positioned(right: 14, bottom: 14, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D2137).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade'] ?? 'A')),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.grid_on, size: 12, color: Color(0xFF7DD3FC)),
                    const SizedBox(width: 6),
                    Text('明暗片: ${_cellBrightResult!["summary"]?["overall_grade"] ?? "A"}类',
                      style: TextStyle(color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade'] ?? 'A'), fontSize: 11, fontWeight: FontWeight.w800)),
                  ]),
                )),

              // 状态标签
              Positioned(left: 12, top: 12, child: _chip(
                _single != null ? '检测完成 · ${_single!.total}个缺陷' : (_imagePath != null ? '已加载图像' : '待处理样本'),
                const Color(0xFF0B1A2D),
              )),

              // 手动标注悬浮面板
              if (_showAnnot)
                Positioned(right: 14, top: 14, child: _annotationPanel()),

              // ── 图片分割设置悬浮面板（主视图上方）──
              if (_detectMode == 'segment')
                Positioned(left: 14, top: 50, child: _segmentSettingsFloating()),

              // ── 明暗片参数设置悬浮面板（主视图上方）──
              if (_cellBrightEnabled)
                Positioned(left: _detectMode == 'segment' ? 268 : 14, top: 50, child: _cellBrightSettingsFloating()),

              // ── 拖拽文件悬停遮罩 ──
              if (_isDragging)
                Positioned.fill(child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF041023).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: const Color(0xFF22D3EE), width: 2),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF22D3EE).withValues(alpha: 0.12),
                        border: Border.all(color: const Color(0xFF22D3EE).withValues(alpha: 0.4), width: 1.5),
                      ),
                      child: const Icon(Icons.file_download_outlined, size: 36, color: Color(0xFF22D3EE)),
                    ),
                    const SizedBox(height: 14),
                    const Text('释放以加载文件', style: TextStyle(color: Color(0xFF22D3EE), fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('支持图片文件 (jpg/png/bmp/tif) 或文件夹', style: TextStyle(color: const Color(0xFF22D3EE).withValues(alpha: 0.6), fontSize: 11)),
                  ])),
                )),
            ]),
          ),
        );
      })),
    ),
    ]));
  }

  // ─── 标注悬浮面板 ───
  Widget _annotationPanel() {
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2137),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF22D3EE), width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 16)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.edit_note, color: Color(0xFF22D3EE), size: 18),
          const SizedBox(width: 6),
          const Expanded(child: Text('手动标注', style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 13, fontWeight: FontWeight.w900))),
          InkWell(onTap: () => setState(() { _showAnnot = false; _drawMode = false; _polygonMode = false; _polygonPoints.clear(); }), child: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 18)),
        ]),
        const Divider(color: AppTheme.stroke, height: 16),
        // 缺陷类别下拉 + 自定义输入
        const Text('缺陷类别', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: AppTheme.panelAlt, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.stroke)),
            child: Builder(builder: (_) {
              // 动态构建选项列表，确保当前自定义类别在列表中
              final opts = List<String>.from(_annotClassOptions);
              if (!opts.contains(_annotClass)) opts.add(_annotClass);
              return DropdownButton<String>(
                value: _annotClass,
                isExpanded: true,
                dropdownColor: const Color(0xFF0D2137),
                underline: const SizedBox(),
                style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
                items: opts.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) { if (v != null) setState(() => _annotClass = v); },
              );
            }),
          )),
        ]),
        const SizedBox(height: 6),
        // 自定义类别输入
        Row(children: [
          Expanded(child: SizedBox(
            height: 32,
            child: TextField(
              controller: _customClassCtrl,
              style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
              decoration: InputDecoration(
                hintText: '输入自定义类别...',
                hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF334155))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF22D3EE))),
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) {
                  setState(() => _annotClass = v.trim());
                  _customClassCtrl.clear();
                }
              },
            ),
          )),
          const SizedBox(width: 6),
          SizedBox(
            height: 32, width: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22D3EE), foregroundColor: Colors.black, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () {
                final v = _customClassCtrl.text.trim();
                if (v.isNotEmpty) {
                  setState(() => _annotClass = v);
                  _customClassCtrl.clear();
                  _toast('已设置类别: $v');
                } else {
                  _toast('请输入类别名称');
                }
              },
              child: const Text('应用', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        // 操作按钮
        Row(children: [
          Expanded(child: _annotBtn(
            _drawMode ? '停止绘制' : '新增框',
            _drawMode ? const Color(0xFFEF4444) : const Color(0xFF1D4ED8),
            Icons.add_box_outlined,
            () => setState(() { _drawMode = !_drawMode; _polygonMode = false; _polygonPoints.clear(); }),
          )),
          const SizedBox(width: 6),
          Expanded(child: _annotBtn(
            _polygonMode ? '停止绘制' : '多边形',
            _polygonMode ? const Color(0xFFEF4444) : const Color(0xFF7C3AED),
            Icons.pentagon_outlined,
            () => setState(() { _polygonMode = !_polygonMode; _drawMode = false; _polygonPoints.clear(); }),
          )),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: _annotBtn('删除', const Color(0xFF7F1D1D), Icons.delete_outline, _deleteSelected)),
          const SizedBox(width: 6),
          Expanded(child: _annotBtn('修改类别', const Color(0xFF0F766E), Icons.edit, _modifySelected)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _btn('保存标注', const Color(0xFF1D4ED8), () { _log('标注已保存 (${_annotations.length}个框)'); _toast('标注已保存'); })),
          const SizedBox(width: 6),
          Expanded(child: _btn('取消', const Color(0xFF334155), () => setState(() { _showAnnot = false; _drawMode = false; _polygonMode = false; _polygonPoints.clear(); }))),
        ]),
        if (_drawMode) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFF22D3EE).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: const Row(children: [
              Icon(Icons.info_outline, color: Color(0xFF22D3EE), size: 14),
              SizedBox(width: 6),
              Expanded(child: Text('在图像上拖拽绘制标注框', style: TextStyle(color: Color(0xFF22D3EE), fontSize: 11))),
            ]),
          ),
        ],
        if (_polygonMode) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFF7C3AED).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.info_outline, color: Color(0xFF7C3AED), size: 14),
              const SizedBox(width: 6),
              Expanded(child: Text(_polygonPoints.isEmpty ? '点击放置顶点，双击闭合多边形' : '已放置 ${_polygonPoints.length} 个顶点，双击闭合', style: const TextStyle(color: Color(0xFF7C3AED), fontSize: 11))),
            ]),
          ),
        ],
        if (_selectedIdx != null) ...[
          const SizedBox(height: 8),
          Text('已选中: ${_annotations[_selectedIdx!].className} (${_annotations[_selectedIdx!].isManual ? "手动" : "自动"})',
            style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ]),
    );
  }

  Widget _annotBtn(String text, Color color, IconData icon, VoidCallback onTap) => SizedBox(
    height: 32,
    child: ElevatedButton.icon(
      icon: Icon(icon, size: 14),
      label: Text(text, style: const TextStyle(fontSize: 11)),
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 8)),
      onPressed: onTap,
    ),
  );

  // ─── 右侧面板 ───
  // ─── 文件列表排序辅助 ───

  Widget _sortableHeader(String label, String column, {bool center = false}) {
    final isActive = _sortColumn == column;
    final arrow = isActive ? (_sortAscending ? ' ▲' : ' ▼') : '';
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_sortColumn == column) {
            if (!_sortAscending) {
              _sortColumn = null; // 第三次点击取消排序
            } else {
              _sortAscending = false;
            }
          } else {
            _sortColumn = column;
            _sortAscending = true;
          }
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Text(
          '$label$arrow',
          textAlign: center ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: isActive ? const Color(0xFF7DD3FC) : const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  List<int> _buildSortedIndices() {
    final indices = List<int>.generate(_files.length, (i) => i);
    if (_sortColumn == null) return indices;

    int Function(int, int) comparator;
    switch (_sortColumn) {
      case 'name':
        comparator = (a, b) => _files[a].$1.compareTo(_files[b].$1);
        break;
      case 'count':
        comparator = (a, b) {
          final ca = _perImageAnnotations[_files[a].$3]?.length ?? -1;
          final cb = _perImageAnnotations[_files[b].$3]?.length ?? -1;
          return ca.compareTo(cb);
        };
        break;
      case 'result':
        comparator = (a, b) {
          const order = {'NG': 0, '已分割': 1, 'OK': 2, '-': 3};
          final oa = order[_files[a].$2] ?? 3;
          final ob = order[_files[b].$2] ?? 3;
          return oa.compareTo(ob);
        };
        break;
      case 'grade':
        comparator = (a, b) {
          const order = {'C': 0, 'B': 1, 'A': 2, '': 3};
          final ga = _perImageGrades[_files[a].$3] ?? '';
          final gb = _perImageGrades[_files[b].$3] ?? '';
          final oa = order[ga] ?? 3;
          final ob = order[gb] ?? 3;
          return oa.compareTo(ob);
        };
        break;
      default:
        return indices;
    }
    indices.sort((a, b) => _sortAscending ? comparator(a, b) : comparator(b, a));
    return indices;
  }

  Widget _rightPanel() {
    final defects = _defects();
    final allClasses = _allDetectedClasses();
    final total = math.max(1, defects.values.fold<int>(0, (p, c) => p + c)); // 各缺陷图片数之和，占比合计100%
    final hasData = defects.isNotEmpty || allClasses.isNotEmpty;
    // 管理模式下显示所有已检测类别，否则显示当前图片统计
    final displayClasses = _classManageMode ? allClasses : defects;

    Widget defectRow(String name, int count, Color c) {
      final r = count / total;
      return Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 64, child: Text(name, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        SizedBox(width: 36, child: Text('$count', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w800))),
        const SizedBox(width: 8),
        Expanded(child: Container(
          height: 18,
          decoration: BoxDecoration(color: const Color(0xFF0A1E33), borderRadius: BorderRadius.circular(999), border: Border.all(color: AppTheme.stroke)),
          child: Stack(children: [
            FractionallySizedBox(widthFactor: r.clamp(0, 1).toDouble(), child: Container(decoration: BoxDecoration(color: c.withOpacity(0.4), borderRadius: BorderRadius.circular(999)))),
            Center(child: Text('${(r * 100).toStringAsFixed(1)}%', style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 9, fontWeight: FontWeight.w800))),
          ]),
        )),
      ]));
    }

    Widget manageRow(String name, int count, Color c) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF071726),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.stroke),
          ),
          child: Row(children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            Expanded(child: Text(name, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
            Text('$count', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            // 重命名按钮
            GestureDetector(
              onTap: () => _showRenameClassDialog(name),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D4ED8).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFF1D4ED8).withOpacity(0.5)),
                ),
                child: const Text('改名', style: TextStyle(color: Color(0xFF60A5FA), fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 4),
            // 删除按钮
            GestureDetector(
              onTap: () => _showDeleteClassDialog(name, count),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFDC2626).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFFDC2626).withOpacity(0.5)),
                ),
                child: const Text('删除', style: TextStyle(color: Color(0xFFF87171), fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      );
    }

    return Column(children: [
      // 明暗片分析摘要卡片
      if (_cellBrightEnabled && _cellBrightResult != null) ...[
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppTheme.panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade']), width: 1.5),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.grid_on, size: 14, color: Color(0xFF7DD3FC)),
              const SizedBox(width: 6),
              const Expanded(child: Text('明暗片分析结果', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w900))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade']).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade'])),
                ),
                child: Text(
                  '${_cellBrightResult!['summary']?['overall_grade'] ?? 'A'}类',
                  style: TextStyle(color: _gradeBadgeColor(_cellBrightResult!['summary']?['overall_grade']), fontSize: 12, fontWeight: FontWeight.w900),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            () {
              final s = _cellBrightResult!['summary'] as Map<String, dynamic>? ?? {};
              final total = (s['total_cells'] as num?)?.toInt() ?? 1;
              return Column(children: [
                _cellGradeRow('A 类 (≤$_cellThresholdA%)',  s['grade_A'] ?? 0, total, const Color(0xFF34D399)),
                _cellGradeRow('B 类 (≤$_cellThresholdB%)',  s['grade_B'] ?? 0, total, const Color(0xFFFBBF24)),
                _cellGradeRow('C 类 (≤$_cellThresholdC%)',  s['grade_C'] ?? 0, total, const Color(0xFFF97316)),
                _cellGradeRow('D 类 (>$_cellThresholdC%)',  s['grade_D'] ?? 0, total, const Color(0xFFEF4444)),
              ]);
            }(),
            const SizedBox(height: 6),
            Text(
              '网格: $_cellRows 行 × $_cellCols 列  基准灰度: ${_cellBrightResult!['global_ref']?.toStringAsFixed(1) ?? '-'}',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
            ),
          ]),
        ),
      ],
      // ─── A/B/C 等级实时统计 ───
      () {
        final totalDetected = _perImageGrades.length;
        if (totalDetected == 0) return const SizedBox.shrink();
        int gradeA = 0, gradeB = 0, gradeC = 0;
        int gradeOK = 0;
        for (final g in _perImageGrades.values) {
          if (g == 'OK') {
            gradeOK++;
          } else if (g == 'A') gradeA++;
          else if (g == 'B') gradeB++;
          else gradeC++;
        }
        Widget gradeStatRow(String label, int count, Color color) {
          final pct = totalDetected > 0 ? (count / totalDetected * 100) : 0.0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              SizedBox(width: 28, child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800))),
              const SizedBox(width: 4),
              SizedBox(width: 28, child: Text('$count', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 11, fontWeight: FontWeight.w700))),
              const SizedBox(width: 6),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: pct / 100,
                  backgroundColor: const Color(0xFF0F172A),
                  valueColor: AlwaysStoppedAnimation<Color>(color.withOpacity(0.7)),
                  minHeight: 6,
                ),
              )),
              const SizedBox(width: 6),
              SizedBox(width: 38, child: Text('${pct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: TextStyle(color: color.withOpacity(0.8), fontSize: 10, fontWeight: FontWeight.w600))),
            ]),
          );
        }
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppTheme.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('类别统计', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w900)),
              const Spacer(),
              Text('$totalDetected 张', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            gradeStatRow('OK', gradeOK, const Color(0xFF22D3EE)),
            gradeStatRow('A类', gradeA, const Color(0xFF34D399)),
            gradeStatRow('B类', gradeB, const Color(0xFFFBBF24)),
            gradeStatRow('C类', gradeC, const Color(0xFFF87171)),
          ]),
        );
      }(),
      // 实时缺陷统计 - 自适应高度
      Expanded(flex: 2, child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppTheme.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Row(children: [
              Text(
                _classManageMode ? '缺陷类别管理' : (_detectMode == 'segment' ? '组件数量统计' : '实时缺陷统计'),
                style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w900),
              ),
              if (!_classManageMode && _perImageResults.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('${_perImageResults.length} 张', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
              ],
            ])),
            // 管理模式切换按钮
            GestureDetector(
              onTap: () => setState(() => _classManageMode = !_classManageMode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _classManageMode
                      ? const Color(0xFF1D4ED8).withOpacity(0.3)
                      : const Color(0xFF0B2A4A),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: _classManageMode
                        ? const Color(0xFF60A5FA).withOpacity(0.6)
                        : AppTheme.stroke,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    _classManageMode ? Icons.close : Icons.tune,
                    size: 11,
                    color: _classManageMode ? const Color(0xFF60A5FA) : const Color(0xFF7DD3FC),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _classManageMode ? '退出管理' : '类别管理',
                    style: TextStyle(
                      color: _classManageMode ? const Color(0xFF60A5FA) : const Color(0xFF7DD3FC),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (_classManageMode) ...[
            // 管理模式：说明文字
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(color: const Color(0xFF071726), borderRadius: BorderRadius.circular(7), border: Border.all(color: AppTheme.stroke)),
              child: const Text('操作将应用于全部已检测图片', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
            ),
            const SizedBox(height: 8),
          ] else ...[
            Row(children: const [
              SizedBox(width: 64, child: Text('类别', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
              SizedBox(width: 36, child: Text('数值', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
              SizedBox(width: 8),
              Expanded(child: Text('占比', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
          ],
          Expanded(child: !hasData
            ? const Center(child: Text('暂无检测数据', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
            : displayClasses.isEmpty
              ? const Center(child: Text('暂无类别数据', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
              : SingleChildScrollView(child: Column(children: [
                  ...displayClasses.entries.map((e) {
                    final color = _BoxPainter._defaultColors[e.key.hashCode.abs() % _BoxPainter._defaultColors.length];
                    return _classManageMode
                        ? manageRow(e.key, e.value, color)
                        : defectRow(e.key, e.value, color);
                  }),
                ])),
          ),
        ]),
      )),
      const SizedBox(height: 8),
      // 文件列表 - 占满剩余空间
      Expanded(flex: 3, child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppTheme.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('文件列表', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w800))),
            Text('${_files.length} 张', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _sortableHeader('文件名', 'name')),
            SizedBox(width: 40, child: _sortableHeader('数量', 'count', center: true)),
            SizedBox(width: 36, child: _sortableHeader('等级', 'grade', center: true)),
            SizedBox(width: 42, child: _sortableHeader('结果', 'result', center: true)),
          ]),
          const SizedBox(height: 6),
          const Divider(color: AppTheme.stroke, height: 1),
          const SizedBox(height: 6),
          Expanded(child: _files.isEmpty
            ? const Center(child: Text('请打开目录或选择图像', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
            : Builder(builder: (_) {
                final sortedIndices = _buildSortedIndices();
                return ListView.builder(
                controller: _fileListScrollCtrl,
                itemExtent: 28.0,
                itemCount: sortedIndices.length,
                itemBuilder: (_, i) {
                  final origIdx = sortedIndices[i];
                  final (name, result, fullPath) = _files[origIdx];
                  final isSelected = origIdx == _selectedFileIdx;
                  final isDetected = result == 'NG' || result == 'OK' || result == '已分割';
                  final resultColor = (result == 'NG') ? const Color(0xFFF87171) : (result == 'OK' || result == '已分割') ? const Color(0xFF34D399) : const Color(0xFF64748B);
                  final nameColor = (result == 'NG') ? const Color(0xFFF87171) : (result == 'OK' || result == '已分割') ? const Color(0xFF34D399) : const Color(0xFFCBD5E1);
                  final count = _perImageAnnotations[fullPath]?.length ?? 0;

                  return InkWell(
                    onTap: () async {
                      // 1. 记录上一张图路径，保存其标注状态（仅非空时保存，防止覆盖有效缓存）
                      final previousPath = _imagePath;
                      setState(() {
                        if (previousPath != null && _annotations.isNotEmpty) {
                          _perImageAnnotations[previousPath] = List.from(_annotations);
                        }
                        _selectedFileIdx = origIdx;
                        _imagePath = fullPath;
                        _annotations.clear();
                        _selectedIdx = null;
                        _single = null;
                        _imageWidth = 0;
                        _imageHeight = 0;
                        _resetTransform();
                      });

                      // 2. 异步加载新图像尺寸
                      await _loadImageSize(fullPath);

                      // ★ 防止快速连点：如果在 await 期间用户已切到另一张图，则不恢复标注
                      if (!mounted || _imagePath != fullPath) return;

                      final cached = _perImageResults[fullPath];

                      // 3. 尺寸加载完成后，从缓存恢复标注框
                      setState(() {
                        _annotations.clear(); // ★ 确保干净
                        if (_perImageAnnotations.containsKey(fullPath)) {
                          _annotations.addAll(_perImageAnnotations[fullPath]!);
                          _single = cached;
                        } else if (cached != null) {
                          _single = cached;
                          final imgW = _imageWidth > 0 ? _imageWidth : 1.0;
                          final imgH = _imageHeight > 0 ? _imageHeight : 1.0;
                          for (final d in cached.detections) {
                            final ann = AnnotationBox(
                              rect: Rect.fromLTRB(d.x1 / imgW, d.y1 / imgH, d.x2 / imgW, d.y2 / imgH),
                              className: d.className,
                              score: d.score,
                              isManual: false,
                            );
                            if (!_isDuplicateAnnotation(_annotations, ann)) {
                                _annotations.add(ann);
                            }
                          }
                          _perImageAnnotations[fullPath] = List.from(_annotations);
                        } else {
                          _single = null;
                        }
                      });
                      // 仅对未检测的图片自动触发检测
                      if (cached == null && _perImageAnnotations[fullPath] == null && _modelReady) _detectSingle();
                      if (_cellBrightEnabled) _runCellBrightnessAnalysis(fullPath);
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF1D4ED8).withOpacity(0.2) : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: isSelected ? Border.all(color: const Color(0xFF1D4ED8).withOpacity(0.5)) : null,
                      ),
                      child: Row(children: [
                        if (isDetected)
                          Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: resultColor, shape: BoxShape.circle))
                        else
                          const SizedBox(width: 12),
                        Expanded(child: Text(name, style: TextStyle(color: nameColor, fontSize: 11.5, fontWeight: isDetected ? FontWeight.w700 : FontWeight.w400), overflow: TextOverflow.ellipsis)),
                        // 数量列
                        SizedBox(
                          width: 40,
                          child: Center(
                            child: Text(
                              isDetected ? '$count' : '-',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isDetected ? resultColor : const Color(0xFF94A3B8),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        // 等级列
                        SizedBox(
                          width: 36,
                          child: Center(
                            child: () {
                              final grade = _perImageGrades[fullPath];
                              if (grade == null || !isDetected) {
                                return const Text('-', style: TextStyle(color: Color(0xFF64748B), fontSize: 10));
                              }
                              final gradeColor = grade == 'A' ? const Color(0xFF34D399)
                                  : grade == 'B' ? const Color(0xFFFBBF24)
                                  : const Color(0xFFF87171);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: gradeColor.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: gradeColor.withOpacity(0.5), width: 0.8),
                                ),
                                child: Text(
                                  grade,
                                  style: TextStyle(color: gradeColor, fontSize: 10, fontWeight: FontWeight.w800),
                                ),
                              );
                            }(),
                          ),
                        ),
                        SizedBox(width: 42, child: Text(result, textAlign: TextAlign.center, style: TextStyle(color: resultColor, fontSize: 11, fontWeight: FontWeight.w800))),
                      ]),
                    ),
                  );
                },
              );
          }),),
          const Divider(color: AppTheme.stroke, height: 12),
        ]),
      )),
    ]);
  }

  /// 日志悬浮窗 - 从底部向上弹出
  void _showLogPopup(BuildContext ctx) {
    showDialog(
      context: ctx,
      barrierColor: Colors.black26,
      builder: (context) => Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 22, bottom: 80),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 300, height: 320,
              decoration: BoxDecoration(
                color: const Color(0xFF0D2137),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1E3A5F)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 24)],
              ),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
                  child: Row(children: [
                    const Icon(Icons.terminal, color: Color(0xFF7DD3FC), size: 16),
                    const SizedBox(width: 6),
                    const Expanded(child: Text('运行日志', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w900))),
                    Text('${_logs.length} 条', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                    IconButton(icon: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)), onPressed: () => Navigator.pop(context)),
                  ]),
                ),
                const Divider(color: AppTheme.stroke, height: 1),
                Expanded(child: _logs.isEmpty
                  ? const Center(child: Text('暂无日志', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(10),
                      itemCount: _logs.length,
                      itemBuilder: (_, i) {
                        final log = _logs[i];
                        final isError = log.contains('ERROR');
                        final isWarn = log.contains('WARN');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(log, style: TextStyle(
                            color: isError ? const Color(0xFFF87171) : isWarn ? const Color(0xFFFBBF24) : const Color(0xFF94A3B8),
                            fontSize: 11, fontFamily: 'monospace',
                          )),
                        );
                      },
                    ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ─── History UI Panels ───

  // 选中的项目记录索引（用于导出）
  int _selectedProjectIdx = -1;
  int _selectedDetectionIdx = -1;

  Widget _buildSavedProjectsPanel() {
    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.history, color: Color(0xFF7DD3FC), size: 18),
                const SizedBox(width: 8),
                const Text('已保存项目信息 (点击选中 · ✏ 编辑)', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.bold)),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _projectInfoData = {};
                      _selectedProjectIdx = -1;
                      _isProjectFormOpen = true;
                    });
                  },
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('新增项目'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.stroke),
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : _historyList.isEmpty
                    ? const Center(child: Text('暂无历史记录', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _historyList.length,
                        itemBuilder: (_, i) {
                          final item = _historyList[i];
                          final selected = i == _selectedProjectIdx;
                          final name = item['项目名称']?.toString() ?? item['project_name']?.toString() ?? '未命名项目';
                          final time = item['display_time']?.toString() ?? '';
                          final totalImg = item['total_images'] ?? 0;
                          final ngImg = item['ng_images'] ?? 0;
                          final okImg = item['ok_images'] ?? 0;
                          final defectTotal = item['defect_total'] ?? 0;
                          final component = item['组件编号']?.toString() ?? item['component_id']?.toString() ?? '';
                          final inspector = item['检验员']?.toString() ?? item['inspector']?.toString() ?? '';
                          final reportNo = item['报告编号']?.toString() ?? item['report_no']?.toString() ?? '';
                          final client = item['委托单位']?.toString() ?? '';
                          final testUnit = item['检测单位']?.toString() ?? '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  setState(() {
                                    if (selected) {
                                      _selectedProjectIdx = -1;
                                      _projectInfoData = {};
                                    } else {
                                      _selectedProjectIdx = i;
                                      _projectInfoData = Map<String, dynamic>.from(item);
                                    }
                                  });
                                  if (!selected) _toast('已选中项目: $name，将用于导出报告');
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: selected ? const Color(0xFF0C2D48) : const Color(0xFF0F172A).withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: selected ? const Color(0xFF22D3EE) : const Color(0xFF1E293B),
                                      width: selected ? 1.5 : 1,
                                    ),
                                    boxShadow: selected ? [
                                      BoxShadow(color: const Color(0xFF22D3EE).withValues(alpha: 0.15), blurRadius: 12, spreadRadius: 1),
                                    ] : null,
                                  ),
                                  child: Row(
                                    children: [
                                      // 选中指示器
                                      AnimatedContainer(
                                        duration: const Duration(milliseconds: 200),
                                        width: 3,
                                        height: 32,
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          color: selected ? const Color(0xFF22D3EE) : const Color(0xFF334155),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      // 图标
                                      Icon(
                                        selected ? Icons.check_circle : Icons.folder_outlined,
                                        size: 18,
                                        color: selected ? const Color(0xFF22D3EE) : const Color(0xFF475569),
                                      ),
                                      const SizedBox(width: 8),
                                      // 项目信息（横向紧凑布局）
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // 第一行：名称 + 统计数据（横向）
                                            Row(children: [
                                              Text(name,
                                                style: TextStyle(
                                                  color: selected ? const Color(0xFF22D3EE) : const Color(0xFFCBD5E1),
                                                  fontSize: 12,
                                                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Text('图片:$totalImg', style: TextStyle(color: selected ? const Color(0xFF7DD3FC) : const Color(0xFF64748B), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('NG:$ngImg', style: TextStyle(color: ngImg > 0 ? (selected ? const Color(0xFFFBBF24) : const Color(0xFFB45309)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('OK:$okImg', style: TextStyle(color: okImg > 0 ? (selected ? const Color(0xFF34D399) : const Color(0xFF047857)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('缺陷:$defectTotal', style: TextStyle(color: defectTotal > 0 ? (selected ? const Color(0xFFF87171) : const Color(0xFFB91C1C)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                            ]),
                                            const SizedBox(height: 3),
                                            // 第二行：编号 + 委托 + 检测 + 组件 + 检验员 + 日期（横向）
                                            Row(children: [
                                              if (reportNo.isNotEmpty) ...[
                                                Text('编号:$reportNo', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                                const SizedBox(width: 6),
                                              ],
                                              if (client.isNotEmpty) ...[
                                                Text('委托:$client', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                                const SizedBox(width: 6),
                                              ],
                                              if (testUnit.isNotEmpty) ...[
                                                Text('检测:$testUnit', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                                const SizedBox(width: 6),
                                              ],
                                              if (component.isNotEmpty) ...[
                                                Text('组件:$component', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                                const SizedBox(width: 6),
                                              ],
                                              if (inspector.isNotEmpty) ...[
                                                Text('检验员:$inspector', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                                const SizedBox(width: 6),
                                              ],
                                              Icon(Icons.access_time, size: 9, color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
                                              const SizedBox(width: 2),
                                              Expanded(
                                                child: Text(time.isNotEmpty ? time : '未记录', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10), overflow: TextOverflow.ellipsis),
                                              ),
                                            ]),
                                          ],
                                        ),
                                      ),
                                      // 操作按钮
                                      IconButton(
                                        icon: Icon(Icons.edit_outlined, size: 16, color: selected ? const Color(0xFF7DD3FC) : const Color(0xFF475569)),
                                        tooltip: '编辑项目',
                                        onPressed: () {
                                          setState(() {
                                            _selectedProjectIdx = i;
                                            _projectInfoData = Map<String, dynamic>.from(item);
                                            _isProjectFormOpen = true;
                                          });
                                          _toast('正在编辑: $name');
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete_outline, size: 16, color: selected ? const Color(0xFFEF4444) : const Color(0xFF475569)),
                                        tooltip: '删除项目',
                                        onPressed: () => _deleteHistoryItem(i),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectionHistoryPanel() {
    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.analytics_outlined, color: Color(0xFF7DD3FC), size: 18),
              const SizedBox(width: 8),
              const Text('历史检测记录', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('${_detectionHistoryList.length} 条', style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
            ]),
          ),
          const Divider(height: 1, color: AppTheme.stroke),
          Expanded(
            child: _isLoadingHistory
                ? const SizedBox()
                : _detectionHistoryList.isEmpty
                    ? const Center(child: Text('暂无数据', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _detectionHistoryList.length,
                        itemBuilder: (_, i) {
                          final item = _detectionHistoryList[i];
                          final selected = i == _selectedDetectionIdx;
                          final typeStr = item['type'] == 'batch' ? '批量检测' : '单张检测';
                          final totalImg = item['total_images'] ?? 0;
                          final ngImg = item['ng_images'] ?? 0;
                          final okImg = item['ok_images'] ?? 0;
                          final defectTotal = item['defect_total'] ?? 0;
                          final time = item['display_time'] ?? '';
                          final defectByClass = item['defect_by_class'];
                          // 构建缺陷分布文字
                          String defectDetail = '';
                          if (defectByClass is Map && defectByClass.isNotEmpty) {
                            defectDetail = defectByClass.entries.map((e) => '${e.key}:${e.value}').join(' · ');
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  setState(() => _selectedDetectionIdx = selected ? -1 : i);
                                  if (!selected) _toast('已选中检测记录');
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: selected ? const Color(0xFF0C2D48) : const Color(0xFF0F172A).withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: selected ? const Color(0xFF22D3EE) : const Color(0xFF1E293B),
                                      width: selected ? 1.5 : 1,
                                    ),
                                    boxShadow: selected ? [
                                      BoxShadow(color: const Color(0xFF22D3EE).withValues(alpha: 0.15), blurRadius: 12, spreadRadius: 1),
                                    ] : null,
                                  ),
                                  child: Row(
                                    children: [
                                      // 选中指示器
                                      AnimatedContainer(
                                        duration: const Duration(milliseconds: 200),
                                        width: 3,
                                        height: 32,
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          color: selected ? const Color(0xFF22D3EE) : const Color(0xFF334155),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      // 图标
                                      Icon(
                                        selected ? Icons.check_circle : Icons.analytics_outlined,
                                        size: 18,
                                        color: selected ? const Color(0xFF22D3EE) : const Color(0xFF475569),
                                      ),
                                      const SizedBox(width: 8),
                                      // 检测信息（横向紧凑布局）
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // 第一行：类型 + 统计数据 + 时间（全横向）
                                            Row(children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: item['type'] == 'batch'
                                                      ? const Color(0xFF1D4ED8).withValues(alpha: 0.3)
                                                      : const Color(0xFF0F766E).withValues(alpha: 0.3),
                                                  borderRadius: BorderRadius.circular(3),
                                                ),
                                                child: Text(typeStr, style: TextStyle(
                                                  color: selected ? const Color(0xFF7DD3FC) : const Color(0xFF94A3B8),
                                                  fontSize: 10, fontWeight: FontWeight.w600,
                                                )),
                                              ),
                                              const SizedBox(width: 8),
                                              Text('$totalImg张', style: TextStyle(color: selected ? const Color(0xFF7DD3FC) : const Color(0xFF64748B), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('NG:$ngImg', style: TextStyle(color: ngImg > 0 ? (selected ? const Color(0xFFFBBF24) : const Color(0xFFB45309)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('OK:$okImg', style: TextStyle(color: okImg > 0 ? (selected ? const Color(0xFF34D399) : const Color(0xFF047857)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                              const SizedBox(width: 6),
                                              Text('缺陷:$defectTotal', style: TextStyle(color: defectTotal > 0 ? (selected ? const Color(0xFFF87171) : const Color(0xFFB91C1C)) : (selected ? const Color(0xFF64748B) : const Color(0xFF475569)), fontSize: 10)),
                                              const Spacer(),
                                              Text(time, style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10)),
                                            ]),
                                            const SizedBox(height: 3),
                                            // 第二行：缺陷类别分布
                                            Text(defectDetail.isNotEmpty ? '类别: $defectDetail' : '无缺陷分布数据', style: TextStyle(color: selected ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 10), overflow: TextOverflow.ellipsis),
                                          ],
                                        ),
                                      ),
                                      // 删除按钮
                                      IconButton(
                                        icon: Icon(Icons.delete_outline, size: 16, color: selected ? const Color(0xFFEF4444) : const Color(0xFF475569)),
                                        onPressed: () => _deleteDetectionHistoryItem(i),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteDetectionHistoryItem(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('删除检测记录', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 16)),
        content: const Text('确定要删除这条检测记录吗？', style: TextStyle(color: Color(0xFF94A3B8))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Color(0xFFEF4444)))),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _detectionHistoryList.removeAt(index);
      if (_selectedDetectionIdx == index) {
        _selectedDetectionIdx = -1;
      } else if (_selectedDetectionIdx > index) {
        _selectedDetectionIdx--;
      }
    });

    try {
      final file = File(_detectionHistoryFilePath);
      if (_detectionHistoryList.isEmpty) {
        if (file.existsSync()) file.deleteSync();
      } else {
        await file.writeAsString(json.encode(_detectionHistoryList));
      }
      _toast('记录已删除');
    } catch (e) {
      _toast('删除失败: $e');
    }
  }

  /// 合并选中的项目记录和检测记录用于导出
  Map<String, dynamic> _buildExportData() {
    // 只在明确选中项目时使用项目信息，否则从空 Map 开始
    final data = _selectedProjectIdx >= 0
        ? Map<String, dynamic>.from(_projectInfoData)
        : <String, dynamic>{};
    // 始终使用当前检测数据（_files 列表）
    final stats = _collectAutoStats();
    data.addAll(stats);

    // 判断当前 file_results 是否有实际检测数据
    bool hasRealDetections(List? results) {
      if (results == null || results.isEmpty) return false;
      return results.any((f) => f is Map && f['result'] != '待检测' && f['result'] != null && f['result'] != '');
    }

    // 如果当前 _files 无实际检测数据，尝试从历史记录中恢复 file_results
    final currentFileResults = data['file_results'] as List?;
    if (!hasRealDetections(currentFileResults) && _selectedProjectIdx >= 0 && _selectedProjectIdx < _historyList.length) {
      final hist = _historyList[_selectedProjectIdx];
      final savedResults = hist['file_results'];
      if (savedResults is List && savedResults.isNotEmpty) {
        data['file_results'] = savedResults;
        data['total_images'] = hist['total_images'] ?? savedResults.length;
        data['ng_images'] = hist['ng_images'] ?? 0;
        data['ok_images'] = hist['ok_images'] ?? 0;
        data['defect_total'] = hist['defect_total'] ?? 0;
        data['defect_by_class'] = hist['defect_by_class'] ?? {};
        _log('使用历史记录中的file_results: ${savedResults.length}条');
      }
    }

    // 如果选中了检测记录，用检测记录的统计数据和file_results覆盖
    if (_selectedDetectionIdx >= 0 && _selectedDetectionIdx < _detectionHistoryList.length) {
      final det = _detectionHistoryList[_selectedDetectionIdx];
      data['total_images'] = det['total_images'] ?? 0;
      data['ng_images'] = det['ng_images'] ?? 0;
      data['ok_images'] = det['ok_images'] ?? 0;
      data['defect_total'] = det['defect_total'] ?? 0;
      // 始终使用检测记录中的 file_results（含标注框和缺陷数据）
      final detFileResults = det['file_results'];
      if (detFileResults is List && detFileResults.isNotEmpty) {
        data['file_results'] = detFileResults;
        data['defect_by_class'] = det['defect_by_class'] ?? {};
        _log('使用检测记录中的file_results: ${detFileResults.length}条');
      }
    }
    _log('导出数据: file_results=${(data['file_results'] as List?)?.length ?? 0}条, total_images=${data['total_images']}, ng=${data['ng_images']}');

    // ─── 添加 A/B/C 等级统计 ───
    int gradeA = 0, gradeB = 0, gradeC = 0;
    
    // ─── 辅助函数：从 detections 数据计算等级 ───
    String calcGradeFromDetections(List? detections) {
      if (detections == null || detections.isEmpty) return 'OK';
      
      // 统计各类缺陷数量
      final defectCounts = <String, int>{};
      for (final d in detections) {
        if (d is Map) {
          final className = d['class_name']?.toString() ?? d['className']?.toString() ?? '';
          if (className.isNotEmpty) {
            defectCounts[className] = (defectCounts[className] ?? 0) + 1;
          }
        }
      }
      
      if (defectCounts.isEmpty) return 'OK';
      
      // 构建配置查找表
      final Map<String, Map<String, dynamic>> configMap = {};
      for (final cfg in _defectGradingConfig) {
        configMap[cfg['name'] as String] = cfg;
      }
      
      _log('等级计算: defectCounts=$defectCounts, configKeys=${configMap.keys.toList()}');
      
      const gradeOrder = {'A': 0, 'B': 1, 'C': 2};
      String worstGrade = 'A';
      int worstLevel = 99;
      
      for (final entry in defectCounts.entries) {
        final clsName = entry.key;
        final count = entry.value;
        
        final thisGrade = _getGradeForDefect(clsName, count);
        int thisLevel = 0;
        
        Map<String, dynamic>? cfg = configMap[clsName];
        if (cfg == null) {
          // 模糊匹配
          for (final cfgEntry in configMap.entries) {
            if (cfgEntry.key.contains(clsName) || clsName.contains(cfgEntry.key)) {
              cfg = cfgEntry.value;
              _log('  模糊匹配: $clsName -> ${cfgEntry.key}');
              break;
            }
          }
        }
        thisLevel = (cfg?['level'] as num?)?.toInt() ?? 99;
        
        if ((gradeOrder[thisGrade] ?? 0) > (gradeOrder[worstGrade] ?? 0)) {
          worstGrade = thisGrade;
          worstLevel = thisLevel;
        } else if ((gradeOrder[thisGrade] ?? 0) == (gradeOrder[worstGrade] ?? 0)) {
          if (thisLevel < worstLevel) {
            worstLevel = thisLevel;
          }
        }
      }
      
      _log('  等级结果: $worstGrade');
      return worstGrade;
    }
    
    // 为每个 file_result 添加/修复 grade 字段，并统计 A/B/C 数量
    final fileResults = data['file_results'] as List?;
    if (fileResults != null) {
      for (final fr in fileResults) {
        if (fr is Map<String, dynamic>) {
          final path = fr['path'] as String? ?? '';
          
          // 优先使用已有的 grade 字段
          String? existingGrade;
          final rawGrade = fr['grade']?.toString() ?? '';
          _log('历史记录原始grade: path=$path, grade=$rawGrade');
          if (rawGrade.isNotEmpty) {
            final g = rawGrade.toUpperCase();
            if (g == 'A' || g == 'B' || g == 'C' || g == 'OK') {
              existingGrade = g;
              _log('  使用现有grade: $existingGrade');
            } else {
              _log('  grade无效: $g');
            }
          }
          
          // 尝试从缓存获取等级
          String? cachedGrade = _perImageGrades[path];
          
          // 如果缓存中没有，尝试从内存检测结果重新计算
          String? calculatedGrade;
          if (cachedGrade == null && existingGrade == null && path.isNotEmpty) {
            final cached = _perImageResults[path];
            if (cached != null && cached.detections.isNotEmpty) {
              calculatedGrade = _classifyImageGrade(path);
            }
          }
          
          // 如果缓存也没有，尝试从历史记录的 detections 数据计算等级
          String? historyGrade;
          if (cachedGrade == null && existingGrade == null && calculatedGrade == null) {
            final histDetections = fr['detections'] as List?;
            if (histDetections != null && histDetections.isNotEmpty) {
              historyGrade = calcGradeFromDetections(histDetections);
              _log('历史记录等级计算: path=$path, detections=${histDetections.length}个, grade=$historyGrade');
            } else {
              _log('历史记录无 detections: path=$path, defect_total=${fr['defect_total']}');
            }
          }
          
          // 确定最终等级
          // 优先使用历史记录的等级，但如果历史记录是 'OK' 且 detections 有数据，需要重新计算
          String? finalGradeCandidate = existingGrade ?? cachedGrade ?? calculatedGrade ?? historyGrade;
          
          String finalGrade;
          if (finalGradeCandidate != null && finalGradeCandidate != 'OK') {
            // 有明确的等级（非 OK），直接使用
            finalGrade = finalGradeCandidate;
          } else {
            // 等级为 OK 或空，需要检查 detections 是否有数据
            final histDetections = fr['detections'] as List?;
            final hasDetections = histDetections != null && histDetections.isNotEmpty;
            if (hasDetections && (finalGradeCandidate == null || finalGradeCandidate == 'OK')) {
              // detections 有数据但等级是 OK，需要重新计算
              finalGrade = calcGradeFromDetections(histDetections);
              _log('等级修正(OK->重新计算): path=$path, old=$finalGradeCandidate, new=$finalGrade');
            } else {
              finalGrade = finalGradeCandidate ?? 'OK';
            }
          }
          
          // 修正：如果没有缺陷但等级是 A/B/C，需要改为 OK
          final hasDefects = (fr['defect_total'] ?? 0) > 0;
          final detections = fr['detections'] as List?;
          final hasDetections = detections != null && detections.isNotEmpty;
          if (!hasDefects && !hasDetections && (finalGrade == 'A' || finalGrade == 'B' || finalGrade == 'C')) {
            finalGrade = 'OK';
          }
          
          fr['grade'] = finalGrade;
          
          // 统计 A/B/C 数量
          if (finalGrade == 'A') gradeA++;
          else if (finalGrade == 'B') gradeB++;
          else if (finalGrade == 'C') gradeC++;
          // 'OK' 不参与 A/B/C 分级统计
          
          // 调试日志
          _log('图片等级判定: name=${fr['name']}, finalGrade=$finalGrade, defect_total=${fr['defect_total']}');
        }
      }
    }
    
    data['grade_a_count'] = gradeA;
    data['grade_b_count'] = gradeB;
    data['grade_c_count'] = gradeC;
    
    // 调试日志
    _log('_buildExportData 等级统计: A=$gradeA, B=$gradeB, C=$gradeC (总计=${gradeA + gradeB + gradeC})');
    _log('历史记录来源: ${_selectedDetectionIdx >= 0 ? "检测记录" : (_selectedProjectIdx >= 0 ? "项目记录" : "当前数据")}');
    _log('file_results 条目数: ${(data['file_results'] as List?)?.length ?? 0}');

    return data;
  }

  Widget _buildExportButtonsPanel() {
    final hasProject = _selectedProjectIdx >= 0 || _projectInfoData.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.file_download_outlined, color: Color(0xFF7DD3FC), size: 18),
            SizedBox(width: 8),
            Text('导出报告', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          Text(
            _selectedProjectIdx >= 0 && _selectedProjectIdx < _historyList.length
                ? '项目: ${_historyList[_selectedProjectIdx]['项目名称'] ?? '未命名'}'
                : '提示: 点击上方项目记录选中后导出',
            style: TextStyle(color: _selectedProjectIdx >= 0 && _selectedProjectIdx < _historyList.length ? const Color(0xFF34D399) : const Color(0xFF64748B), fontSize: 11),
          ),
          if (_selectedDetectionIdx >= 0 && _selectedDetectionIdx < _detectionHistoryList.length)
            Text('检测: ${_detectionHistoryList[_selectedDetectionIdx]['display_time'] ?? ''}', style: const TextStyle(color: Color(0xFF34D399), fontSize: 11)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _btnAlways('Word', const Color(0xFF1D4ED8), () {
              _showReportExportDialog('Word');
            }, enabled: hasProject)),
            const SizedBox(width: 8),
            Expanded(child: _btnAlways('自定义模板渲染', const Color(0xFFD97706), () async {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['docx'],
                  dialogTitle: '选择带有标签的模板 (.docx)',
                );
                if (result != null && result.files.single.path != null) {
                  Navigator.push(context, MaterialPageRoute(builder: (_) {
                    return NativeWordEditorPage(
                      initialData: _projectInfoData,
                      templatePath: result.files.single.path!,
                      serverUrl: _backendCtrl.text.trim(),
                    );
                  }));
                }
            }, enabled: hasProject)),
            const SizedBox(width: 8),
            Expanded(child: _btnAlways('Excel', const Color(0xFF0F766E), () {
              _showReportExportDialog('Excel');
            }, enabled: hasProject)),
          ]),
        ],
      ),
    );
  }

  // ─── 项目信息页 ───
    Widget _buildModelPage() {
    return AiModelPage(
      initialMapData: _mapDataCache,
      serverUrl: _backendCtrl.text.trim(),
    );
  }

  Widget _buildProjectPage() {
    // Merge auto-collected stats into the persistent data
    final stats = _collectAutoStats();
    _projectInfoData.addAll(stats);

    return Stack(
      children: [
        // Base layer: History Panels + Export Buttons
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildSavedProjectsPanel()),
                      const SizedBox(width: 16),
                      Expanded(child: _buildDetectionHistoryPanel()),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _buildExportButtonsPanel(),
                const SizedBox(height: 50),
              ],
            ),
          ),
        ),

        // Top Layer (Slide-out Form)
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          left: _isProjectFormOpen ? 0 : -1000,
          width: 1000,
          child: Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              boxShadow: _isProjectFormOpen ? [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(10, 0))
              ] : null,
            ),
            child: ProjectInfoPanel(
              initialProjectInfo: _projectInfoData,
              autoSaveDir: _dataDir,
              onClose: () => setState(() => _isProjectFormOpen = false),
              onInfoChanged: (data) {
                 _projectInfoData = data;
              },
              onSaveProject: (data) async {
                 _projectInfoData = data; // Update local state
                 await _saveHistoryItem(data);
                 setState(() => _isProjectFormOpen = false); // auto-close on save
              },
            ),
          ),
        ),
      ],
    );
  }

  // Define _collectAutoStats to get live counts (defects, images, etc.) without relying on text controllers
  Map<String, dynamic> _collectAutoStats() {
    final defects = _defects();
    return {
      'stroke_width': _boxStrokeWidth.round(),
      'font_size': _labelFontSize.round(),
      'show_boxes': _showBoxes,
      'show_labels': _showLabels,
      'show_confidence': _showConfidence,
      'preview_canvas_width': _previewCanvasWidth,
      'preview_canvas_height': _previewCanvasHeight,
      'defect_classes': defects.length,
      'defect_total': defects.values.fold<int>(0, (p, c) => p + c),
      'defect_by_class': defects,
      // 每种缺陷类型的 A/B/C 等级图片数量统计
      'defect_grade_breakdown': () {
        final breakdown = <String, Map<String, int>>{};
        for (final entry in _perImageResults.entries) {
          final det = entry.value;
          
          final defectCounts = <String, int>{};
          for (final d in det.detections) {
            defectCounts[d.className] = (defectCounts[d.className] ?? 0) + 1;
          }

          // 为每种缺陷类型计入对应真实的独自分离 A/B/C 等级
          for (final dtype in defectCounts.keys) {
            final cnt = defectCounts[dtype]!;
            final defectGrade = _getGradeForDefect(dtype, cnt);
            breakdown.putIfAbsent(dtype, () => {'A': 0, 'B': 0, 'C': 0, 'total': 0});
            breakdown[dtype]![defectGrade] = (breakdown[dtype]![defectGrade] ?? 0) + 1;
            breakdown[dtype]!['total'] = (breakdown[dtype]!['total'] ?? 0) + 1;
          }
        }
        return breakdown;
      }(),
      'total_images': _files.length,
      'ng_images': _files.where((f) => f.$2 == 'NG').length,
      'ok_images': _files.where((f) => f.$2 == 'OK').length,
      'file_results': _files.map((f) {
        final path = f.$3;
        final det = _perImageResults[path];
        // 构建每张图片的缺陷详情
        final defectCounts = <String, int>{};
        if (det != null) {
          for (final d in det.detections) {
            defectCounts[d.className] = (defectCounts[d.className] ?? 0) + 1;
          }
        }
        return {
          'name': f.$1,
          'result': f.$2,
          'path': path,
          'visualization_path': det?.visualizationPath ?? '',
          'detections': det?.detections.map((d) => d.toJson()).toList() ?? const [],
          'defect_counts': defectCounts,
          'defect_total': det?.total ?? 0,
          // 与 _saveDetectionRecord 保持一致：如果没有缓存的等级，则重新计算
          'grade': _perImageGrades[path] ?? _classifyImageGrade(path),
        };
      }).toList(),
    };
  }

  // ─── History Persistence (JSON file) ───

  /// 检测历史文件路径
  String get _detectionHistoryFilePath {
    return '$_dataDir${Platform.pathSeparator}detection_history.json';
  }

  /// 断点续存检查点文件路径
  String get _checkpointFilePath => '$_dataDir${Platform.pathSeparator}batch_checkpoint.json';

  /// 保存当前批量检测进度到检查点文件
  Future<void> _saveCheckpoint({
    required int ngCount,
    required int okCount,
    required Map<String, int> defectByClass,
  }) async {
    try {
      final checkpoint = {
        'folderPath': _folderPath,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'ngCount': ngCount,
        'okCount': okCount,
        'defectByClass': defectByClass,
        'files': _files.map((f) => {
          'name': f.$1,
          'status': f.$2,
          'path': f.$3,
        }).toList(),
        'perImageResults': Map.fromEntries(
          _perImageResults.entries.map((e) => MapEntry(e.key, e.value.toJson())),
        ),
      };
      await File(_checkpointFilePath).writeAsString(json.encode(checkpoint));
    } catch (e) {
      _log('保存检查点失败: $e', level: 'WARN');
    }
  }

  /// 清除检查点文件
  Future<void> _clearCheckpoint() async {
    try {
      final f = File(_checkpointFilePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 检查是否有未完成的检查点，若有则弹框询问是否恢复
  /// 返回 true 表示已恢复（调用方应跳过重新扫描目录）
  Future<bool> _loadCheckpoint(String folderPath) async {
    try {
      final f = File(_checkpointFilePath);
      if (!await f.exists()) return false;
      final data = json.decode(await f.readAsString()) as Map<String, dynamic>;
      final savedFolder = data['folderPath'] as String?;
      if (savedFolder != folderPath) return false;

      // 统计已完成数量
      final fileList = (data['files'] as List<dynamic>? ?? []);
      final doneCount = fileList.where((e) => (e as Map)['status'] == 'NG' || e['status'] == 'OK').length;
      final totalCount = fileList.length;
      if (doneCount == 0) return false;

      // 弹出确认对话框
      if (!mounted) return false;
      final resume = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF0B1A2D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF0B2A4A), width: 1),
          ),
          title: Row(children: [
            const Icon(Icons.restore_rounded, color: Color(0xFF7DD3FC), size: 22),
            const SizedBox(width: 8),
            const Text('发现未完成的检测任务', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          content: Text(
            '上次批量检测中断，已完成 $doneCount / $totalCount 张。\n是否从断点继续？',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 14, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('重新开始', style: TextStyle(color: Colors.white.withValues(alpha: 0.50))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E3A5F),
                foregroundColor: const Color(0xFF7DD3FC),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续检测'),
            ),
          ],
        ),
      );

      if (resume != true) {
        await _clearCheckpoint();
        return false;
      }

      // 恢复状态
      final restoredFiles = fileList.map<(String, String, String)>((e) {
        final m = e as Map<String, dynamic>;
        return (m['name'] as String, m['status'] as String, m['path'] as String);
      }).toList();

      final restoredResults = <String, DetectResult>{};
      final rawResults = data['perImageResults'] as Map<String, dynamic>? ?? {};
      for (final entry in rawResults.entries) {
        try {
          restoredResults[entry.key] = DetectResult.fromJson(entry.value as Map<String, dynamic>);
        } catch (_) {}
      }

      setState(() {
        _files = restoredFiles;
        _perImageResults.addAll(restoredResults);
        _selectedFileIdx = -1;
      });
      _log('已恢复断点: $doneCount/$totalCount 张已完成');
      return true;
    } catch (e) {
      _log('加载检查点失败: $e', level: 'WARN');
      return false;
    }
  }

  String get _historyFilePath {
    return '$_dataDir${Platform.pathSeparator}project_history.json';
  }

  /// 数据存储目录
  String? _dataDirCache;
  String get _dataDir {
    if (_dataDirCache != null) return _dataDirCache!;
    final exe = Platform.resolvedExecutable;
    if (exe.contains('flutter') || exe.contains('dart')) {
      // 开发模式：使用当前工作目录
      final dir = Directory('${Directory.current.path}${Platform.pathSeparator}data');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dataDirCache = dir.path;
    } else {
      // Release模式：使用 AppData\Local\ELDefectSystem\data（避免 Program Files 权限问题）
      final localAppData = Platform.environment['LOCALAPPDATA'];
      final String base;
      if (localAppData != null && localAppData.isNotEmpty) {
        base = '$localAppData${Platform.pathSeparator}ELDefectSystem';
      } else {
        base = File(exe).parent.path;
      }
      final dir = Directory('$base${Platform.pathSeparator}data');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dataDirCache = dir.path;
    }
    return _dataDirCache!;
  }

  // ─── Settings Persistence ───
  String get _settingsFilePath => '$_dataDir${Platform.pathSeparator}app_settings.json';

  Future<void> _loadSettings() async {
    try {
      final file = File(_settingsFilePath);
      if (await file.exists()) {
        final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
        setState(() {
          _conf = (data['conf'] as num?)?.toDouble() ?? 0.55;
          _iou = (data['iou'] as num?)?.toDouble() ?? 0.45;
          _boxStrokeWidth = (data['boxStrokeWidth'] as num?)?.toDouble() ?? 1.8;
          _labelFontSize = (data['labelFontSize'] as num?)?.toDouble() ?? 11.0;
          _showBoxes = data['showBoxes'] as bool? ?? true;
          _showLabels = data['showLabels'] as bool? ?? true;
          _showConfidence = data['showConfidence'] as bool? ?? true;
          _rotateExportImages = data['rotateExportImages'] as bool? ?? false;
          _wordRotateExportImages = data['wordRotateExportImages'] as bool? ?? false;
          _wordImgWidthCm = (data['wordImgWidthCm'] as num?)?.toDouble() ?? 10.0;
          _wordImgHeightCm = (data['wordImgHeightCm'] as num?)?.toDouble() ?? 5.0;
          _wordImgQuality = (data['wordImgQuality'] as num?)?.toInt() ?? 85;
          _wordImageFilter = data['wordImageFilter'] as String? ?? 'all';
          _excelCols = (data['excelCols'] as num?)?.toInt() ?? 10;
          _cuda = data['cuda'] as bool? ?? true;
          _fp16 = data['fp16'] as bool? ?? true;
          _nms = data['nms'] as bool? ?? true;
          _cellBrightEnabled = data['cellBrightEnabled'] as bool? ?? false;
          _cellRows = data['cellRows'] as int? ?? 6;
          _cellCols = data['cellCols'] as int? ?? 10;
          _cellThresholdA = (data['cellThresholdA'] as num?)?.toDouble() ?? 15.0;
          _cellThresholdB = (data['cellThresholdB'] as num?)?.toDouble() ?? 30.0;
          _cellThresholdC = (data['cellThresholdC'] as num?)?.toDouble() ?? 50.0;
          _edgeDisplayThresh = (data['edgeDisplayThresh'] as num?)?.toDouble() ?? 5.0;
          _cellHeatmap = data['cellHeatmap'] as bool? ?? true;
          _cellTextLabels = data['cellTextLabels'] as bool? ?? true;
          _detectMode = data['detectMode'] as String? ?? 'defect';
          _filterEdges = data['filterEdges'] as bool? ?? true;
          _defectModelPath = data['defectModelPath'] as String?;
          _segmentModelPath = data['segmentModelPath'] as String?;
          // 加载缺陷等级配置
          final savedGrading = data['defectGradingConfig'] as List?;
          if (savedGrading != null && savedGrading.isNotEmpty) {
            _defectGradingConfig = savedGrading.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          }
        });
        _log('已恢复上次设置参数');
      }
    } catch (e) {
      _log('加载设置失败: $e', level: 'WARN');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final data = {
        'conf': _conf, 'iou': _iou,
        'boxStrokeWidth': _boxStrokeWidth, 'labelFontSize': _labelFontSize,
        'showBoxes': _showBoxes, 'showLabels': _showLabels, 'showConfidence': _showConfidence,
        'rotateExportImages': _rotateExportImages,
        'imgWidthCm': _imgWidthCm, 'imgHeightCm': _imgHeightCm, 'imgQuality': _imgQuality,
        'wordRotateExportImages': _wordRotateExportImages,
        'wordImgWidthCm': _wordImgWidthCm, 'wordImgHeightCm': _wordImgHeightCm, 'wordImgQuality': _wordImgQuality,
        'wordImageFilter': _wordImageFilter,
        'excelCols': _excelCols,
        'cuda': _cuda, 'fp16': _fp16, 'nms': _nms,
        'cellBrightEnabled': _cellBrightEnabled,
        'cellRows': _cellRows,
        'cellCols': _cellCols,
        'cellThresholdA': _cellThresholdA,
        'cellThresholdB': _cellThresholdB,
        'cellThresholdC': _cellThresholdC,
        'edgeDisplayThresh': _edgeDisplayThresh,
        'cellHeatmap': _cellHeatmap,
        'cellTextLabels': _cellTextLabels,
        'detectMode': _detectMode,
        'filterEdges': _filterEdges,
        'defectModelPath': _defectModelPath,
        'segmentModelPath': _segmentModelPath,
        'defectGradingConfig': _defectGradingConfig,
      };
      await File(_settingsFilePath).writeAsString(json.encode(data));
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      final file = File(_historyFilePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> decoded = json.decode(content);
        setState(() {
          _historyList = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        });
      }
      // 加载检测历史
      final dFile = File(_detectionHistoryFilePath);
      if (await dFile.exists()) {
        final content = await dFile.readAsString();
        final List<dynamic> decoded = json.decode(content);
        setState(() {
          _detectionHistoryList = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        });
      }
    } catch (e) {
      _log('加载历史记录失败: $e (路径: $_historyFilePath)', level: 'ERROR');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _saveHistoryItem(Map<String, dynamic> data) async {
    try {
      final now = DateTime.now();
      final timeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);
      final item = Map<String, dynamic>.from(data);
      item['display_time'] = timeStr;
      item['saved_at'] = now.millisecondsSinceEpoch;

      // Merge auto stats (includes file_results)
      item.addAll(_collectAutoStats());

      // Prepend to list (newest first)
      setState(() => _historyList.insert(0, item));

      // Persist - serialize file_results as simple list for JSON compatibility
      final file = File(_historyFilePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(json.encode(_historyList));
      _log('项目信息已保存: ${data['项目名称'] ?? data['project_name'] ?? '未命名'} -> ${file.path}');
      _toast('项目信息已保存');
    } catch (e) {
      _log('保存项目信息失败: $e (路径: $_historyFilePath)', level: 'ERROR');
      _toast('保存失败: $e');
    }
  }

  Future<void> _deleteHistoryItem(int index) async {
    if (index < 0 || index >= _historyList.length) return;
    final name = _historyList[index]['项目名称'] ?? _historyList[index]['project_name'] ?? '未命名';
    setState(() {
      _historyList.removeAt(index);
      // 修复索引关系
      if (_selectedProjectIdx == index) {
        _selectedProjectIdx = -1;
        _projectInfoData = {};
      } else if (_selectedProjectIdx > index) {
        _selectedProjectIdx--;
      }
    });
    try {
      final file = File(_historyFilePath);
      await file.writeAsString(json.encode(_historyList));
      _log('已删除历史记录: $name');
      _toast('已删除: $name');
    } catch (e) {
      _log('删除历史记录失败: $e', level: 'ERROR');
    }
  }

  /// 保存检测记录（检测完成后自动调用）
  Future<void> _saveDetectionRecord({
    required String type, // 'single' or 'batch'
    required int totalImages,
    required int ngCount,
    required int okCount,
    required int defectTotal,
    String? fileName,
  }) async {
    // 图片分割模式的检测记录不要显示到检测历史记录内
    if (_detectMode == 'segment') return;
    try {
      final now = DateTime.now();
      final timeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);
      final projName = _projectInfoData['项目名称']?.toString() ?? _projectInfoData['project_name']?.toString() ?? '';
      final record = <String, dynamic>{
        'display_time': timeStr,
        'saved_at': now.millisecondsSinceEpoch,
        'type': type,
        '项目名称': projName,
        'stroke_width': _boxStrokeWidth.round(),
        'font_size': _labelFontSize.round(),
        'show_boxes': _showBoxes,
        'show_labels': _showLabels,
        'show_confidence': _showConfidence,
        'preview_canvas_width': _previewCanvasWidth,
        'preview_canvas_height': _previewCanvasHeight,
        'total_images': totalImages,
        'ng_images': ngCount,
        'ok_images': okCount,
        'defect_total': defectTotal,
        'file_name': fileName ?? '',
        'defect_by_class': _defects(),
        'file_results': _files.map((f) {
          final path = f.$3;
          final det = _perImageResults[path];
          final defectCounts = <String, int>{};
          if (det != null) {
            for (final d in det.detections) {
              defectCounts[d.className] = (defectCounts[d.className] ?? 0) + 1;
            }
          }
          return {
            'name': f.$1,
            'result': f.$2,
            'path': path,
            'visualization_path': det?.visualizationPath ?? '',
            'detections': det?.detections.map((d) => d.toJson()).toList() ?? const [],
            'defect_counts': defectCounts,
            'defect_total': det?.total ?? 0,
            'grade': _perImageGrades[path] ?? _classifyImageGrade(path),
          };
        }).toList(),
      };
      setState(() => _detectionHistoryList.insert(0, record));
      final file = File(_detectionHistoryFilePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(json.encode(_detectionHistoryList));
      _log('检测记录已保存: ${file.path}');
    } catch (e) {
      _log('保存检测记录失败: $e (路径: $_detectionHistoryFilePath)', level: 'ERROR');
    }
  }

  Future<void> _handlePanelExport(Map<String, dynamic> data) async {
    // File Picker
    final projName = data['项目名称']?.toString() ?? data['project_name']?.toString() ?? 'EL检测报告';
    String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存 Word 报告',
      fileName: '${projName.isNotEmpty ? projName : "EL检测报告"}.docx',
      allowedExtensions: ['docx'],
      type: FileType.custom,
    );

    if (savePath == null) return;
    if (!savePath.toLowerCase().endsWith('.docx')) {
      savePath += '.docx';
    }

    // 使用传入的 data（已经由 _buildExportData 处理好了）
    final exportData = Map<String, dynamic>.from(data);
    // 不再重复调用 _collectAutoStats()，_buildExportData 已经处理好了数据合并
    exportData['rotate_images'] = _wordRotateExportImages;
    exportData['img_width_cm'] = _wordImgWidthCm;
    exportData['img_height_cm'] = _wordImgHeightCm;
    exportData['img_quality'] = _wordImgQuality;
    exportData['image_filter'] = _wordImageFilter;
    exportData['stroke_width'] = _boxStrokeWidth.round();
    exportData['font_size'] = _labelFontSize.round();
    exportData['show_boxes'] = _showBoxes;
    exportData['show_labels'] = _showLabels;
    exportData['show_confidence'] = _showConfidence;
    exportData['preview_canvas_width'] = _previewCanvasWidth;
    exportData['preview_canvas_height'] = _previewCanvasHeight;

    // 过滤掉 "待检测" 文件，只导出已检测的文件
    final rawResults = exportData['file_results'] as List?;
    if (rawResults != null) {
      final filtered = rawResults.where((f) =>
        f is Map && (f['result'] == 'NG' || f['result'] == 'OK')
      ).toList();
      if (filtered.isNotEmpty) {
        exportData['file_results'] = filtered;
        _log('Word导出: 过滤后file_results=${filtered.length}条 (原${rawResults.length}条)');
      }
    }

    _log('Word导出: file_results=${(exportData['file_results'] as List?)?.length ?? 0}条, rotate=$_wordRotateExportImages, img=${_wordImgWidthCm}x${_wordImgHeightCm}cm, quality=$_wordImgQuality');
    _log('Word导出项目信息字段: ${exportData.keys.where((k) => !['file_results', 'rotate_images', 'img_width_cm', 'img_height_cm', 'img_quality'].contains(k)).toList()}');
    // 调试等级统计
    _log('等级统计: A=${exportData['grade_a_count']}, B=${exportData['grade_b_count']}, C=${exportData['grade_c_count']}');
    _log('其他统计: ok_images=${exportData['ok_images']}, ng_images=${exportData['ng_images']}, total_images=${exportData['total_images']}');
    for (final k in ['项目名称', '报告编号', '委托单位', '检测单位', '项目地址']) {
      _log('  $k = ${exportData[k] ?? "<空>"}');
    }

    // API Call
    if (_working) return _toast('当前有任务正在执行，请稍后再试');
    _showProgress('正在导出 Word 报告...');
    await _run('Word导出', () async {
      await _api.exportWord(projectInfo: exportData, outputPath: savePath!);
      _updateProgress('Word 报告已导出: $savePath');
    });
  }

  Widget _projField(TextEditingController ctrl, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
  }



  Future<void> _exportExcel() async {
    final name = _projectInfoData['项目名称']?.toString() ?? _projectInfoData['project_name']?.toString() ?? 'EL检测报告';
    String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存 Excel 报告',
      fileName: '${name.isNotEmpty ? name : "EL检测报告"}.xlsx',
      allowedExtensions: ['xlsx'],
      type: FileType.custom,
    );
    if (savePath == null) return;
    if (!savePath.toLowerCase().endsWith('.xlsx')) {
      savePath += '.xlsx';
    }
    if (_working) return _toast('当前有任务正在执行，请稍后再试');
    _showProgress('正在导出 Excel 报告...');
    await _run('Excel导出', () async {
      final info = _buildExportData();
      info['rotate_images'] = _rotateExportImages;
      info['img_width_cm'] = _imgWidthCm;
      info['img_height_cm'] = _imgHeightCm;
      info['img_quality'] = _imgQuality;
      info['img_cols'] = _excelCols;
      await _api.exportExcel(projectInfo: info, outputPath: savePath!);
      _updateProgress('Excel 报告已导出: $savePath');
    });
  }

  /// Word / Excel 常规报告导出设置弹窗
  void _showReportExportDialog(String type) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          void upd(VoidCallback fn) { setState(fn); setDlgState(() {}); }

          Future<void> execute() async {
            Navigator.pop(ctx);
            if (type == 'Word') {
              final data = _buildExportData();
              await _handlePanelExport(data);
            } else if (type == 'Excel') {
              _projectInfoData = _buildExportData();
              await _exportExcel();
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFF334155))),
            title: Row(children: [
              Icon(type == 'Word' ? Icons.description : Icons.table_chart, color: const Color(0xFF7DD3FC), size: 20),
              const SizedBox(width: 8),
              Text('$type 报告导出设置', style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ── 图像配置 ──
                Text('报告中每个缺陷的图片渲染设置：', style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                const SizedBox(height: 12),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('旋转图片 90 度', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
                  value: type == 'Word' ? _wordRotateExportImages : _rotateExportImages,
                  activeThumbColor: const Color(0xFF7DD3FC),
                  onChanged: (v) => upd(() { if (type == 'Word') {
                    _wordRotateExportImages = v;
                  } else {
                    _rotateExportImages = v;
                  } }),
                ),
                const Divider(color: Color(0xFF1E293B)),
                Row(children: [const Text('图片呈现宽度', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)), const Spacer(), Text('${(type == 'Word' ? _wordImgWidthCm : _imgWidthCm).toStringAsFixed(1)} cm', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12))]),
                Slider(value: type == 'Word' ? _wordImgWidthCm : _imgWidthCm, min: 2.0, max: 20.0, divisions: 180, activeColor: const Color(0xFF7DD3FC), inactiveColor: const Color(0xFF1E293B), onChanged: (v) => upd(() { if (type == 'Word') {
                  _wordImgWidthCm = v;
                } else {
                  _imgWidthCm = v;
                } })),
                Row(children: [const Text('图片呈现高度', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)), const Spacer(), Text('${(type == 'Word' ? _wordImgHeightCm : _imgHeightCm).toStringAsFixed(1)} cm', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12))]),
                Slider(value: type == 'Word' ? _wordImgHeightCm : _imgHeightCm, min: 2.0, max: 20.0, divisions: 180, activeColor: const Color(0xFF7DD3FC), inactiveColor: const Color(0xFF1E293B), onChanged: (v) => upd(() { if (type == 'Word') {
                  _wordImgHeightCm = v;
                } else {
                  _imgHeightCm = v;
                } })),
                Row(children: [const Text('图片压缩质量', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)), const Spacer(), Text('${type == 'Word' ? _wordImgQuality : _imgQuality}%', style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12))]),
                Slider(value: (type == 'Word' ? _wordImgQuality : _imgQuality).toDouble(), min: 30, max: 100, divisions: 70, activeColor: const Color(0xFF7DD3FC), inactiveColor: const Color(0xFF1E293B), onChanged: (v) => upd(() { if (type == 'Word') {
                  _wordImgQuality = v.round();
                } else {
                  _imgQuality = v.round();
                } })),
                
                if (type == 'Word') ...[
                  const Divider(color: Color(0xFF1E293B)),
                  const Text('导出图片范围', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  RadioListTile<String>(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: const Text('全部图片', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
                    subtitle: const Text('包含所有已检测的 OK 和 NG 图片', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
                    value: 'all', groupValue: _wordImageFilter,
                    activeColor: const Color(0xFF7DD3FC),
                    onChanged: (v) => upd(() => _wordImageFilter = v ?? 'all'),
                  ),
                  RadioListTile<String>(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: const Text('仅缺陷图片 (NG)', style: TextStyle(color: Color(0xFFF87171), fontSize: 12)),
                    subtitle: const Text('只导出被判定为 NG 的图片', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
                    value: 'ng', groupValue: _wordImageFilter,
                    activeColor: const Color(0xFFF87171),
                    onChanged: (v) => upd(() => _wordImageFilter = v ?? 'all'),
                  ),
                  RadioListTile<String>(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: const Text('仅正常图片 (OK)', style: TextStyle(color: Color(0xFF34D399), fontSize: 12)),
                    subtitle: const Text('只导出被判定为 OK 的良品图片', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
                    value: 'ok', groupValue: _wordImageFilter,
                    activeColor: const Color(0xFF34D399),
                    onChanged: (v) => upd(() => _wordImageFilter = v ?? 'all'),
                  ),
                ],

                if (type == 'Excel') ...[
                  const Divider(color: Color(0xFF1E293B)),
                  Row(children: [
                    const Text('每行显示的图片数（列数）', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.remove_circle_outline, size: 18), color: const Color(0xFF94A3B8), onPressed: () => upd(() => _excelCols = (_excelCols - 1).clamp(1, 50))),
                    Text('$_excelCols', style: const TextStyle(color: Color(0xFF7DD3FC), fontWeight: FontWeight.bold, fontSize: 16)),
                    IconButton(icon: const Icon(Icons.add_circle_outline, size: 18), color: const Color(0xFF94A3B8), onPressed: () => upd(() => _excelCols = (_excelCols + 1).clamp(1, 50))),
                  ]),
                ],
              ])),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8)))),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 16),
                label: const Text('继续导出'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF34D399), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: () { _saveSettings(); execute(); },
              ),
            ],
          );
        },
      ),
    );
  }


  Future<void> _exportCsv() async {
    final name = _projectInfoData['项目名称']?.toString() ?? _projectInfoData['project_name']?.toString() ?? 'EL检测报告';
    String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存 CSV 报告',
      fileName: '${name.isNotEmpty ? name : "EL检测报告"}.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (savePath == null) return;
    if (!savePath.toLowerCase().endsWith('.csv')) {
      savePath += '.csv';
    }
    if (_working) return _toast('当前有任务正在执行，请稍后再试');
    _showProgress('正在导出 CSV 报告...');
    await _run('CSV导出', () async {
      final info = _buildExportData();
      await _api.exportCsv(projectInfo: info, outputPath: savePath!);
      _updateProgress('CSV 报告已导出: $savePath');
    });
  }

  /// 导出带标注框的检测图片（原始格式、最高质量）
  Future<void> _exportAnnotatedImages() async {
    if (_files.isEmpty) return _toast('没有可导出的图片');
    final hasDetected = _files.any((f) => f.$2 == 'NG' || f.$2 == 'OK');
    if (!hasDetected) return _toast('请先完成检测再导出图片');

    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2634),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('选择图片导出范围', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              tileColor: const Color(0xFF101A26),
              leading: const Icon(Icons.collections_outlined, color: Color(0xFF64FFDA)),
              title: const Text('导出全部图片', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('包含所有已检测的 OK 和 NG 图片', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'all'),
            ),
            const SizedBox(height: 8),
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              tileColor: const Color(0xFF101A26),
              leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
              title: const Text('仅导出有缺陷 (NG)', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('只导出被判定为 NG 的图片', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'ng'),
            ),
            const SizedBox(height: 8),
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              tileColor: const Color(0xFF101A26),
              leading: const Icon(Icons.check_circle_outline, color: Color(0xFF10B981)),
              title: const Text('仅导出无缺陷 (OK)', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('只导出被判定为 OK 的良品图片', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'ok'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
    if (mode == null) return;

    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择图片导出目录');
    if (dir == null) return;
    if (_working) return _toast('当前有任务正在执行，请稍后再试');
    _showProgress('正在导出检测图片...');
    await _run('导出图片', () async {
      final info = _buildExportData();
      final List results = (info['file_results'] as List?) ?? [];
      
      if (mode == 'ng') {
        info['file_results'] = results.where((f) => f['result'] == 'NG').toList();
      } else if (mode == 'ok') {
        info['file_results'] = results.where((f) => f['result'] == 'OK').toList();
      }
      
      if ((info['file_results'] as List).isEmpty) {
        _updateProgress('按照该设定没有可导出的图片');
        return;
      }
      
      final result = await _api.exportImages(projectInfo: info, outputDir: dir);
      final count = result['exported_count'] ?? 0;
      _updateProgress('已根据设定导出 $count 张检测图片到: $dir');
    });
  }

  // ─── 关于（系统信息）页 ───
  Widget _buildProfilePage() {
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(children: [
          Icon(Icons.info_outline_rounded, color: Color(0xFF7DD3FC), size: 28),
          SizedBox(width: 10),
          Text('关于', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 18, fontWeight: FontWeight.w900)),
        ]),
        const Divider(color: AppTheme.stroke, height: 28),

        // 系统信息
        _mini('系统信息', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _profileRow('版本号', _appVersion.isNotEmpty ? _appVersion : '未知'),
          _profileRow('当前模型', _modelName.isNotEmpty ? _modelName : '未加载'),
          _profileRow('后端地址', _backendCtrl.text.trim()),
          _profileRow('许可证', 'GNU GPLv3'),
        ])),
        const SizedBox(height: 14),

        // 退出
        SizedBox(width: double.infinity, height: 44, child: ElevatedButton.icon(
          icon: const Icon(Icons.exit_to_app, size: 18),
          label: const Text('退出系统', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF334155),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () async {
            if (!mounted) return;
            exit(0);
          },
        )),
      ],
    ));
  }

  Widget _profileRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w700))),
        Expanded(child: Text(value, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12))),
      ]),
    );
  }

  // ─── 报告页 & 设置页 ───
  Widget _buildReportPage() {
    final gap = _panelGap(context);
    return Row(children: [
      SizedBox(width: _leftPanelWidth(context), child: _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _header('报告中心导航', '模板 12'),
        const SizedBox(height: 10),
        _mini('报告模板', const Text('标准模板A / 对比模板B / 客户模板C', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
        const SizedBox(height: 8),
        _mini('导出配置', const Text('Word / Excel / PDF / CSV / JSON', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
        const SizedBox(height: 8),
        _mini('签章与权限', const Text('审核签字、电子章、导出权限控制', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
      ]))),
      SizedBox(width: gap),
      Expanded(child: _panel(Column(children: [
        _header('报告预览中心（Word / Excel / PDF）', '当前页 1/3'),
        const SizedBox(height: 10),
        Expanded(child: Container(decoration: BoxDecoration(color: const Color(0xFF041023), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.stroke)), child: Center(child: Container(width: 430, height: 560, color: Colors.white)))),
      ]))),
      SizedBox(width: gap),
      SizedBox(width: _rightPanelWidth(context), child: _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Text('导出队列', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w800)),
        SizedBox(height: 8),
        Text('PRJ-2026-001_日报告.docx  已完成', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
        Text('PRJ-2026-001_总表.xlsx    已完成', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
        Text('PRJ-2026-001_明细.pdf     处理中', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
      ]))),
    ]);
  }

  // ─── 滑出面板版参数设置（竖向排列，无导出报告设置）───
  Widget _modelPickerRow(String title, String? currentPath, Function(String?) onSelected) {
    final name = currentPath?.split(RegExp(r'[/\\]')).last ?? '未挂载模型 (点击选择)';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      InkWell(
        onTap: () async {
          final p = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['onnx', 'pt']);
          final path = p?.files.single.path;
          if (path != null) onSelected(path);
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: currentPath != null ? const Color(0xFF34D399) : const Color(0xFF334155)),
          ),
          child: Row(children: [
            Icon(Icons.folder_open_rounded, size: 16, color: currentPath != null ? const Color(0xFF34D399) : const Color(0xFF94A3B8)),
            const SizedBox(width: 8),
            Expanded(child: Text(
              name, 
              style: TextStyle(color: currentPath != null ? const Color(0xFF34D399) : const Color(0xFF94A3B8), fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            )),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildSettingsSlide() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 👑 本地模型池挂载
          _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: const [
              Text('👑', style: TextStyle(fontSize: 14)),
              SizedBox(width: 6),
              Text('本地模型池挂载', style: TextStyle(color: Color(0xFFFBBF24), fontSize: 13, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            const Text('支持单独挂载专属检测/分割模型 (.pt/.onnx)', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
            const SizedBox(height: 12),
            _modelPickerRow('缺陷检测模型', _defectModelPath, (path) {
              setState(() { _defectModelPath = path; _modelReady = false; });
              _saveSettings();
            }),
            const SizedBox(height: 10),
            _modelPickerRow('图片分割模型', _segmentModelPath, (path) {
              setState(() { _segmentModelPath = path; _modelReady = false; });
              _saveSettings();
            }),
          ])),
          const SizedBox(height: 8),

          // 检测参数
          _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _header('检测参数', ''),
            const SizedBox(height: 6),
            _sliderRow('置信度阈值', _conf, 0.1, 0.95, (v) { setState(() => _conf = v); _saveSettings(); }),
            _sliderRow('IOU阈值', _iou, 0.1, 0.95, (v) { setState(() => _iou = v); _saveSettings(); }),
            const SizedBox(height: 4),
            SwitchListTile(dense: true, visualDensity: VisualDensity.compact, value: _cuda, onChanged: (v) { setState(() => _cuda = v); _saveSettings(); }, title: const Text('CUDA', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
            SwitchListTile(dense: true, visualDensity: VisualDensity.compact, value: _fp16, onChanged: (v) { setState(() => _fp16 = v); _saveSettings(); }, title: const Text('FP16', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
            SwitchListTile(dense: true, visualDensity: VisualDensity.compact, value: _nms, onChanged: (v) { setState(() => _nms = v); _saveSettings(); }, title: const Text('NMS', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: _btn('应用参数', const Color(0xFF1D4ED8), () => _toast('参数已应用'))),
              const SizedBox(width: 8),
              Expanded(child: _btn('保存方案', const Color(0xFF0F766E), () => _toast('方案已保存'))),
            ]),
          ])),
          const SizedBox(height: 8),

          // 标注框显示参数
          _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _header('标注框显示', ''),
            const SizedBox(height: 6),
            _sliderRow('线段粗细', _boxStrokeWidth, 0.5, 6.0, (v) { setState(() => _boxStrokeWidth = v); _saveSettings(); }),
            _sliderRow('标签大小', _labelFontSize, 1.0, 24.0, (v) { setState(() => _labelFontSize = v); _saveSettings(); }),
            const Divider(color: Color(0xFF334155), height: 10),
            SwitchListTile(
              dense: true, visualDensity: VisualDensity.compact, value: _showBoxes,
              onChanged: (v) { setState(() => _showBoxes = v); _saveSettings(); },
              title: const Text('显示标注框', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
              subtitle: const Text('控制是否在图片上显示检测标注框', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
            ),
            SwitchListTile(
              dense: true, visualDensity: VisualDensity.compact, value: _showLabels,
              onChanged: (v) { setState(() => _showLabels = v); _saveSettings(); },
              title: const Text('显示标签名称', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
              subtitle: const Text('在标注框上方显示缺陷类别名称', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
            ),
            SwitchListTile(
              dense: true, visualDensity: VisualDensity.compact, value: _showConfidence,
              onChanged: (v) { setState(() => _showConfidence = v); _saveSettings(); },
              title: const Text('显示置信度', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
              subtitle: const Text('在标注框上方显示检测置信度百分比', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
            ),
          ])),
          const SizedBox(height: 8),

          // 缺陷等级配置
          _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _header('缺陷等级配置', ''),
            const SizedBox(height: 8),
            const Text('配置每种缺陷的A/B/C类阈值（小于等于A类阈值判A，小于等于B类阈值判B，否则判C）',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
            const SizedBox(height: 10),
            // 表头
            Row(children: const [
              SizedBox(width: 28, child: Text('排序', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
              SizedBox(width: 8),
              SizedBox(width: 100, child: Text('缺陷名称', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
              SizedBox(width: 36, child: Text('等级', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700))),
              SizedBox(width: 6),
              SizedBox(width: 44, child: Text('A类\n≤N', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF34D399), fontSize: 10, fontWeight: FontWeight.w700))),
              SizedBox(width: 6),
              SizedBox(width: 44, child: Text('B类\n≤N', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFFBBF24), fontSize: 10, fontWeight: FontWeight.w700))),
              SizedBox(width: 6),
              SizedBox(width: 44, child: Text('C类\n≥N', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFF87171), fontSize: 10, fontWeight: FontWeight.w700))),
              Expanded(child: SizedBox()),
            ]),
            const Divider(color: Color(0xFF334155), height: 8),
            ...List.generate(_defectGradingConfig.length, (i) {
              final cfg = _defectGradingConfig[i];
              final bMax = (cfg['b_max'] as num?)?.toInt() ?? 0;
              final cMin = bMax + 1;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  // 排序按钮 (左右紧凑排列)
                  SizedBox(width: 28, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    GestureDetector(
                      onTap: i > 0 ? () => setState(() {
                        final item = _defectGradingConfig.removeAt(i);
                        _defectGradingConfig.insert(i - 1, item);
                        for (int j = 0; j < _defectGradingConfig.length; j++) {
                          _defectGradingConfig[j]['level'] = j + 1;
                        }
                        _updateAllGrades(); _saveSettings();
                      }) : null,
                      child: Icon(Icons.keyboard_arrow_up, size: 14, color: i > 0 ? const Color(0xFF64748B) : const Color(0xFF1E293B)),
                    ),
                    GestureDetector(
                      onTap: i < _defectGradingConfig.length - 1 ? () => setState(() {
                        final item = _defectGradingConfig.removeAt(i);
                        _defectGradingConfig.insert(i + 1, item);
                        for (int j = 0; j < _defectGradingConfig.length; j++) {
                          _defectGradingConfig[j]['level'] = j + 1;
                        }
                        _updateAllGrades(); _saveSettings();
                      }) : null,
                      child: Icon(Icons.keyboard_arrow_down, size: 14, color: i < _defectGradingConfig.length - 1 ? const Color(0xFF64748B) : const Color(0xFF1E293B)),
                    ),
                  ])),
                  const SizedBox(width: 8),
                  // 缺陷名称 (可编辑)
                  SizedBox(width: 100, child: SizedBox(height: 26, child: TextField(
                    controller: TextEditingController(text: cfg['name'] as String),
                    style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(3)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF334155))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF3B82F6))),
                    ),
                    onChanged: (v) {
                      if (v.trim().isNotEmpty) {
                        setState(() { _defectGradingConfig[i]['name'] = v.trim(); _updateAllGrades(); });
                        _saveSettings();
                      }
                    },
                  ))),
                  // 等级 (可编辑)
                  SizedBox(width: 36, child: SizedBox(height: 26, child: TextField(
                    controller: TextEditingController(text: '${cfg['level']}'),
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(3)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF334155))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF3B82F6))),
                    ),
                    onChanged: (v) {
                      final val = int.tryParse(v);
                      if (val != null && val > 0) {
                        setState(() { _defectGradingConfig[i]['level'] = val; _updateAllGrades(); });
                        _saveSettings();
                      }
                    },
                  ))),
                  const SizedBox(width: 6),
                  // A类阈值
                  SizedBox(width: 44, child: SizedBox(height: 26, child: TextField(
                    controller: TextEditingController(text: '${cfg['a_max']}'),
                    style: const TextStyle(color: Color(0xFF34D399), fontSize: 12),
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(3)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF334155))),
                    ),
                    onChanged: (v) {
                      final val = int.tryParse(v);
                      if (val != null) {
                        setState(() { _defectGradingConfig[i]['a_max'] = val; _updateAllGrades(); });
                        _saveSettings();
                      }
                    },
                  ))),
                  const SizedBox(width: 6),
                  // B类阈值
                  SizedBox(width: 44, child: SizedBox(height: 26, child: TextField(
                    controller: TextEditingController(text: '${cfg['b_max']}'),
                    style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 12),
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(3)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: const BorderSide(color: Color(0xFF334155))),
                    ),
                    onChanged: (v) {
                      final val = int.tryParse(v);
                      if (val != null) {
                        setState(() { _defectGradingConfig[i]['b_max'] = val; _updateAllGrades(); });
                        _saveSettings();
                      }
                    },
                  ))),
                  const SizedBox(width: 6),
                  // C类阈值（自动计算 = B类上限+1）
                  SizedBox(
                    width: 44,
                    child: Container(
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF87171).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: const Color(0xFFF87171).withOpacity(0.3), width: 0.8),
                      ),
                      child: Text('≥$cMin', style: const TextStyle(color: Color(0xFFF87171), fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 删除按钮
                  GestureDetector(
                    onTap: () => setState(() {
                      _defectGradingConfig.removeAt(i);
                      for (int j = 0; j < _defectGradingConfig.length; j++) {
                        _defectGradingConfig[j]['level'] = j + 1;
                      }
                      _updateAllGrades(); _saveSettings();
                    }),
                    child: const Icon(Icons.close, size: 14, color: Color(0xFF64748B)),
                  ),
                ]),
              );
            }),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => setState(() {
                _defectGradingConfig.add({'name': '新缺陷', 'level': _defectGradingConfig.length + 1, 'a_max': 0, 'b_max': 0});
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(border: Border.all(color: const Color(0xFF334155)), borderRadius: BorderRadius.circular(4)),
                child: const Center(child: Text('+ 新增缺陷类别', style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 12))),
              ),
            ),
          ])),
          const SizedBox(height: 16),

          // 裁剪功能已移至主界面分割设置面板
        ],
      ),
    );
  }

  Widget _buildSettingsPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 检测参数
            Expanded(child: _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header('检测参数', ''),
          const SizedBox(height: 10),
          _sliderRow('置信度阈值', _conf, 0.1, 0.95, (v) { setState(() => _conf = v); _saveSettings(); }),
          _sliderRow('IOU阈值', _iou, 0.1, 0.95, (v) { setState(() => _iou = v); _saveSettings(); }),
          const SizedBox(height: 8),
          SwitchListTile(dense: true, value: _cuda, onChanged: (v) { setState(() => _cuda = v); _saveSettings(); }, title: const Text('CUDA', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
          SwitchListTile(dense: true, value: _fp16, onChanged: (v) { setState(() => _fp16 = v); _saveSettings(); }, title: const Text('FP16', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
          SwitchListTile(dense: true, value: _nms, onChanged: (v) { setState(() => _nms = v); _saveSettings(); }, title: const Text('NMS', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _btn('应用参数', const Color(0xFF1D4ED8), () => _toast('参数已应用'))),
            const SizedBox(width: 8),
            Expanded(child: _btn('保存方案', const Color(0xFF0F766E), () => _toast('方案已保存'))),
          ]),
        ]))),
            const SizedBox(width: 16),

            // 标注框显示参数
            Expanded(child: _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header('标注框显示', ''),
          const SizedBox(height: 10),
          _sliderRow('线段粗细', _boxStrokeWidth, 0.5, 6.0, (v) { setState(() => _boxStrokeWidth = v); _saveSettings(); }),
          _sliderRow('标签大小', _labelFontSize, 1.0, 24.0, (v) { setState(() => _labelFontSize = v); _saveSettings(); }),
          const Divider(color: Color(0xFF334155), height: 20),
          SwitchListTile(
            dense: true,
            value: _showBoxes,
            onChanged: (v) { setState(() => _showBoxes = v); _saveSettings(); },
            title: const Text('显示标注框', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
            subtitle: const Text('控制是否在图片上显示检测标注框', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
          ),
          SwitchListTile(
            dense: true,
            value: _showLabels,
            onChanged: (v) { setState(() => _showLabels = v); _saveSettings(); },
            title: const Text('显示标签名称', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
            subtitle: const Text('在标注框上方显示缺陷类别名称', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
          ),
          SwitchListTile(
            dense: true,
            value: _showConfidence,
            onChanged: (v) { setState(() => _showConfidence = v); _saveSettings(); },
            title: const Text('显示置信度', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
            subtitle: const Text('在标注框上方显示检测置信度百分比', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
          ),
        ]))),
            const SizedBox(width: 16),

            // 导出设置
            Expanded(child: _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header('报告导出设置', ''),
          const SizedBox(height: 10),
          SwitchListTile(
            dense: true,
            value: _rotateExportImages,
            onChanged: (v) => setState(() => _rotateExportImages = v),
            title: const Text('旋转图片90度（横向放置）', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
            subtitle: const Text('导出报告时将EL图片逆时针旋转90度', style: TextStyle(color: Color(0xFF64748B), fontSize: 10)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('图片宽度(cm)', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
              const SizedBox(width: 8),
              SizedBox(width: 70, height: 32, child: TextField(
                controller: TextEditingController(text: _imgWidthCm.toStringAsFixed(1)),
                style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 12),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF334155))),
                ),
                onChanged: (v) { final d = double.tryParse(v); if (d != null && d > 0) setState(() => _imgWidthCm = d); },
              )),
              const SizedBox(width: 16),
              const Text('高度(cm)', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
              const SizedBox(width: 8),
              SizedBox(width: 70, height: 32, child: TextField(
                controller: TextEditingController(text: _imgHeightCm.toStringAsFixed(1)),
                style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 12),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF334155))),
                ),
                onChanged: (v) { final d = double.tryParse(v); if (d != null && d > 0) setState(() => _imgHeightCm = d); },
              )),
            ]),
          ),
          const SizedBox(height: 4),
          _sliderRow('图片压缩质量', _imgQuality.toDouble(), 10, 100, (v) => setState(() => _imgQuality = v.round()), decimals: 0),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '• 降低质量可减小Word文件体积\n'
              '• 100=最高质量，建议50-85\n'
              '• 导出图片使用带缺陷标注的检测结果图\n'
              '• 按输入图片的目录层级自动分组导出',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
            ),
          ),
        ]))),
          ],
        ),
      ],
    ));
  }

  Widget _sliderRow(String label, double value, double min, double max, ValueChanged<double> onChanged, {int decimals = 2}) {
    final step = decimals == 0 ? 1.0 : 0.05;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12))),
        Expanded(child: Slider(
          value: value, min: min, max: max,
          divisions: ((max - min) / step).round(),
          label: value.toStringAsFixed(decimals),
          onChanged: onChanged,
        )),
        // 加减 + 直接输入 + 滚轮
        _NeuSpinner(
          value: value, min: min, max: max, step: step, decimals: decimals,
          onChanged: onChanged,
        ),
      ]),
    );
  }

  Widget _cellGradeRow(String label, int count, int total, Color color) {
    final ratio = count / math.max(1, total);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11))),
        SizedBox(width: 30, child: Text('$count', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 11, fontWeight: FontWeight.w700))),
        const SizedBox(width: 6),
        Expanded(child: Container(
          height: 10,
          decoration: BoxDecoration(color: const Color(0xFF0A1E33), borderRadius: BorderRadius.circular(5), border: Border.all(color: AppTheme.stroke, width: 0.5)),
          child: Stack(children: [
            FractionallySizedBox(widthFactor: ratio, child: Container(decoration: BoxDecoration(color: color.withOpacity(0.6), borderRadius: BorderRadius.circular(5)))),
          ]),
        )),
        const SizedBox(width: 6),
        SizedBox(width: 40, child: Text('${(ratio * 100).toStringAsFixed(1)}%', textAlign: TextAlign.right, style: const TextStyle(color: Color(0xFF64748B), fontSize: 10))),
      ]),
    );
  }

  // ─── 通用组件 ───
  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: AppTheme.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
    child: child,
  );

  Widget _mini(String title, Widget child) => Container(
    width: double.infinity, padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: AppTheme.panelAlt, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.stroke)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13, fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      child,
    ]),
  );

  Widget _header(String title, String badge) => Row(children: [
    Expanded(child: Text(title, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w900))),
  ]);

  Widget _btn(String text, Color color, Function()? onTap) => SizedBox(
    height: 34,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      onPressed: _working ? null : () => onTap?.call(),
      child: Text(text, overflow: TextOverflow.ellipsis),
    ),
  );

  /// 始终可用的按钮（暂停/停止等在检测中也需要可点击）
  Widget _btnAlways(String text, Color color, Function()? onTap, {bool enabled = true}) => SizedBox(
    height: 34,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      onPressed: enabled ? () => onTap?.call() : null,
      child: Text(text, overflow: TextOverflow.ellipsis),
    ),
  );


  Widget _buildHelpPage() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: ListView(
        children: [
          // ══ 标题 ══
          const Text('使用帮助', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('EL光伏组件缺陷检测系统', style: TextStyle(color: Color(0xFF64748B), fontSize: 11, letterSpacing: 0.5)),
          const SizedBox(height: 20),

          // ══ 快捷操作区 ══
          Row(children: [
            Expanded(child: _helpActionCard(
              icon: Icons.terminal, iconColor: const Color(0xFF7DD3FC),
              title: '完整日志',
              subtitle: '开启后显示全字段',
              trailing: Transform.scale(scale: 0.75, child: Switch(
                value: _showFullLogs,
                onChanged: (v) => setState(() => _showFullLogs = v),
                activeThumbColor: const Color(0xFF7DD3FC),
              )),
            )),
            const SizedBox(width: 8),
            Expanded(child: _helpActionCard(
              icon: Icons.cloud_upload_outlined, iconColor: const Color(0xFFFBBF24),
              title: '上报日志',
              subtitle: '一键上报至运维服务器',
              trailing: SizedBox(width: 52, height: 26, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFBBF24), foregroundColor: Colors.black, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)), textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                onPressed: _reportLogs,
                child: const Text('上报'),
              )),
            )),
            const SizedBox(width: 8),
            Expanded(child: _helpActionCard(
              icon: Icons.system_update, iconColor: const Color(0xFF4ADE80),
              title: '检查更新',
              subtitle: _appVersion.isNotEmpty ? '当前 v$_appVersion' : '获取最新版本',
              trailing: SizedBox(width: 52, height: 26, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4ADE80), foregroundColor: Colors.black, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)), textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                onPressed: _checkForUpdate,
                child: const Text('检查'),
              )),
            )),
          ]),
          const SizedBox(height: 24),

          // ══ 帮助文档入口 ══
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _HelpDocPage(displayName: _displayName),
            )),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: const Color(0xFF071726),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF0B2A4A)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B2A4A),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.menu_book_rounded, color: Color(0xFF7DD3FC), size: 22),
                ),
                const SizedBox(width: 16),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('查看帮助文档', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 15, fontWeight: FontWeight.w700)),
                  SizedBox(height: 3),
                  Text('参数说明、类别管理、导出报告、账号授权、常见问题', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                ])),
                const Icon(Icons.chevron_right_rounded, color: Color(0xFF334155), size: 22),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _helpActionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F33),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E3A5F)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 5),
          Expanded(child: Text(title, style: const TextStyle(color: Color(0xFFE6F0FF), fontSize: 12, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 2),
        Text(subtitle, style: const TextStyle(color: Color(0xFF64748B), fontSize: 9)),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: trailing),
      ]),
    );
  }

  Widget _helpSection(String title, IconData icon, Color color, List<Widget> steps) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF071726),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF0B2A4A)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFF0B2A4A)),
        ...steps,
      ]),
    );
  }

  Widget _helpStep(String badge, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28, height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0B2A4A),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(badge, style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 9, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, height: 1.5)),
        ])),
      ]),
    );
  }

  // ─── 空间智能映射地图 ───
  Future<void> _syncToMap() async {
    if (_files.isEmpty) {
      _toast('没有可映射的文件，请先导入并检测。');
      return;
    }
    
    _showProgress('正在启动空间映射...');
    try {
      List<Map<String, dynamic>> mapData = [];
      for (int i = 0; i < _files.length; i++) {
        final path = _files[i].$3;
        _updateProgress('解析并匹配 GPS: ${i + 1}/${_files.length} ...');
        // 映射所有含 GPS 的图像，无论是否带有检测结果
        // if (_files[i].$2 == '待检测') continue;

        try {
          final res = await _api.extractGps(path);
          if (res['success'] == true) {
            final lat = res['latitude'];
            final lon = res['longitude'];
            final gsd = res['gsd'] ?? 0.0;
            final dynamic rw = res['img_w'];
            final dynamic rh = res['img_h'];
            final double imgW = (rw != null && rw > 1) ? rw.toDouble() : (_imageWidth > 0 ? _imageWidth : 1000.0);
            final double imgH = (rh != null && rh > 1) ? rh.toDouble() : (_imageHeight > 0 ? _imageHeight : 1000.0);
            debugPrint('[SYNC-MAP] path=$path, lat=$lat, lon=$lon, gsd=$gsd, imgW=$imgW, imgH=$imgH');
            debugPrint('[SYNC-MAP] annotations count=${_perImageAnnotations[path]?.length ?? 0}');
            
            List<Map<String, dynamic>> defects = [];
            if (_perImageAnnotations[path] != null) {
              for (var box in _perImageAnnotations[path]!) {
                defects.add({
                  'className': box.className,
                  'score': box.score,
                  'cropPath': box.cropPath,
                  'rect': {
                    'left': box.rect.left,
                    'top': box.rect.top,
                    'right': box.rect.right,
                    'bottom': box.rect.bottom,
                  },
                  'quad': box.quad?.map((e) => {'x': e.dx, 'y': e.dy}).toList(),
                });
              }
            }
            
            mapData.add({
              'path': path,
              'filename': _files[i].$1,
              'lat': lat,
              'lon': lon,
              'gsd': gsd,
              'img_w': imgW,
              'img_h': imgH,
              'defects': defects,
              'grade': _files[i].$2 == '待检测' ? '待检测' : (_perImageGrades[path] ?? 'OK'),
            });
          }
        } catch (e) {
          // Skip file if GPS extraction fails
        }
      }
      
      if (mapData.isEmpty) {
        _hideProgress();
        _toast('未能从已载图像中提取到任何有效的 GPS 信息！');
        return;
      }
      
      _hideProgress();
      _toast('成功映射 ${mapData.length} 张检测图像到地理空间系统！');
      
      setState(() {
        _mapDataCache = mapData;
        _section = AppSection.model;
        _slidePanel = null;
      });

    } catch (e) {
      _hideProgress();
      _toast('映射异常中断: $e');
    }
  }

  // ─── TIF 大地图接入 ───
  Future<void> _pickTifAndSync() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['tif', 'tiff'],
    );
    if (result != null && result.files.single.path != null) {
      final tifPath = result.files.single.path!;
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => AiModelPage(
            initialMapData: [], 
            tifPath: tifPath,
            serverUrl: _backendCtrl.text.trim(),
          ),
        ),
      );
    }
  }

  // ─── 智能视频轨抽帧 (MOT) ───
  Future<void> _pickVideoAndExtract() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );
    if (result != null && result.files.single.path != null) {
      final videoPath = result.files.single.path!;
      _showProgress('正在通过 MOT 算法解析视频并去重抽帧 (可能需要数分钟)...');
      
      try {
        final parentPath = Directory(videoPath).parent.path;
        final outDir = '$parentPath\\el_extracted_frames';
        final Dio dio = Dio(BaseOptions(baseUrl: _backendCtrl.text.trim()));
        
        final response = await dio.post(
          '/api/video/extract_panels', 
          data: {
             'video_path': videoPath,
             'output_dir': outDir,
             'conf_threshold': _conf
          },
          options: Options(receiveTimeout: const Duration(minutes: 30))
        );
        
        if (response.data != null && response.data!['success'] == true) {
           _hideProgress();
           final int frameProcessed = response.data!['frames_processed'] ?? 0;
           final int extracted = response.data!['extracted_images'] ?? 0;
           _toast('视频处理完成！共分析 $frameProcessed 帧，抽取图像 $extracted 张。');
           if (extracted > 0) {
             _folderPath = outDir;
             await _scanFolder(outDir);
             await _loadCheckpoint(outDir);
           }
        } else {
             _hideProgress();
             _toast('视频抽取失败');
        }
      } catch (e) {
        _hideProgress();
        _toast('视频抽取失败: $e');
      }
    }
  }
}

// ─── 帮助文档页（独立页面，点击"查看帮助文档"跳转）───
class _HelpDocPage extends StatelessWidget {
  final String displayName;
  const _HelpDocPage({required this.displayName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.canvas,
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        foregroundColor: const Color(0xFFE6F0FF),
        elevation: 0,
        title: const Text('帮助文档', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ══ 参数调整 ══
          _section('参数调整', Icons.tune_rounded, const Color(0xFFA78BFA), [
            _step('置信度', 'Confidence Threshold（建议 0.45～0.65）', '控制检测结果的最低置信度阈值。值越高，输出结果越精准但可能漏检低置信度缺陷；值越低，召回率更高但可能出现误报。推荐初始值 0.55，根据实际误检/漏检情况微调。'),
            _step('NMS', 'IoU Threshold（建议 0.35～0.50）', '非极大值抑制阈值，控制重叠检测框的合并程度。值越小，相邻重叠框合并越积极，适合密集缺陷场景；值越大，保留更多独立框，适合缺陷间距较大的场景。'),
            _step('笔触', '标注框线宽（1～5px）', '调整图像上标注框的线条粗细。高分辨率图像建议使用 2～3px；低分辨率图像使用 1px 避免遮挡细节。'),
            _step('字号', '标签字体大小（10～24px）', '调整标注框上类别标签的字体大小。建议与图像分辨率匹配，避免标签过大遮挡缺陷区域。'),
            _step('显示', '标注显示选项', '可独立控制是否显示标注框、类别标签、置信度数值。仅需查看缺陷位置时可关闭标签和置信度，使图像更简洁。'),
          ]),
          const SizedBox(height: 16),

          // ══ 类别管理 ══
          _section('类别管理', Icons.category_outlined, const Color(0xFF64FFDA), [
            _step('入口', '打开类别管理', '在右侧「实时缺陷统计」卡片右上角点击「类别管理」按钮，进入类别编辑模式。'),
            _step('改名', '重命名缺陷类别', '点击类别行右侧「改名」按钮，在弹出对话框中输入新名称后确认。操作将同步更新当前所有已检测图片中该类别的标注框名称。'),
            _step('删除', '删除缺陷类别', '点击类别行右侧「删除」按钮，确认后将删除所有图片中该类别的全部标注框。此操作不可撤销，请谨慎使用。'),
            _step('范围', '批量应用', '所有类别操作均自动应用到全部已检测图片，无需逐张操作。'),
          ]),
          const SizedBox(height: 16),

          // ══ 导出与报告 ══
          _section('导出与报告', Icons.description_outlined, const Color(0xFFFBBF24), [
            _step('图片', '导出标注图片', '点击左侧「导出图片」按钮，将当前图像连同标注框一起导出为 PNG 文件，保存到指定目录。'),
            _step('Word', '技术尽调报告', '在右侧项目信息面板填写项目基本信息后，点击「导出 Word」生成包含检测图像、缺陷统计和项目信息的技术尽调报告（.docx 格式）。'),
            _step('Excel', '缺陷数据汇总', '点击「导出 Excel」生成附件2格式的缺陷数据汇总表，包含图片缩略图、缺陷类别、数量等详细统计（.xlsx 格式）。'),
            _step('保存', '项目进度保存', '点击「保存项目信息」将当前检测数据、项目信息和进度保存到本地 JSON 文件，下次打开可继续上次工作。'),
          ]),
          const SizedBox(height: 16),

          // ══ 账号与授权 ══
          _section('账号与授权', Icons.lock_outline_rounded, const Color(0xFF34D399), [
            _step('登录', '账号登录', '在登录页填写授权服务器地址、账号和密码后点击「登录」。'),
            _step('绑定', '设备绑定', '首次登录时系统自动绑定当前设备机器码，后续只允许在同一台设备上使用。如需更换设备，请联系管理员在授权后台重置设备绑定。'),
            _step('配额', '检测配额', '每次单张或批量检测消耗相应配额。可在「我的」页面查看剩余配额和账号到期时间。配额不足时请联系管理员续期。'),
            _step('密码', '修改密码', '在「我的」页面点击「修改密码」，输入旧密码和新密码后确认。密码修改后立即生效，下次登录使用新密码。'),
          ]),
          const SizedBox(height: 16),

          // ══ 常见问题与故障排除 ══
          _section('常见问题与故障排除', Icons.build_outlined, const Color(0xFFF87171), [
            _step('Q1', '登录提示"连接被拒绝"或"无法连接"', '原因：授权服务器未启动或地址填写错误。\n解决：① 确认服务器地址格式正确（如 http://192.168.1.100:8000）；② 检查服务器端授权服务是否正在运行；③ 确认防火墙未拦截对应端口。'),
            _step('Q2', '检测结果全部为空（无标注框）', '原因：置信度阈值过高，或图像质量不符合要求。\n解决：① 将置信度阈值降低至 0.3～0.4 后重新检测；② 确认图像为 EL 图像（电致发光图像）；③ 检查图像分辨率是否过低（建议不低于 640×640）。'),
            _step('Q3', '批量检测中途停止或卡住', '原因：内存不足、磁盘空间不足或单张图像处理超时。\n解决：① 减少单次批量处理数量；② 关闭其他占用内存的程序；③ 确认磁盘剩余空间大于 2GB；④ 点击「停止」后重新开始。'),
            _step('Q4', '导出 Excel/Word 失败', '原因：目标路径无写入权限，或文件被其他程序占用。\n解决：① 选择其他保存路径（如桌面或 D 盘）；② 关闭已打开的同名文件；③ 以管理员身份运行程序后重试。'),
            _step('Q5', '程序启动后界面空白或崩溃', '原因：后端服务未启动，或端口被占用。\n解决：① 检查任务管理器中是否有后端服务进程；② 查看运行日志面板中的错误信息，或联系技术支持并上报日志。'),
            _step('Q6', '配额显示异常或无法消耗', '原因：网络波动导致配额同步失败。\n解决：① 退出后重新登录刷新配额状态；② 检查与授权服务器的网络连接；③ 若问题持续，联系管理员在后台核查账号状态。'),
          ]),
          const SizedBox(height: 16),

          // ══ 技术支持 ══
          _section('技术支持', Icons.support_agent_outlined, const Color(0xFF94A3B8), [
            _step('日志', '上报运行日志', '遇到问题时，点击帮助页「上报日志」按钮，将运行日志发送至技术支持团队，便于快速定位问题。'),
            _step('联系', '获取技术支持', '如问题无法自行解决，请联系系统管理员或技术支持，并提供：① 问题描述；② 操作步骤；③ 错误截图；④ 已上报的日志编号。'),
          ]),

          // ══ 开源声明 ══
          const SizedBox(height: 32),
          const Divider(color: Color(0xFF0A1828), height: 1),
          const SizedBox(height: 10),
          const Center(
            child: Text(
              'EL 缺陷检测系统基于 GNU GPLv3 协议开源',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _section(String title, IconData icon, Color color, List<Widget> steps) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF071726),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF0B2A4A)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFF0B2A4A)),
        ...steps,
      ]),
    );
  }

  Widget _step(String badge, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28, height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0B2A4A),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(badge, style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 9, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, height: 1.5)),
        ])),
      ]),
    );
  }

}

