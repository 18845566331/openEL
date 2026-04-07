import os
import io
import time
import json
import uuid
import shutil
import base64
import zipfile
import urllib.parse
from typing import Any, List, Optional
from fastapi import APIRouter, HTTPException, File, UploadFile, Form, BackgroundTasks
from fastapi.responses import JSONResponse, Response, FileResponse, StreamingResponse
from pydantic import BaseModel
import cv2
import numpy as np
import requests as _requests_lib
import logging
from datetime import datetime


from app.exif_helper import _ExifGpsHelper, _read_exif_bytes, _save_crop_with_exif



router = APIRouter()

from pathlib import Path
from app.schemas import *
from app.state import _loaded_model_id, _model_profiles_cache, _cache_lock, engine


from app.schemas import DetectionResponse, ImageDetectResponse, SegmentRequest
from app.detector import segment_image, extract_boxes_for_batch
def debug_raw_output(request: DetectRequest) -> dict[str, Any]:
    """调试端点：返回模型原始输出的形状和数值统计信息。"""
    from pathlib import Path
    import numpy as np

    with engine._lock:
        if engine._runtime is None:
            raise HTTPException(status_code=400, detail="模型未加载")
        runtime = engine._runtime

        image = _imread_unicode(request.image_path)
        if image is None:
            raise HTTPException(status_code=400, detail=f"无法读取图像: {request.image_path}")

        blob, scale, pad_x, pad_y = engine._preprocess(
            image, runtime.input_size, normalize=runtime.normalize, swap_rb=runtime.swap_rb
        )
        raw_outputs = engine._inference(blob, runtime)

        output_info = []
        for i, out in enumerate(raw_outputs):
            arr = np.asarray(out, dtype=np.float32)
            output_info.append({
                "index": i,
                "shape": list(arr.shape),
                "dtype": str(arr.dtype),
                "min": float(np.min(arr)),
                "max": float(np.max(arr)),
                "mean": float(np.mean(arr)),
                "std": float(np.std(arr)),
            })

        # 分析第一个输出的详细结构
        pred = np.asarray(raw_outputs[0], dtype=np.float32)
        while pred.ndim > 2 and pred.shape[0] == 1:
            pred = pred[0]

        # 尝试不同的解析方式
        analysis = {
            "squeezed_shape": list(pred.shape),
            "scale": scale,
            "pad_x": pad_x,
            "pad_y": pad_y,
            "image_size": [image.shape[1], image.shape[0]],
            "input_size": list(runtime.input_size),
        }

        # 如果是 [N, C] 或 [C, N] 格式
        if pred.ndim == 2:
            rows, cols = pred.shape
            analysis["dim0_x_dim1"] = f"{rows}x{cols}"
            # 取前5行看看数据
            sample_rows = min(5, rows)
            sample_cols = min(20, cols)
            analysis["first_rows_raw"] = pred[:sample_rows, :sample_cols].tolist()

            # 如果需要转置 (YOLOv8 格式: [num_features, num_boxes])
            if rows < cols:
                pred_t = pred.T
                analysis["transposed_shape"] = list(pred_t.shape)
                analysis["first_rows_transposed"] = pred_t[:sample_rows, :sample_cols].tolist()

        return {
            "outputs": output_info,
            "analysis": analysis,
            "current_layout": runtime.output_layout,
        }




@router.post("/api/detect")
def detect_single(request: DetectRequest) -> dict[str, Any]:
    # 需求 11.5: 记录检测任务的开始和完成
    logger.info("单张检测开始: image=%s", request.image_path)
    start_time = time.perf_counter()
    try:
        result = engine.detect_image(
            request.image_path,
            confidence_threshold=request.confidence_threshold,
            iou_threshold=request.iou_threshold,
            save_visualization=request.save_visualization,
            visualization_dir=request.visualization_dir,
            stroke_width=request.stroke_width,
            font_size=request.font_size,
            show_boxes=request.show_boxes,
            show_labels=request.show_labels,
            show_confidence=request.show_confidence,
        )
    except RuntimeError as exc:
        logger.error("单张检测失败 - 模型未就绪: image=%s, error=%s", request.image_path, exc)
        raise HTTPException(
            status_code=400, detail=f"模型未就绪: {exc}"
        ) from exc
    except FileNotFoundError as exc:
        # 需求 11.6: 提供明确的文件路径和失败原因
        logger.error("单张检测失败 - 文件不存在: image=%s, error=%s", request.image_path, exc)
        raise HTTPException(
            status_code=400, detail=f"文件不存在: {exc}"
        ) from exc
    except ValueError as exc:
        logger.error("单张检测失败 - 数据错误: image=%s, error=%s", request.image_path, exc)
        raise HTTPException(
            status_code=400, detail=f"数据错误: {exc}"
        ) from exc
    except Exception as exc:
        logger.error("单张检测失败: image=%s, error=%s", request.image_path, exc, exc_info=True)
        raise HTTPException(
            status_code=400, detail=f"检测失败: {exc}"
        ) from exc
    finally:
        elapsed_ms = (time.perf_counter() - start_time) * 1000
        with _perf_lock:
            _perf_metrics["detect_times"].append(elapsed_ms)
    
    logger.info(
        "单张检测完成: image=%s, defects=%d, time=%.1fms",
        request.image_path,
        result.get("total", 0),
        elapsed_ms,
    )
    return result


import uuid

@router.post("/api/detect/batch")
def detect_batch(request: BatchDetectRequest) -> dict[str, Any]:
    # 需求 11.5: 记录检测任务的开始和完成
    start_time = time.perf_counter()
    job_id = str(uuid.uuid4())
    
    logger.info(
        "批量检测开始: job_id=%s, dir=%s, recursive=%s, extensions=%s, max_images=%d",
        job_id,
        request.input_dir,
        request.recursive,
        request.extensions,
        request.max_images,
    )
    
    try:
        input_dir = Path(request.input_dir).expanduser().resolve()
        if not input_dir.exists() or not input_dir.is_dir():
            # 需求 11.6: 提供明确的文件路径和失败原因
            logger.error("输入目录不存在: path=%s", input_dir)
            raise HTTPException(
                status_code=400, detail=f"输入目录不存在: {input_dir}"
            )

        patterns = {
            ext.lower() if ext.startswith(".") else f".{ext.lower()}"
            for ext in request.extensions
        }
        iterator = input_dir.rglob("*") if request.recursive else input_dir.glob("*")
        images = [
            item
            for item in iterator
            if item.is_file() and item.suffix.lower() in patterns
        ]
        images = sorted(images)[: request.max_images]
        total_images = len(images)
        logger.info("批量检测扫描到 %d 张图像", total_images)
        
        # 初始化任务状态
        with _batch_jobs_lock:
            _batch_jobs[job_id] = {
                "status": "running",
                "total": total_images,
                "completed": 0,
                "progress": 0,
                "start_time": start_time,
                "input_dir": request.input_dir,
                "results": []
            }
        
        if not images:
            logger.info("批量检测完成: 未找到匹配的图像文件")
            with _batch_jobs_lock:
                _batch_jobs[job_id]["status"] = "completed"
                _batch_jobs[job_id]["progress"] = 100
            return {
                "job_id": job_id,
                "total_images": 0,
                "ok_images": 0,
                "ng_images": 0,
                "total_defects": 0,
                "defect_by_class": {},
                "results": [],
                "status": "completed"
            }

        results: list[dict[str, Any]] = []
        class_counter: Counter[str] = Counter()
        ng_images = 0
        completed_count = 0

        # 并发处理函数
        def process_image(image):
            nonlocal completed_count
            try:
                result = engine.detect_image(
                    image.as_posix(),
                    confidence_threshold=request.confidence_threshold,
                    iou_threshold=request.iou_threshold,
                    save_visualization=request.save_visualization,
                    visualization_dir=request.visualization_dir,
                    stroke_width=request.stroke_width,
                    font_size=request.font_size,
                    show_boxes=request.show_boxes,
                    show_labels=request.show_labels,
                    show_confidence=request.show_confidence,
                )
            except Exception as exc:
                # 需求 3.7: 记录错误信息并继续处理其他图像
                logger.warning(
                    "批量检测中单张图像失败: image=%s, error=%s",
                    image.as_posix(),
                    exc,
                )
                result = {
                    "image_path": image.as_posix(),
                    "total": 0,
                    "detections": [],
                    "visualization_path": None,
                    "error": str(exc),
                }
            finally:
                # 更新进度
                completed_count += 1
                progress = int((completed_count / total_images) * 100)
                with _batch_jobs_lock:
                    if job_id in _batch_jobs:
                        _batch_jobs[job_id]["completed"] = completed_count
                        _batch_jobs[job_id]["progress"] = progress
            return result

        # 使用线程池并发处理
        import concurrent.futures
        max_workers = min(int(os.getenv("MAX_WORKERS", "4")), total_images)  # 限制并发数，避免系统过载
        logger.info("启动并发处理，线程数: %d", max_workers)
        
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            # 提交所有任务
            future_to_image = {
                executor.submit(process_image, image): image
                for image in images
            }
            
            # 收集结果
            for future in concurrent.futures.as_completed(future_to_image):
                result = future.result()
                if result.get("total", 0) > 0:
                    ng_images += 1
                    for item in result.get("detections", []):
                        class_counter[item["class_name"]] += 1
                results.append(result)

        summary = {
            "job_id": job_id,
            "total_images": total_images,
            "ok_images": total_images - ng_images,
            "ng_images": ng_images,
            "total_defects": int(sum(class_counter.values())),
            "defect_by_class": dict(class_counter),
            "results": results,
            "status": "completed"
        }
        
        elapsed_ms = (time.perf_counter() - start_time) * 1000
        logger.info(
            "批量检测完成: job_id=%s, total=%d, ok=%d, ng=%d, defects=%d, time=%.1fms",
            job_id,
            summary["total_images"],
            summary["ok_images"],
            summary["ng_images"],
            summary["total_defects"],
            elapsed_ms,
        )
        
        # 更新任务状态为完成
        with _batch_jobs_lock:
            if job_id in _batch_jobs:
                _batch_jobs[job_id]["status"] = "completed"
                _batch_jobs[job_id]["progress"] = 100
                _batch_jobs[job_id]["results"] = results
                _batch_jobs[job_id]["elapsed_ms"] = elapsed_ms
        
        with _perf_lock:
            _perf_metrics["batch_detect_times"].append(elapsed_ms)
        
        return summary
    except HTTPException:
        # 更新任务状态为失败
        with _batch_jobs_lock:
            if job_id in _batch_jobs:
                _batch_jobs[job_id]["status"] = "failed"
        raise
    except RuntimeError as exc:
        logger.error("批量检测失败 - 模型未就绪: error=%s", exc)
        with _batch_jobs_lock:
            if job_id in _batch_jobs:
                _batch_jobs[job_id]["status"] = "failed"
        raise HTTPException(
            status_code=400, detail=f"模型未就绪: {exc}"
        ) from exc
    except PermissionError as exc:
        logger.error("批量检测失败 - 权限不足: dir=%s, error=%s", request.input_dir, exc)
        with _batch_jobs_lock:
            if job_id in _batch_jobs:
                _batch_jobs[job_id]["status"] = "failed"
        raise HTTPException(
            status_code=400, detail=f"目录访问权限不足: {exc}"
        ) from exc
    except Exception as exc:
        logger.error("批量检测失败: dir=%s, error=%s", request.input_dir, exc, exc_info=True)
        with _batch_jobs_lock:
            if job_id in _batch_jobs:
                _batch_jobs[job_id]["status"] = "failed"
        raise HTTPException(
            status_code=400, detail=f"批量检测失败: {exc}"
        ) from exc
    finally:
        if 'start_time' in locals():
            elapsed_ms = (time.perf_counter() - start_time) * 1000
            with _perf_lock:
                _perf_metrics["batch_detect_times"].append(elapsed_ms)


@router.post("/api/analyze/cell_brightness")
def analyze_cell_brightness(request: dict[str, Any]) -> dict[str, Any]:
    """
    明暗片辅助检测 - 按 Q/NOA J0618-2024 第16条标准分析每格灰度差值。
    将图像按 rows × cols 均匀切割，计算每格平均灰度值，
    以全图中位数为基准计算相对差值百分比，并按标准分级(A/B/C)。
    """
    import cv2
    import numpy as np

    image_path = request.get("image_path", "")
    rows = int(request.get("rows", 6))
    cols = int(request.get("cols", 10))
    ref_mode = request.get("ref_mode", "median")  # "mean" 或 "median"
    threshold_a = float(request.get("threshold_a", 15.0))
    threshold_b = float(request.get("threshold_b", 30.0))
    threshold_c = float(request.get("threshold_c", 50.0))


    if not image_path:
        raise HTTPException(status_code=400, detail="未指定 image_path")
    if rows <= 0 or cols <= 0:
        raise HTTPException(status_code=400, detail="rows 和 cols 必须大于 0")

    img_path = Path(image_path).expanduser().resolve()
    if not img_path.exists():
        raise HTTPException(status_code=400, detail=f"图像文件不存在: {img_path}")

    # 读取图像（支持中文路径）
    img_bytes = np.fromfile(str(img_path), dtype=np.uint8)
    img = cv2.imdecode(img_bytes, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise HTTPException(status_code=400, detail="无法读取图像文件")

    h, w = img.shape

    # 计算全图参考值（中位数或均值）
    if ref_mode == "mean":
        global_ref = float(np.mean(img))
    else:
        global_ref = float(np.median(img))

    # 计算每个单元格的均值及差值百分比
    cell_height = h / rows
    cell_width = w / cols
    cells = []
    all_means = []

    for r in range(rows):
        row_cells = []
        y1 = int(round(r * cell_height))
        y2 = int(round((r + 1) * cell_height))
        for c in range(cols):
            x1 = int(round(c * cell_width))
            x2 = int(round((c + 1) * cell_width))
            cell_region = img[y1:y2, x1:x2]
            if cell_region.size == 0:
                cell_mean = 0.0
            else:
                cell_mean = float(np.mean(cell_region))
            all_means.append(cell_mean)
            row_cells.append({"row": r, "col": c, "mean": round(cell_mean, 2)})
        cells.append(row_cells)

    # 用所有单元格均值的中位数( 或均值 )作为基准，更稳健
    cell_means_arr = np.array(all_means)
    if ref_mode == "mean":
        base_val = float(np.mean(cell_means_arr))
    else:
        base_val = float(np.median(cell_means_arr))

    # 防止除零
    if base_val < 1.0:
        base_val = 1.0

    # 分级统计 (Q/NOA J0618-2024 第16条)
    grade_A = 0      
    grade_B = 0  
    grade_C = 0    
    grade_D = 0   

    for r in range(rows):
        for c in range(cols):
            cell_mean = cells[r][c]["mean"]
            diff_pct = abs(cell_mean - base_val) / base_val * 100.0
            cells[r][c]["diff_pct"] = round(diff_pct, 1)

            if diff_pct <= threshold_a:
                grade = "A"
                grade_A += 1
            elif diff_pct <= threshold_b:
                grade = "B"
                grade_B += 1
            elif diff_pct <= threshold_c:
                grade = "C"
                grade_C += 1
            else:
                grade = "D"
                grade_D += 1
            cells[r][c]["grade"] = grade

    # 总体评价
    if grade_D > 0:
        overall_grade = "D"
    elif grade_C > 0:
        overall_grade = "C"
    elif grade_B > 0:
        overall_grade = "B"
    else:
        overall_grade = "A"

    summary = {
        "total_cells": rows * cols,
        "grade_A": grade_A,
        "grade_B": grade_B,
        "grade_C": grade_C,
        "grade_D": grade_D,
        "overall_grade": overall_grade
    }
    logger.info(
        "明暗片分析完成: image=%s, rows=%d, cols=%d, base=%.1f, A=%d B=%d C=%d D=%d overall=%s",
        image_path, rows, cols, base_val, grade_A, grade_B, grade_C, grade_D, overall_grade
    )

    return {
        "image_path": image_path,
        "rows": rows,
        "cols": cols,
        "global_ref": round(base_val, 2),
        "ref_mode": ref_mode,
        "cells": cells,
        "summary": summary
    }


@router.post("/api/segment")
def image_segment(request: dict[str, Any]) -> dict[str, Any]:
    """图片分割模式接口。"""
    import cv2
    import numpy as np

    image_path = request.get("image_path", "")
    filter_edges = request.get("filter_edges", True)
    auto_crop = request.get("auto_crop", False)
    perspective_crop = request.get("perspective_crop", False)
    expand_px = int(request.get("expand_px", 0))
    crop_quality = int(request.get("crop_quality", 95))
    custom_output_dir = request.get("output_dir", "")
    relative_subdir = request.get("relative_subdir", "")
    crop_out_w = int(request.get("crop_res_w", 0))
    crop_out_h = int(request.get("crop_res_h", 0))
    manual_quads = request.get("manual_quads", None)  # [[dx,dy],...] 归一化坐标
    do_crop = auto_crop or perspective_crop

    if not image_path:
        raise HTTPException(status_code=400, detail="未指定 image_path")

    # 1. 检查是否加载了模型
    desc = engine.describe()
    if not desc.get("model_loaded"):
        raise HTTPException(
            status_code=400, 
            detail="当前服务器没有上传或绑定分割模型，无法进行图片分割，请先加载专用模型。"
        )

    img_path = Path(image_path).expanduser().resolve()
    if not img_path.exists():
        raise HTTPException(status_code=400, detail=f"图像文件不存在: {img_path}")

    # 读取图像
    img_bytes = np.fromfile(str(img_path), dtype=np.uint8)
    img = cv2.imdecode(img_bytes, cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(status_code=400, detail="无法读取图像文件")

    h, w = img.shape[:2]

    # ── 初始化 GPS 智能计算器 ──
    _gps_helper = _ExifGpsHelper(str(img_path), w, h)
    if _gps_helper.has_gps:
        if _gps_helper.can_compute_offset:
            logger.info("已启用智能 GPS 偏移: 每个组件将获得独立的经纬度坐标")
        else:
            logger.info("原图有 GPS 但无法计算偏移（缺少相机参数），所有子图将共享相同坐标")
    _fallback_exif = _gps_helper.make_base_exif() if _gps_helper.has_gps else None

    if manual_quads and do_crop:
        logger.info("使用手动四边形裁剪: %d 个区域", len(manual_quads))
        if custom_output_dir:
            output_dir_path = Path(custom_output_dir)
            if relative_subdir:
                output_dir_path = output_dir_path / relative_subdir
        else:
            output_dir_path = img_path.parent / f"{img_path.stem}_crops"
        output_dir_path.mkdir(parents=True, exist_ok=True)
        output_dir = str(output_dir_path)

        crops = []
        for qi, quad_norm in enumerate(manual_quads):
            label = chr(65 + (qi % 26)) if qi < 26 else f"{chr(65 + qi // 26 - 1)}{chr(65 + qi % 26)}"
            # 归一化坐标 → 像素坐标
            pts_px = [[p[0] * w, p[1] * h] for p in quad_norm]
            src_points = np.float32(pts_px)

            # 透视裁剪
            if perspective_crop and len(pts_px) >= 4:
                try:
                    # 排序: TL→TR→BR→BL
                    pts_sorted = sorted(src_points, key=lambda p: (p[1], p[0]))
                    top = sorted(pts_sorted[:2], key=lambda p: p[0])
                    bottom = sorted(pts_sorted[2:], key=lambda p: p[0])
                    ordered = np.float32([top[0], top[1], bottom[1], bottom[0]])

                    cw = int(max(np.linalg.norm(ordered[0] - ordered[1]),
                                 np.linalg.norm(ordered[3] - ordered[2])))
                    ch = int(max(np.linalg.norm(ordered[0] - ordered[3]),
                                 np.linalg.norm(ordered[1] - ordered[2])))
                    if expand_px > 0:
                        cw += expand_px * 2
                        ch += expand_px * 2

                    dst = np.float32([[0, 0], [cw, 0], [cw, ch], [0, ch]])
                    M = cv2.getPerspectiveTransform(ordered, dst)
                    cell_region = cv2.warpPerspective(img, M, (cw, ch))
                except Exception as e:
                    logger.warning("手动透视裁剪失败 [%s]: %s", label, e)
                    # 回退到矩形裁剪
                    x1 = max(0, int(min(p[0] for p in pts_px)) - expand_px)
                    y1 = max(0, int(min(p[1] for p in pts_px)) - expand_px)
                    x2 = min(w, int(max(p[0] for p in pts_px)) + expand_px)
                    y2 = min(h, int(max(p[1] for p in pts_px)) + expand_px)
                    cell_region = img[y1:y2, x1:x2]
            else:
                # 矩形裁剪
                x1 = max(0, int(min(p[0] for p in pts_px)) - expand_px)
                y1 = max(0, int(min(p[1] for p in pts_px)) - expand_px)
                x2 = min(w, int(max(p[0] for p in pts_px)) + expand_px)
                y2 = min(h, int(max(p[1] for p in pts_px)) + expand_px)
                cell_region = img[y1:y2, x1:x2]

            if cell_region is not None and cell_region.size > 0:
                if crop_out_w > 0 and crop_out_h > 0:
                    cell_region = cv2.resize(cell_region, (crop_out_w, crop_out_h))
                crop_name = f"{img_path.stem}_{label}.jpg"
                crop_path = output_dir_path / crop_name
                # 计算该裁剪区域的中心像素坐标
                cx = sum(p[0] for p in pts_px) / len(pts_px)
                cy = sum(p[1] for p in pts_px) / len(pts_px)
                crop_exif = _gps_helper.make_exif_for_crop(cx, cy) or _fallback_exif
                _save_crop_with_exif(cell_region, str(crop_path), crop_quality, crop_exif)
                crops.append({"label": label, "path": str(crop_path)})

        return {
            "message": f"手动裁剪完成: {len(crops)} 张子图",
            "output_dir": output_dir,
            "total": len(manual_quads),
            "detections": [],
            "crops": crops
        }

    # 2. 调用分割推理引擎
    try:
        res = engine.detect_image_seg(
            image_path=str(img_path),
            confidence_threshold=desc.get("default_confidence", 0.5),
            iou_threshold=desc.get("default_iou", 0.45),
        )
        detections = res["detections"]
        seg_items = res.get("segmentation_items", [])
        is_seg = res.get("is_seg_model", False)
    except Exception as e:
        logger.error("图片分割模式检测失败: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail=f"图片分割检测失败: {e}")

    # 3. 过滤边缘并收集组件框
    margin = 15  # 距离边缘不到 15 像素的框剔除
    valid_boxes = []
    valid_seg_items = []
    
    for idx, det in enumerate(detections):
        box = det["box"]
        x1, y1, x2, y2 = box["x1"], box["y1"], box["x2"], box["y2"]
        # filter_edges 逻辑
        if filter_edges:
            if x1 < margin or y1 < margin or x2 > (w - margin) or y2 > (h - margin):
                continue
        valid_boxes.append([x1, y1, x2, y2, det])
        if idx < len(seg_items):
            valid_seg_items.append(seg_items[idx])

    if not valid_boxes:
        return {
            "message": "未检测到任何有效的光伏组件" if not filter_edges else "边缘过滤后未检测到有效组件",
            "output_dir": "",
            "total": 0,
            "detections": [],
            "crops": []
        }

    # 3.5 IoU 去重：同一位置的重复框只保留置信度最高的
    def _iou(a, b):
        ax1, ay1, ax2, ay2 = a[0], a[1], a[2], a[3]
        bx1, by1, bx2, by2 = b[0], b[1], b[2], b[3]
        ix1, iy1 = max(ax1, bx1), max(ay1, by1)
        ix2, iy2 = min(ax2, bx2), min(ay2, by2)
        inter = max(0, ix2 - ix1) * max(0, iy2 - iy1)
        area_a = (ax2 - ax1) * (ay2 - ay1)
        area_b = (bx2 - bx1) * (by2 - by1)
        union = area_a + area_b - inter
        return inter / union if union > 0 else 0

    keep_mask = [True] * len(valid_boxes)
    for j in range(len(valid_boxes)):
        if not keep_mask[j]:
            continue
        for k in range(j + 1, len(valid_boxes)):
            if not keep_mask[k]:
                continue
            if _iou(valid_boxes[j], valid_boxes[k]) > 0.5:
                # 保留置信度更高的
                score_j = valid_boxes[j][4].get("score", 0)
                score_k = valid_boxes[k][4].get("score", 0)
                if score_j >= score_k:
                    keep_mask[k] = False
                else:
                    keep_mask[j] = False
                    break

    dedup_boxes = [b for b, m in zip(valid_boxes, keep_mask) if m]
    dedup_seg = [s for s, m in zip(valid_seg_items, keep_mask) if m] if valid_seg_items else []
    removed = len(valid_boxes) - len(dedup_boxes)
    if removed > 0:
        logger.info("IoU 去重: 移除 %d 个重复框 (剩余 %d)", removed, len(dedup_boxes))
    valid_boxes = dedup_boxes
    valid_seg_items = dedup_seg

    # 4. 根据中心点横向坐标对框进行从左到右排序
    sort_key = [(item[0] + item[2]) / 2.0 for item in valid_boxes]
    sort_indices = sorted(range(len(valid_boxes)), key=lambda k: sort_key[k])
    valid_boxes = [valid_boxes[k] for k in sort_indices]
    valid_seg_items = [valid_seg_items[k] for k in sort_indices] if valid_seg_items else []

    # 5. 生成 A, B, C... 标签
    def get_label(index: int) -> str:
        res = ""
        while index >= 0:
            res = chr(65 + (index % 26)) + res
            index = index // 26 - 1
        return res

    output_dir = ""
    if do_crop:
        if custom_output_dir:
            # 使用自定义保存目录，保持输入文件的目录层级
            output_dir_path = Path(custom_output_dir)
            if relative_subdir:
                output_dir_path = output_dir_path / relative_subdir
        else:
            # 默认保存在源图同目录下的 {stem}_crops 文件夹
            output_dir_path = img_path.parent / f"{img_path.stem}_crops"
        output_dir_path.mkdir(parents=True, exist_ok=True)
        output_dir = str(output_dir_path)

    results = []
    filtered_detections = []
    for i, (x1, y1, x2, y2, det_info) in enumerate(valid_boxes):
        label = get_label(i)
        
        # 将 className 覆盖为排序后的字母，供前端只显示编号
        det_info["class_name"] = label
        filtered_detections.append(det_info)

        if do_crop:
            cell_region = None

            # ★ 获取 seg_item 的 quad 四顶点（引擎已从 mask 轮廓拟合）
            seg_quad = None
            if is_seg and i < len(valid_seg_items) and hasattr(valid_seg_items[i], 'quad'):
                seg_quad = valid_seg_items[i].quad  # [[x,y],[x,y],[x,y],[x,y]] 像素坐标

            logger.info("裁剪 [%s]: perspective_crop=%s, has_quad=%s", label, perspective_crop, seg_quad is not None)

            if perspective_crop and seg_quad is not None and len(seg_quad) == 4:
                try:
                    # ★ 按用户参考方案: src_points → dst_points → getPerspectiveTransform → warpPerspective
                    src_points = np.float32(seg_quad)  # 4个源点 [[x,y],...]

                    # 排序: TL→TR→BR→BL (确保顺序正确)
                    # 按 y 排序分上下
                    sorted_by_y = src_points[np.argsort(src_points[:, 1])]
                    top_pts = sorted_by_y[:2]
                    bot_pts = sorted_by_y[2:]
                    tl = top_pts[np.argmin(top_pts[:, 0])]
                    tr = top_pts[np.argmax(top_pts[:, 0])]
                    br = bot_pts[np.argmax(bot_pts[:, 0])]
                    bl = bot_pts[np.argmin(bot_pts[:, 0])]
                    src_points = np.float32([tl, tr, br, bl])

                    # 计算目标矩形宽高
                    width_top = np.linalg.norm(tr - tl)
                    width_bottom = np.linalg.norm(br - bl)
                    height_left = np.linalg.norm(bl - tl)
                    height_right = np.linalg.norm(br - tr)
                    out_w = int(max(width_top, width_bottom)) + 2 * expand_px
                    out_h = int(max(height_left, height_right)) + 2 * expand_px

                    if out_w > 10 and out_h > 10:
                        # 目标矩形: 左上→右上→右下→左下
                        dst_points = np.float32([
                            [expand_px, expand_px],
                            [out_w - expand_px, expand_px],
                            [out_w - expand_px, out_h - expand_px],
                            [expand_px, out_h - expand_px]
                        ])

                        M = cv2.getPerspectiveTransform(src_points, dst_points)
                        cell_region = cv2.warpPerspective(img, M, (out_w, out_h),
                                                          flags=cv2.INTER_LINEAR,
                                                          borderMode=cv2.BORDER_REPLICATE)
                        logger.info("透视裁剪成功 [%s]: quad=%s → %dx%d", label, src_points.tolist(), out_w, out_h)

                except Exception as e:
                    logger.error("透视裁剪异常 [%s]: %s", label, e, exc_info=True)
                    cell_region = None

            if cell_region is None:
                # 普通矩形裁剪回退
                ix1 = max(0, int(round(x1)) - expand_px)
                iy1 = max(0, int(round(y1)) - expand_px)
                ix2 = min(w, int(round(x2)) + expand_px)
                iy2 = min(h, int(round(y2)) + expand_px)
                ix1 = max(0, min(ix1, w - 1))
                iy1 = max(0, min(iy1, h - 1))
                ix2 = max(ix1 + 1, min(ix2, w))
                iy2 = max(iy1 + 1, min(iy2, h))
                cell_region = img[iy1:iy2, ix1:ix2]

            if cell_region is not None and cell_region.size > 0:
                # 如果指定了导出分辨率，先 resize
                if crop_out_w > 0 and crop_out_h > 0:
                    cell_region = cv2.resize(cell_region, (crop_out_w, crop_out_h), interpolation=cv2.INTER_LINEAR)
                crop_name = f"{img_path.stem}_{label}.jpg"
                crop_path = output_dir_path / crop_name
                # 计算该裁剪区域的中心像素坐标，生成独立 GPS
                crop_cx = (x1 + x2) / 2.0
                crop_cy = (y1 + y2) / 2.0
                crop_exif = _gps_helper.make_exif_for_crop(crop_cx, crop_cy) or _fallback_exif
                _save_crop_with_exif(cell_region, str(crop_path), crop_quality, crop_exif)
                
                results.append({
                    "label": label,
                    "crop_path": str(crop_path),
                    "box": [int(x1), int(y1), int(x2), int(y2)]
                })

    logger.info("图片分割完成: %s, 识别到 %d 块组件, 有效 %d 块 (seg_model=%s)", image_path, len(detections), len(filtered_detections), is_seg)
    return {
        "message": "提取光伏组件成功" + ("并裁剪完成" if do_crop else "（已标注，未裁剪）"),
        "total": len(filtered_detections),
        "detections": filtered_detections,
        "output_dir": output_dir,
        "crops": results
    }
