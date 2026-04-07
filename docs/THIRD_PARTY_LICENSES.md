# 第三方依赖许可证声明

本文档列出了 EL光伏组件缺陷检测系统 所使用的所有第三方开源组件及其许可证信息。

## 开源合规策略

本系统是基于 **GNU General Public License v3.0 (GPLv3)** 开源的自由软件。
所有第三方运行时依赖均采用与 GPLv3 兼容的开源许可证。

---

## 后端依赖（Python）

以下为后端服务的运行时依赖：

| 组件名称 | 版本 | 许可证 | 用途 |
|---------|------|--------|------|
| FastAPI | 0.116.1 | MIT | Web 框架，提供 RESTful API 服务 |
| Uvicorn | 0.35.0 | BSD-3-Clause | ASGI 服务器，运行 FastAPI 应用 |
| NumPy | 2.2.2 | BSD-3-Clause | 数值计算，图像数据处理 |
| OpenCV-Python | 4.12.0.88 | Apache 2.0 | 图像读取、预处理、可视化绘制、备用推理引擎 |
| ONNX Runtime GPU | 1.22.0 | MIT | 主推理引擎，执行 ONNX 模型推理 |
| Pydantic | 2.11.7 | MIT | 数据验证和序列化 |
| Ultralytics | >=8.0.0 | AGPL-3.0 | YOLO 模型加载与推理 |
| python-docx | >=1.1.0 | MIT | Word 报告生成 |
| openpyxl | >=3.1.2 | MIT | Excel 报告生成 |
| Pillow | >=10.2.0 | HPND | 图像处理与格式转换 |
| SciPy | >=1.10.0 | BSD-3-Clause | 科学计算 |
| python-dotenv | >=1.0.0 | BSD-3-Clause | 环境变量配置管理 |
| psutil | >=5.9.0 | BSD-3-Clause | 系统资源监控 |
| Requests | >=2.31.0 | Apache 2.0 | HTTP 客户端 |
| python-multipart | >=0.0.6 | Apache 2.0 | 文件上传处理 |

> **注意**：Ultralytics 采用 AGPL-3.0 许可证。本项目采用 GPLv3 许可证，与 AGPL-3.0 兼容。
> 如果您不需要 YOLO `.pt` 模型加载功能，可以从 `requirements.txt` 中移除 `ultralytics` 依赖，
> 系统仍可通过 ONNX Runtime 加载 `.onnx` 格式模型。

### 后端开发/测试依赖（不随产品分发）

| 组件名称 | 版本要求 | 许可证 | 用途 |
|---------|---------|--------|------|
| pytest | >=8.0.0 | MIT | 单元测试框架 |
| pytest-cov | >=6.0.0 | MIT | 测试覆盖率工具 |
| Hypothesis | >=6.100.0 | MPL 2.0 | 基于属性的测试框架 |
| httpx | >=0.28.0 | BSD-3-Clause | HTTP 测试客户端 |

---

## 前端依赖（Flutter/Dart）

以下为前端桌面应用的运行时依赖：

| 组件名称 | 版本要求 | 许可证 | 用途 |
|---------|---------|--------|------|
| Flutter SDK | >=3.4.0 | BSD-3-Clause | 跨平台桌面应用框架 |
| flutter_localizations | SDK 内置 | BSD-3-Clause | 国际化和本地化支持 |
| cupertino_icons | ^1.0.8 | MIT | iOS 风格图标资源 |
| dio | ^5.9.0 | MIT | HTTP 客户端，与后端 API 通信 |
| file_picker | ^10.3.2 | MIT | 系统文件选择对话框 |
| provider | ^6.1.2 | MIT | 状态管理 |
| window_manager | ^0.5.1 | MIT | 桌面窗口管理 |
| desktop_drop | ^0.4.4 | MIT | 桌面拖放支持 |
| flutter_map | ^8.2.2 | BSD-3-Clause | 地图组件 |
| qr_flutter | ^4.1.0 | BSD-3-Clause | 二维码生成 |

### 前端开发/测试依赖（不随产品分发）

| 组件名称 | 版本要求 | 许可证 | 用途 |
|---------|---------|--------|------|
| flutter_test | SDK 内置 | BSD-3-Clause | Flutter 测试框架 |
| flutter_lints | ^5.0.0 | BSD-3-Clause | Dart 代码风格检查 |

---

## 许可证兼容性说明

本项目采用 **GPLv3** 许可证。以下许可证均与 GPLv3 兼容：

| 许可证 | 兼容性 | 说明 |
|--------|--------|------|
| MIT | ✅ 兼容 | 宽松许可证，可自由用于 GPL 项目 |
| BSD-3-Clause | ✅ 兼容 | 宽松许可证，可自由用于 GPL 项目 |
| Apache 2.0 | ✅ 兼容 | 与 GPLv3 兼容（GPLv2 不兼容） |
| AGPL-3.0 | ✅ 兼容 | GPLv3 允许与 AGPL-3.0 代码组合 |
| MPL 2.0 | ✅ 兼容 | 仅用于测试依赖，不影响分发 |
| HPND | ✅ 兼容 | 历史宽松许可证，与 GPL 兼容 |

---

*Copyright (C) 2024-2026 OpenSource Contributors*
*本文档最后更新时间：2026年4月*
