# EL / Solar Panel Defect Detection System (Open Source)

[English](./README_EN.md) | [简体中文](./README.md)

<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/FastAPI-0.100+-009688?logo=fastapi" alt="FastAPI">
  <img src="https://img.shields.io/badge/ONNX_Runtime-1.15+-blue?logo=onnx" alt="ONNX Runtime">
  <img src="https://img.shields.io/badge/platform-Windows-lightgrey" alt="Platform">
</p>

<p align="center">
  <img src="./docs/images/workspace.png" alt="Main Workspace" width="800">
  <br>
  <em>A modern, geek-styled dark theme workflow powered by Flutter, supporting hardware acceleration, Deep Zoom, and high-FPS mask rendering.</em>
</p>

<p align="center">
  <img src="./docs/images/settings.png" alt="Parameter Settings" width="400">
  <img src="./docs/images/history.png" alt="History and Export" width="400">
  <br>
  <em>Dynamic model hot-reloading configurations (left) alongside comprehensive project history and multi-format reporting (right).</em>
</p>

This project is a powerful and fully open-source (under the **GNU GPLv3** license) solar panel defect detection system. Utilizing a decoupled frontend-backend architecture, it features a modern, cross-platform desktop frontend built with Flutter, and a high-performance local AI inference backend driven by FastAPI, OpenCV, and ONNX Runtime. It operates completely offline, delivering high-speed, high-precision AI defect recognition and report generation services.

## 🌟 Key Features

### 1. Core AI Vision Detection Architecture
* **Ultra-Fast Inference Engine**: Integrated local ONNX Runtime and OpenCV DNN engine with an automatic optimization mechanism. It executes millisecond-level defect detection natively without relying on any network connectivity or commercial cloud quotas.
* **Dual-Mode Detection Fusion**: Supports both **Object Detection** and **Instance Segmentation** algorithms, providing precise pixel-level mask annotations for complex solar panel defects such as micro-cracks, broken gridlines, debris, and hotspots.
* **Seamless Model Switching**: The backend supports flexible mounting of arbitrary ONNX format weights. It allows dynamic hot-loading and custom parameter adjustments (Confidence, IoU thresholds, etc.) across various application scenarios.

### 2. Modern Workspace & Visualization
* **Extreme Performance Frontend**: A cross-platform Windows desktop application built on Flutter 3, featuring a geek-styled Dark Theme workflow and hardware acceleration engine support.
* **Smart Image Management & Zoom**: Drag-and-drop support, directory cascade loading, and continuous "Deep Zoom" capabilities built for super-resolution industrial cameras (> 100 Megapixels).
* **Perspective Cropping & Auto-Correction**: Equipped with edge filters and a 4-point perspective transformation algorithm to automatically correct perspective distortions with a single click.

### 3. Dynamic Report Generation & Data Export
* **Multi-Modal Output Options**: Supports local export of the original images alongside the inference results highlighting Bounding Boxes (BBox) and Masks.
* **Structured Data Retention**: Generates full statistical results along with defect category distribution matrices, exportable as CSV/Excel formats instantly.
* **Automated Word Document Build**: Pre-set layout templates for solar panel defect reports. Capable of rendering and exporting `.docx` and PDF reports featuring original dimensions, panel IDs, detail lists, and comprehensive conclusions.

---

## 💻 Installation and Development Guide

This guide is primarily for the Windows environment. You can either run the pre-compiled application directly or build from the source code for further development.

<!-- TODO: UPDATE THIS LINK AFTER PUBLISHING GITHUB RELEASES -->
> **📥 Out-of-the-Box Download**
> If you're not familiar with programming environments, please visit the [Releases Page](https://github.com/YourUsername/YourRepo/releases) directly to download the latest portable / installer version!

### Prerequisites for Source Execution
1. **OS**: Windows 10/11 (64-bit)
2. **Python**: Python 3.10 or 3.11 (Recommended)
3. **Flutter**: Flutter SDK (3.24+ Recommended)

### 1. Backend Setup & Startup (FastAPI)

The backend acts as the core inference node and local API server running on `http://127.0.0.1:5000`.

```bash
# 1. Switch to backend directory
cd backend

# 2. Create and activate a Virtual Environment (Recommended)
python -m venv .venv
.\.venv\Scripts\activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Start backend server
python run_server.py --port 5000 --log-level info
# The server is successfully running when you see "Uvicorn running on http://0.0.0.0:5000" in the terminal.
```

### 2. Frontend Setup & Startup (Flutter)

The frontend handles user interaction and rich visual rendering. This repository doesn't embed the SDK, so you need to configure Flutter manually.

**Install Steps:**
1. **Download SDK**: Get the Windows stable release from the [Flutter Official Docs](https://docs.flutter.dev/get-started/install/windows/desktop).
2. **Configure Environment Variables**: Add `flutter\bin` to your system's `PATH`.
3. **Verify**: Run `flutter doctor` in your terminal to ensure the SDK and Desktop Build tools (Visual Studio 2022) are correctly installed.

**Run the App:**
```bash
# 1. Switch to frontend directory
cd frontend

# 2. Fetch dependencies
flutter pub get

# 3. Run on Windows desktop
flutter run -d windows
# The application will launch automatically once compilation finishes.
```

### 3. Convenient One-Click Startup Script
For routine dual-end development/testing, you can simply run `scripts\startup_dev.bat` situated at the root path, which automatically triggers both Python and the desktop application in the background (provided initial build prerequisites are met).

---

## 🔮 Roadmap & Future Plans

This system is evolving towards a full-coverage tool ecosystem for solar lifecycle operations. Upcoming milestones include:

1. **Word Template Reverse Engineering**: Dynamically reverse-parse the user's custom `.docx` templates. The frontend will populate visual fill-in fields and seamlessly overlay the bounding boxes onto complex customized client reports.
2. **Infrared Drone Thermal Detection**: Introduce Thermal Infrared (IR) interfaces to execute fine-grained positioning and analysis of hotspots and hidden bypass diode failures throughout the solar panels' lifecycle.
3. **RGB Drone Aerial Defect Localization**: Incorporate visible-light high-altitude image stitching, paired with GPS EXIF mappings. This targets dust, bird debris, cracking, and shading on physical panel surfaces, pinpointing accurately their geometry inside huge field arrays.

This codebase is distributed under the strict **GPLv3** open-source license. If you intend to utilize this for any custom distributions or commercial environments, please ensure you carry forward the license requirements.
