import json
from pathlib import Path
import sys, os

# Add backend dir to sys.path (use relative path based on script location)
script_dir = Path(__file__).parent
backend_dir = script_dir / "backend"
sys.path.insert(0, str(backend_dir))

from app.main import _export_word_from_template

mock_info = {
    "报告编号": "TEST-123",
    "pv_modules": [
        {"生产厂家": "Manufacturer 1", "型号": "Model A"}
    ],
    "defect_by_class": {
        "A类": 5,
        "B类": 10
    },
    "file_results": [
        {"name": "S0000018_A.jpg", "path": "E:\\湖北荆州\\新建文件夹\\S0000018_A.jpg", "result": "NG"}
    ],
    "rotate_images": False,
    "img_width_cm": 10.0,
    "img_height_cm": 5.0,
    "img_quality": 85
}

# 使用相对路径查找模板
template_path = backend_dir / "光伏组件EL检测报告模板.docx"
if not template_path.exists():
    # 尝试上一级目录
    template_path = script_dir.parent / "光伏组件EL检测报告模板.docx"
output_path = str(script_dir / "mock_test.docx")

try:
    _export_word_from_template(mock_info, output_path, template_path)
    print("Mock export complete.")
except Exception as e:
    print(f"Export failed: {e}")
