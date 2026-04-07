import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// 缺陷统计图表组件 — 需求 7.8
/// 显示OK/NG比例和缺陷类别分布
class DefectChart extends StatelessWidget {
  const DefectChart({
    super.key,
    required this.defectByClass,
    required this.okCount,
    required this.ngCount,
  });

  final Map<String, int> defectByClass;
  final int okCount;
  final int ngCount;

  static const _colors = [
    Color(0xFFF87171),
    Color(0xFFFBBF24),
    Color(0xFF60A5FA),
    Color(0xFF34D399),
    Color(0xFFA78BFA),
    Color(0xFFFB923C),
    Color(0xFF22D3EE),
    Color(0xFFF472B6),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('统计图表', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          // OK/NG 比例
          _buildOkNgBar(),
          const SizedBox(height: 16),
          const Text('缺陷类别分布', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          // 缺陷分布条形图
          Expanded(child: _buildDefectBars()),
        ],
      ),
    );
  }

  Widget _buildOkNgBar() {
    final total = math.max(1, okCount + ngCount);
    final okRatio = okCount / total;
    final ngRatio = ngCount / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('OK/NG 比例', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 13, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('$okCount OK / $ngCount NG', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 20,
            child: Row(children: [
              if (okRatio > 0)
                Expanded(
                  flex: (okRatio * 100).round(),
                  child: Container(color: const Color(0xFF22C55E), alignment: Alignment.center, child: Text('${(okRatio * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
                ),
              if (ngRatio > 0)
                Expanded(
                  flex: (ngRatio * 100).round(),
                  child: Container(color: const Color(0xFFEF4444), alignment: Alignment.center, child: Text('${(ngRatio * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
                ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildDefectBars() {
    if (defectByClass.isEmpty) {
      return const Center(child: Text('无缺陷数据', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)));
    }
    final entries = defectByClass.entries.toList();
    final maxVal = math.max(1, entries.map((e) => e.value).reduce(math.max));
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final e = entries[i];
        final color = _colors[i % _colors.length];
        final ratio = e.value / maxVal;
        return Row(children: [
          SizedBox(width: 80, child: Text(e.key, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                backgroundColor: const Color(0xFF0A1E33),
                color: color,
                minHeight: 16,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 36, child: Text('${e.value}', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700), textAlign: TextAlign.right)),
        ]);
      },
    );
  }
}
