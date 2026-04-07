# Backend 使用说明

## 启动

```powershell
python run_server.py --host 127.0.0.1 --port 5000
```

## 主要接口

### 1) 加载模型

`POST /api/model/load`

```json
{
  "model_path": "D:/models/el.onnx",
  "labels": ["隐裂", "断栅", "黑斑"],
  "input_width": 640,
  "input_height": 640,
  "output_layout": "cxcywh_obj_cls",
  "confidence_threshold": 0.55,
  "iou_threshold": 0.45
}
```

### 2) 单图检测

`POST /api/detect`

```json
{
  "image_path": "D:/images/a.png",
  "confidence_threshold": 0.55,
  "iou_threshold": 0.45
}
```

### 3) 批量检测

`POST /api/detect/batch`

```json
{
  "input_dir": "D:/images",
  "recursive": true,
  "confidence_threshold": 0.55,
  "iou_threshold": 0.45
}
```

