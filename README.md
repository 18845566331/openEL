# EL/光伏组件缺陷检测系统 (开源版)

[English](./README_EN.md) | [简体中文](./README.md)

<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/FastAPI-0.100+-009688?logo=fastapi" alt="FastAPI">
  <img src="https://img.shields.io/badge/ONNX_Runtime-1.15+-blue?logo=onnx" alt="ONNX Runtime">
  <img src="https://img.shields.io/badge/platform-Windows-lightgrey" alt="Platform">
</p>

<p align="center">
  <img src="./docs/images/workspace.png" alt="主工作台界面" width="800">
  <br>
  <em>基于 Flutter 的现代化暗黑极客风工作流，支持硬件加速、深缩放（Deep Zoom）与高帧率掩膜渲染。</em>
</p>

<p align="center">
  <img src="./docs/images/settings.png" alt="参数配置面板" width="400">
  <img src="./docs/images/history.png" alt="历史管理与导出界面" width="400">
  <br>
  <em>灵活的模型可热载、微调参数化面板（左）及项目级检验历史与多格式一键导出功能（右）。</em>
</p>

本项目是一个功能强大且完全开源（基于 **GNU GPLv3** 协议）的光伏组件缺陷检测系统。系统采用前后端分离架构，由基于 Flutter 的现代化跨平台桌面应用前端，以及基于 FastAPI + OpenCV + ONNX Runtime 的高性能本地化引擎后端构成，能够实现离线状态下高速、高精度的 AI 缺陷识别和报告生成服务。

## 🌟 核心功能特色

### 一、 核心 AI 视觉检测体系
* **极速推理引擎**：内置本地化的 ONNX Runtime 与 OpenCV DNN 模型双引擎自动寻优机制，无需依赖联网或云端商业配额约束，完全在本地直接完成毫秒级缺陷检测。
* **双模检测融合**：同时支持 **目标检测 (Object Detection)** 和 **实例分割 (Instance Segmentation)** 双算法架构，对于隐裂、断栅、碎片、热斑等复杂类型的组件缺陷提供像素级的分割标注。
* **多模型无缝切换**：后端可灵活挂载任意 YOLO/ONNX 格式导出权重，支持多应用场景下模型文件、推理精度（置信度、IoU等）的动态热载及自定义配置。

### 二、 现代化工作台与可视化
* **极致性能前端**：基于 Flutter 3 构建的跨桌面端 (Windows) 程序，支持硬件渲染引擎加速。拥有暗黑极客主题风格工作流。
* **智能图像管理与缩放**：支持拖拽导入/文件夹级联读取、支持数亿像素级超大尺寸工业相机的深缩放（Deep Zoom）以及交互式掩膜层高亮、缩略视图管理等。
* **透视裁剪与自动矫正**：集成边缘滤波器与 4 点透视变换算法，能将含有畸变、非正拍视角的组件相片一键矫正输出。

### 三、 动态报告生成与数据导出
* **多模态结果输出**：检测完毕后，不仅提供原图与带边界框（BBox）/掩膜（Mask）的结果图本地导出。
* **结构化数据留存**：一键生成全量统计结果并附带缺陷类别分布矩阵，实时生成 CSV / Excel。
* **Word自动化构建**：预设光伏缺陷报告定制排版模块，支持导出并渲染含有原始尺寸、组件编号、明细列表和结论的 `.docx` 以及 PDF 文件。

---

## 💻 运行与安装开发指南

本指南主要面向 Windows 环境。你可以直接通过预编译好的包进行运行，或使用源码进行二次开发。

<!-- TODO: 当你在 GitHub 发布了 Releases (例如软件打包的 .exe 或 .zip)，请更新此处的下载链接 -->
> **📥 开箱即用版下载**
> 如果你不熟悉开发环境配置，请直接访问 [Releases 发布页](https://github.com/你的用户名/你的项目名/releases) 下载最新的绿色免安装版本直接运行！

### 源码运行的基础环境准备
1. **系统环境**: Windows 10/11 (64-bit)
2. **Python**: Python 3.10 或 3.11（建议）
3. **Flutter**: Flutter SDK (建议版本 3.24+)

### 1. 后端依赖安装与启动 (FastAPI)

后端作为系统核心推理和数据输出代理节点，提供了脱机下的 `http://127.0.0.1:5000` AI API。

```bash
# 1. 切换至项目后端目录
cd backend

# 2. 创建并激活虚拟环境 (推荐)
python -m venv .venv
.\.venv\Scripts\activate

# 3. 安装依赖包
pip install -r requirements.txt

# 4. 启动后端服务器
python run_server.py --port 5000 --log-level info
# 终端看到 "Uvicorn running on http://0.0.0.0:5000 (Press CTRL+C to quit)" 即启动成功。
```

### 2. 前端依赖安装与启动 (Flutter)

前端负责用户交互与渲染展示。本项目不包含 Flutter SDK（以便保持仓库轻量），您需要自行安装并配置。

**安装步骤：**
1. **下载 SDK**: 请前往 [Flutter 官网](https://docs.flutter.dev/get-started/install/windows/desktop) 下载适用于 Windows 的稳定版 SDK。
2. **配置环境变量**: 将下载好的 `flutter\bin` 目录路径添加至系统的 `Path` 环境变量中。
3. **验证安装**: 在终端运行 `flutter doctor`，确保 Flutter 和 Windows 桌面开发环境（Visual Studio 2022）已正确安装。

**运行应用：**
```bash
# 1. 切换至项目前端目录
cd frontend

# 2. 拉取 Flutter pub 库依赖
flutter pub get

# 3. 运行 Windows 桌面应用
flutter run -d windows
# 应用在编译完成后将自动在桌面弹出。
```

### 3. 一次性便捷启动脚本部署
如果你为了日常双端测试，也可以利用项目根目录下的 `scripts\startup_dev.bat` (如果你之前已有构建)，双击运行即可在后台同时拉起 Python 与桌面端程序。

---

## 🔮 探索与计划 (Roadmap)

本系统正朝着一套全面覆盖光伏组件运维体系的工具生态进化。未来的重要迭代方向包括：

1. **Word模板逆向动态读取：** 动态解析用户的 `.docx` 自定义空模板，生成前端可视化填写字段项，结果一键映射还原出原始排版的复杂客户报告。
2. **红外无人机缺陷探测：** 引入红外温度传感（IR）识别接口，对组件全生命周期的热斑、隐蔽二极管损坏等严重问题进行精细化定位分析。
3. **RGB无人机外观缺陷探测：** 添加可见光高空航拍影像组拼分析能力与经纬度(GPS EXIF)映射算法，在全景图中直接高亮出玻璃表面的灰尘、鸟粪、碎裂和遮挡物，精准定位其在大阵列中的物理排布。

本项目代码仅做交流使用，采用严格的 **GPLv3** 开源协议分发，若您作为开源贡献使用，请确保完整继承并公示源代码。
