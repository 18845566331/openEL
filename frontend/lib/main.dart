import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'pages/workbench_page.dart';
import 'providers/app_state.dart';
import 'services/branding_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(TitleBarStyle.normal);
  await windowManager.setMinimumSize(const Size(960, 540));

  // 初始化品牌信息（优先本地持久化，其次 assets 默认值）
  await BrandingStore.instance.init();
  final companyName = BrandingStore.instance.companyName;
  final title = companyName.isNotEmpty
      ? '$companyName  EL缺陷检测系统'
      : 'EL缺陷检测系统';
  await windowManager.setTitle(title);

  runApp(const ElDefectApp());
}

class ElDefectApp extends StatelessWidget {
  const ElDefectApp({super.key});

  // 设计基准分辨率（UI 布局按此尺寸设计）
  static const double _designW = 1920;
  static const double _designH = 1080;

  @override
  Widget build(BuildContext context) {
    final name = BrandingStore.instance.companyName;
    final appTitle = name.isNotEmpty ? '$name EL光伏组件缺陷检测系统' : 'EL光伏组件缺陷检测系统';
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: appTitle,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [
          Locale('zh', 'CN'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const WorkbenchPage(),
        builder: (context, child) {
          // ─── 全局自适应缩放引擎 ───
          // 思路：
          //   1. 以 1920×1080 为设计基准，取宽/高中较小的缩放比
          //   2. 反算出该缩放比下的逻辑分辨率（>=1920×1080，且宽高比 = 窗口宽高比）
          //   3. FittedBox.fill 等比缩放铺满窗口，无黑边、无变形
          //   4. 屏幕 >= 1920×1080 时不缩放，使用原生分辨率
          final mq = MediaQuery.of(context);
          final w = mq.size.width;
          final h = mq.size.height;
          if (w <= 0 || h <= 0) return child ?? const SizedBox.shrink();

          // 统一缩放比例，取宽/高中压力更大的那条边
          final scale = math.min(w / _designW, h / _designH).clamp(0.0, 1.0);
          if (scale >= 1.0) return child!; // 屏幕足够大，无需缩放

          // 反算逻辑尺寸：logicalW/H = 实际尺寸 ÷ scale
          // 由于 scale = min(wRatio, hRatio)，所以 logicalW >= designW, logicalH >= designH
          // 且 logicalW:logicalH == w:h，FittedBox.fill 的 scaleX == scaleY == scale
          final logicalW = w / scale;
          final logicalH = h / scale;

          return FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: logicalW,
              height: logicalH,
              child: MediaQuery(
                data: mq.copyWith(
                  size: Size(logicalW, logicalH),
                ),
                child: child!,
              ),
            ),
          );
        },
      ),
    );
  }
}

