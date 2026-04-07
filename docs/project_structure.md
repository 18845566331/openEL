# 项目架构数据分布表

本文档提供 EL 光伏组件缺陷检测系统精简降本优化后的完整代码与目录架构说明。经过三次全盘清洗后，当前的构建体系无无效/过期资产。

## 根目录结构 (el_defect_system)

| 目录/文件 | 核心作用 | 依赖归属 |
|:---|:---|:---|
| `backend/` | Python FastAPI 后端服务集群，承载推理计算逻辑 | Python 3.10+ |
| `frontend/` | Flutter Desktop 前端 UI 界面工程，跨平台 UI | Flutter 3.24+ |
| `docs/` | 技术说明、第三方许可、接口文档、操作手册 | Markdown |
| `scripts/` | (如有) 脚本小工具集合 | 运维/开发 |
| `LICENSE` | 软件著作权以及相关的商业闭源、知识产权声明 | - |
| `README.md` | 项目总览与上手指南 | - |
| `启动前端界面.bat` / `启动后端服务.bat` / `一键启动系统.bat` | Windows 系统下的一键快捷启动脚本 | CMD |

---

## 核心业务：后端体系 (backend)

在 `backend` 的根目录下主要存储着虚拟环境 (`.venv` - 已排除在代码仓库外)、`requirements.txt`。

- `backend/app/main.py`:  整个系统的核心 API 暴露层。负责路由的注册、图片读取、Base64交互、历史报告导出（Excel/Word 排版写入）。
- `backend/app/detector.py`: 模型推理心脏。负责将多类 ONNX 权重挂载进入 OpenCV DNN / ONNXRuntime 引擎，并承载推理前后的尺寸适配、NMS 框过滤解析任务。
- `backend/app/schemas.py`: Pydantic 规范的传入传出模型，定义了标准的传输字典协议。
- `backend/app/remote_model.py`: （预留/特定状态下载）从远端拉取权重缓存至本地的设计隔离类。
- `backend/models/`: 主要用于放置用户自主训练的 `.onnx` 权重以及 `default` 基线权重的持久化存储位。

---

## 核心外观：前端体系 (frontend)

所有前端渲染的逻辑均存在于 `frontend/lib` 中。这也是 Flutter 工程的核心部位。目前代码已经完全采用组合优于继承的状态，且死代码全部被清除。

- `lib/main.dart` : MaterialApp 入口。
- `lib/app_theme.dart` : 项目暗金黑蓝色调与标准间距控制层。
- `lib/providers/app_state.dart` : 整个应用程序状态管理的集中数据仓库（如检测进度、模型名等状态中继）。
- `lib/pages/login_page.dart`: 系统防伪与第一道授权登录的鉴权界面。
- `lib/pages/workbench_page.dart` : 整个系统的**重中之重**。集成了“检测工作台”、“参数高级设置”、“项目保存与浏览”及“帮助声明”的所有交互事件面板，是应用使用时承接主要渲染的复合视图。
- `lib/services/backend_service.dart` / `detection_api_service.dart`: 承接所有对 `127.0.0.1:5000` 后端发送网络请求（图片、推理、参数调优）的驱动层。
- `lib/widgets/`: 此目录下分布的是在 workbench_page 抽离出去的解耦小件（如饼图 `defect_chart.dart` 等渲染块）。
