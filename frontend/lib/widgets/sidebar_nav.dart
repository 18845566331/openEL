import 'package:flutter/material.dart';

class SidebarNav extends StatelessWidget {
  const SidebarNav({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.onTap,
  });

  final List<NavItemData> items;
  final int activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 248,
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EL缺陷检测',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '工业检测平台',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 24),
              for (var i = 0; i < items.length; i++) ...[
                _NavButton(
                  item: items[i],
                  active: i == activeIndex,
                  onTap: () => onTap(i),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NavItemData {
  const NavItemData({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final NavItemData item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bgColor = active ? const Color(0xFF1D4ED8) : const Color(0xFF1E293B);
    final fgColor = active ? Colors.white : const Color(0xFFCBD5E1);
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(item.icon, color: fgColor, size: 18),
              const SizedBox(width: 10),
              Text(
                item.label,
                style: TextStyle(
                  color: fgColor,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

