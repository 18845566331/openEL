# Frontend 使用说明

## 启动

```powershell
flutter pub get
flutter run -d windows
```

## 页面功能

1. 模型文件选择与加载
2. 单图检测
3. 批量检测
4. 阈值调参（置信度、IOU）
5. 缺陷分类统计与日志

## 关键文件

1. `lib/main.dart`：应用入口
2. `lib/pages/workbench_page.dart`：主工作台界面
3. `lib/services/detection_api_service.dart`：后端接口封装
4. `lib/widgets/sidebar_nav.dart`：侧边导航组件

