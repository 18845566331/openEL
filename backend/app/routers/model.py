"""模型管理路由模块（纯本地开源版）。"""

import json
import logging
from typing import Any
from pathlib import Path
from fastapi import APIRouter, HTTPException

logger = logging.getLogger(__name__)

router = APIRouter()

from app.schemas import ModelLoadRequest
from app.state import engine


@router.post("/api/model/load")
def load_model(request: ModelLoadRequest) -> dict[str, Any]:
    # 需求 1.2: 模型文件不存在或路径无效时返回明确的错误信息
    model_file = Path(request.model_path).expanduser().resolve()
    if not model_file.exists():
        # 需求 11.6: 提供明确的文件路径和失败原因
        logger.error("模型文件不存在: path=%s", model_file)
        raise HTTPException(status_code=400, detail=f"模型文件不存在: {model_file}")
    try:
        # 需求 11.4: 记录模型加载事件
        logger.info(
            "开始加载模型: path=%s, engine=%s, input=%dx%d, layout=%s",
            model_file,
            request.backend_preference,
            request.input_width,
            request.input_height,
            request.output_layout,
        )
        # 创建模型加载配置
        from app.detector import ModelLoadConfig
        config = ModelLoadConfig(
            model_path=request.model_path,
            model_type=request.model_type,
            labels=request.labels,
            input_width=request.input_width,
            input_height=request.input_height,
            output_layout=request.output_layout,
            normalize=request.normalize,
            swap_rb=request.swap_rb,
            confidence_threshold=request.confidence_threshold,
            iou_threshold=request.iou_threshold,
            backend_preference=request.backend_preference,
        )
        runtime = engine.load_model(config)
    except FileNotFoundError as exc:
        logger.error("模型加载失败 - 文件不存在: path=%s, error=%s", model_file, exc)
        raise HTTPException(status_code=400, detail=f"文件不存在: {exc}") from exc
    except ValueError as exc:
        logger.error("模型加载失败 - 参数错误: path=%s, error=%s", model_file, exc)
        raise HTTPException(status_code=400, detail=f"参数错误: {exc}") from exc
    except Exception as exc:  # noqa: BLE001
        logger.error("模型加载失败: path=%s, error=%s", model_file, exc, exc_info=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    logger.info(
        "模型加载成功: backend=%s, path=%s, labels=%d个",
        runtime.get("backend"),
        model_file,
        len(request.labels),
    )
    return {"message": "模型加载成功", "runtime": runtime}


@router.post("/api/model/load_profile")
def load_model_by_profile(profile_path: str) -> dict[str, Any]:
    # 需求 8.3: 通过配置文件加载模型
    # 需求 1.2: 文件不存在时返回明确的错误信息
    config_file = Path(profile_path).expanduser().resolve()
    if not config_file.exists():
        # 需求 11.6: 提供明确的文件路径和失败原因
        logger.error("配置文件不存在: path=%s", config_file)
        raise HTTPException(status_code=400, detail=f"配置文件不存在: {config_file}")
    try:
        logger.info("读取模型配置文件: %s", config_file)
        raw_text = config_file.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        logger.error("无法读取配置文件: path=%s, error=%s", config_file, exc)
        raise HTTPException(status_code=400, detail=f"无法读取配置文件: {exc}") from exc
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        logger.error("配置文件JSON格式无效: path=%s, error=%s", config_file, exc)
        raise HTTPException(status_code=400, detail=f"配置文件JSON格式无效: {exc}") from exc
    try:
        request = ModelLoadRequest(**data)
    except Exception as exc:  # noqa: BLE001
        logger.error("配置文件参数验证失败: path=%s, error=%s", config_file, exc)
        raise HTTPException(status_code=400, detail=f"配置文件参数验证失败: {exc}") from exc
    return load_model(request)
