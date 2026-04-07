from __future__ import annotations

from pydantic import BaseModel, Field

from enum import Enum

class ModelType(str, Enum):
    EL = "EL"
    IR = "IR"
    RGB = "RGB"

class ModelLoadRequest(BaseModel):
    model_path: str = Field(..., description="本地 ONNX 模型路径")
    model_type: str = Field(default="EL", description="模式类型: EL/IR/RGB")
    labels: list[str] = Field(default_factory=list, description="缺陷类别名称")
    input_width: int = Field(default=640, ge=64, le=4096)
    input_height: int = Field(default=640, ge=64, le=4096)
    output_layout: str = Field(
        default="cxcywh_obj_cls",
        description="输出布局: cxcywh_cls(Anchor-Free) / cxcywh_obj_cls(Anchor-Based) / xyxy_score_class / cxcywh_score_class / auto(自动检测)",
    )
    normalize: bool = True
    swap_rb: bool = True
    confidence_threshold: float = Field(default=0.55, ge=0.0, le=1.0)
    iou_threshold: float = Field(default=0.45, ge=0.0, le=1.0)
    backend_preference: str = Field(default="onnxruntime")


class DetectRequest(BaseModel):
    image_path: str
    confidence_threshold: float | None = Field(default=None, ge=0.0, le=1.0)
    iou_threshold: float | None = Field(default=None, ge=0.0, le=1.0)
    save_visualization: bool = False
    visualization_dir: str | None = None
    stroke_width: int = Field(default=2, ge=1, le=20, description="标注框线宽")
    font_size: int = Field(default=16, ge=8, le=72, description="标签字体大小")
    show_boxes: bool = Field(default=True, description="是否显示标注框")
    show_labels: bool = Field(default=True, description="是否显示标签名称")
    show_confidence: bool = Field(default=True, description="是否显示置信度")


class BatchDetectRequest(BaseModel):
    input_dir: str
    recursive: bool = False
    extensions: list[str] = Field(
        default_factory=lambda: [".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"]
    )
    max_images: int = Field(default=5000, ge=1, le=200000)
    confidence_threshold: float | None = Field(default=None, ge=0.0, le=1.0)
    iou_threshold: float | None = Field(default=None, ge=0.0, le=1.0)
    save_visualization: bool = False
    visualization_dir: str | None = None
    stroke_width: int = Field(default=2, ge=1, le=20, description="标注框线宽")
    font_size: int = Field(default=16, ge=8, le=72, description="标签字体大小")
    show_boxes: bool = Field(default=True, description="是否显示标注框")
    show_labels: bool = Field(default=True, description="是否显示标签名称")
    show_confidence: bool = Field(default=True, description="是否显示置信度")


