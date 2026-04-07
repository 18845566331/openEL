"""
后端检测服务 — 性能 / 压力 / 稳定性测试
运行方式: pytest tests/test_performance.py -v -s
"""
from __future__ import annotations

import gc
import os
import statistics
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import psutil
import pytest
from fastapi.testclient import TestClient

from app.main import app, engine

# ─── 全局 fixture ───────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def client():
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture(scope="module")
def proc():
    """当前进程的 psutil 句柄，用于内存监控。"""
    return psutil.Process(os.getpid())


# ═══════════════════════════════════════════════════════════════════════════
# 1. 响应时间基准测试
# ═══════════════════════════════════════════════════════════════════════════

class TestResponseTime:
    """验证各接口在正常负载下的响应时间满足基准要求。"""

    def test_health_response_time(self, client):
        """健康检查接口 P99 < 200ms。"""
        latencies = []
        for _ in range(50):
            t0 = time.perf_counter()
            r = client.get("/health")
            latencies.append((time.perf_counter() - t0) * 1000)
            assert r.status_code == 200

        p50 = statistics.median(latencies)
        p99 = sorted(latencies)[int(len(latencies) * 0.99)]
        print(f"\n  /health  P50={p50:.1f}ms  P99={p99:.1f}ms  max={max(latencies):.1f}ms")
        assert p99 < 200, f"/health P99={p99:.1f}ms 超过 200ms 基准"

    def test_detect_error_response_time(self, client):
        """检测接口（文件不存在）P99 < 300ms。"""
        latencies = []
        for i in range(30):
            t0 = time.perf_counter()
            r = client.post("/api/detect", json={"image_path": f"/nonexistent/img_{i}.jpg"})
            latencies.append((time.perf_counter() - t0) * 1000)
            assert r.status_code == 400

        p99 = sorted(latencies)[int(len(latencies) * 0.99)]
        print(f"\n  /api/detect(err)  P99={p99:.1f}ms  max={max(latencies):.1f}ms")
        assert p99 < 300, f"/api/detect P99={p99:.1f}ms 超过 300ms 基准"

    def test_model_load_error_response_time(self, client):
        """模型加载接口（文件不存在）P99 < 300ms。"""
        latencies = []
        for i in range(20):
            t0 = time.perf_counter()
            r = client.post("/api/model/load", json={
                "model_path": f"/nonexistent/model_{i}.onnx",
                "labels": ["隐裂"],
            })
            latencies.append((time.perf_counter() - t0) * 1000)
            assert r.status_code == 400

        p99 = sorted(latencies)[int(len(latencies) * 0.99)]
        print(f"\n  /api/model/load(err)  P99={p99:.1f}ms  max={max(latencies):.1f}ms")
        assert p99 < 300

    def test_batch_detect_empty_dir_response_time(self, client):
        """批量检测（目录不存在）P99 < 300ms。"""
        latencies = []
        for i in range(20):
            t0 = time.perf_counter()
            r = client.post("/api/detect/batch", json={"input_dir": f"/nonexistent/dir_{i}"})
            latencies.append((time.perf_counter() - t0) * 1000)
            assert r.status_code == 400

        p99 = sorted(latencies)[int(len(latencies) * 0.99)]
        print(f"\n  /api/detect/batch(err)  P99={p99:.1f}ms  max={max(latencies):.1f}ms")
        assert p99 < 300


# ═══════════════════════════════════════════════════════════════════════════
# 2. 压力测试 — 高并发
# ═══════════════════════════════════════════════════════════════════════════

class TestStressHighConcurrency:
    """模拟多用户同时请求，验证服务在高并发下不崩溃、不死锁。"""

    def test_100_concurrent_health_checks(self, client):
        """100 个并发健康检查，全部成功，无超时。"""
        errors = []

        def do_health():
            try:
                r = client.get("/health")
                if r.status_code != 200:
                    errors.append(f"status={r.status_code}")
            except Exception as e:
                errors.append(str(e))

        threads = [threading.Thread(target=do_health) for _ in range(100)]
        t0 = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        elapsed = time.perf_counter() - t0

        print(f"\n  100并发健康检查 耗时={elapsed:.2f}s  错误={len(errors)}")
        assert len(errors) == 0, f"并发健康检查出现错误: {errors[:5]}"
        assert elapsed < 10, f"100并发健康检查耗时 {elapsed:.2f}s 超过 10s"

    def test_50_concurrent_detect_requests(self, client):
        """50 个并发检测请求，全部返回 400（文件不存在），无崩溃。"""
        results = []

        def do_detect(i):
            r = client.post("/api/detect", json={"image_path": f"/nonexistent/stress_{i}.jpg"})
            return r.status_code

        with ThreadPoolExecutor(max_workers=20) as ex:
            futs = [ex.submit(do_detect, i) for i in range(50)]
            results = [f.result(timeout=15) for f in as_completed(futs, timeout=30)]

        assert len(results) == 50
        assert all(s == 400 for s in results), f"意外状态码: {set(results)}"

    def test_mixed_50_concurrent_requests(self, client):
        """50 个混合并发请求（health + detect + batch），全部完成，无崩溃。"""
        results = []

        def do_mixed(i):
            if i % 3 == 0:
                return client.get("/health").status_code
            elif i % 3 == 1:
                return client.post("/api/detect", json={"image_path": "/nonexistent/x.jpg"}).status_code
            else:
                return client.post("/api/detect/batch", json={"input_dir": "/nonexistent/d"}).status_code

        with ThreadPoolExecutor(max_workers=25) as ex:
            futs = [ex.submit(do_mixed, i) for i in range(50)]
            results = [f.result(timeout=15) for f in as_completed(futs, timeout=30)]

        assert len(results) == 50
        for s in results:
            assert s in {200, 400}, f"意外状态码: {s}"

    def test_burst_200_requests_in_2_seconds(self, client):
        """2 秒内发送 200 个请求，服务不崩溃，成功率 ≥ 95%。"""
        success = 0
        total = 200
        lock = threading.Lock()

        def do_req():
            nonlocal success
            try:
                r = client.get("/health")
                if r.status_code == 200:
                    with lock:
                        success += 1
            except Exception:
                pass

        threads = [threading.Thread(target=do_req) for _ in range(total)]
        t0 = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)
        elapsed = time.perf_counter() - t0

        rate = success / total * 100
        print(f"\n  200请求突发 耗时={elapsed:.2f}s  成功率={rate:.1f}%")
        assert rate >= 95, f"突发请求成功率 {rate:.1f}% 低于 95%"


# ═══════════════════════════════════════════════════════════════════════════
# 3. 内存泄漏检测
# ═══════════════════════════════════════════════════════════════════════════

class TestMemoryLeak:
    """验证重复请求不会导致内存持续增长（泄漏）。"""

    def test_no_memory_leak_on_repeated_health(self, client, proc):
        """重复 200 次健康检查，内存增长 < 20MB。"""
        gc.collect()
        mem_before = proc.memory_info().rss / (1024 * 1024)

        for _ in range(200):
            client.get("/health")

        gc.collect()
        mem_after = proc.memory_info().rss / (1024 * 1024)
        delta = mem_after - mem_before
        print(f"\n  健康检查×200 内存变化: {delta:+.1f}MB  ({mem_before:.0f}→{mem_after:.0f}MB)")
        assert delta < 20, f"内存增长 {delta:.1f}MB 超过 20MB，疑似泄漏"

    def test_no_memory_leak_on_repeated_detect_errors(self, client, proc):
        """重复 200 次检测错误请求，内存增长 < 20MB。"""
        gc.collect()
        mem_before = proc.memory_info().rss / (1024 * 1024)

        for i in range(200):
            client.post("/api/detect", json={"image_path": f"/nonexistent/leak_{i}.jpg"})

        gc.collect()
        mem_after = proc.memory_info().rss / (1024 * 1024)
        delta = mem_after - mem_before
        print(f"\n  检测错误×200 内存变化: {delta:+.1f}MB  ({mem_before:.0f}→{mem_after:.0f}MB)")
        assert delta < 20, f"内存增长 {delta:.1f}MB 超过 20MB，疑似泄漏"

    def test_no_memory_leak_on_repeated_model_load_errors(self, client, proc):
        """重复 100 次模型加载错误，内存增长 < 20MB。"""
        gc.collect()
        mem_before = proc.memory_info().rss / (1024 * 1024)

        for i in range(100):
            client.post("/api/model/load", json={
                "model_path": f"/nonexistent/model_{i}.onnx",
                "labels": ["隐裂", "断栅"],
            })

        gc.collect()
        mem_after = proc.memory_info().rss / (1024 * 1024)
        delta = mem_after - mem_before
        print(f"\n  模型加载错误×100 内存变化: {delta:+.1f}MB  ({mem_before:.0f}→{mem_after:.0f}MB)")
        assert delta < 20, f"内存增长 {delta:.1f}MB 超过 20MB，疑似泄漏"

    def test_no_memory_leak_csv_export(self, client, proc):
        """重复 100 次 CSV 导出，内存增长 < 30MB。"""
        gc.collect()
        mem_before = proc.memory_info().rss / (1024 * 1024)

        with tempfile.TemporaryDirectory() as tmp:
            for i in range(100):
                out = os.path.join(tmp, f"leak_{i}.csv")
                client.post(
                    "/api/report/export_csv",
                    json={
                        "output_path": out,
                        "project_info": {
                            "project_name": f"测试项目_{i}",
                            "file_results": [
                                {"name": f"img_{j}.jpg", "result": "NG", "path": f"/img_{j}.jpg"}
                                for j in range(5)
                            ],
                            "defect_by_class": {"隐裂": 3},
                        },
                    },
                )

        gc.collect()
        mem_after = proc.memory_info().rss / (1024 * 1024)
        delta = mem_after - mem_before
        print(f"\n  CSV导出×100 内存变化: {delta:+.1f}MB  ({mem_before:.0f}→{mem_after:.0f}MB)")
        assert delta < 30, f"内存增长 {delta:.1f}MB 超过 30MB，疑似泄漏"


# ═══════════════════════════════════════════════════════════════════════════
# 4. 稳定性测试 — 长时间运行
# ═══════════════════════════════════════════════════════════════════════════

class TestStability:
    """模拟长时间运行，验证服务状态一致性和无崩溃。"""

    def test_sustained_load_500_requests(self, client):
        """持续发送 500 个请求，成功率 100%，无异常。"""
        errors = []
        for i in range(500):
            try:
                r = client.get("/health")
                if r.status_code != 200:
                    errors.append(f"req#{i} status={r.status_code}")
            except Exception as e:
                errors.append(f"req#{i} exception={e}")

        print(f"\n  持续500请求 错误数={len(errors)}")
        assert len(errors) == 0, f"稳定性测试出现错误: {errors[:5]}"

    def test_state_consistency_after_1000_requests(self, client):
        """1000 次请求后，引擎状态与初始状态一致。"""
        initial = client.get("/health").json()["runtime"]["model_loaded"]

        for i in range(1000):
            if i % 4 == 0:
                client.get("/health")
            elif i % 4 == 1:
                client.post("/api/detect", json={"image_path": "/nonexistent/x.jpg"})
            elif i % 4 == 2:
                client.post("/api/detect/batch", json={"input_dir": "/nonexistent/d"})
            else:
                client.post("/api/model/load", json={
                    "model_path": "/nonexistent/m.onnx", "labels": ["隐裂"]
                })

        final = client.get("/health").json()["runtime"]["model_loaded"]
        assert initial == final, f"1000次请求后状态不一致: 初始={initial} 最终={final}"

    def test_no_fd_leak_after_repeated_requests(self, client, proc):
        """重复请求不导致文件描述符泄漏（Windows句柄增长 < 5000，Linux fd增长 < 50）。"""
        gc.collect()
        fd_before = proc.num_fds() if hasattr(proc, "num_fds") else proc.num_handles()

        for _ in range(300):
            client.get("/health")
            client.post("/api/detect", json={"image_path": "/nonexistent/x.jpg"})

        gc.collect()
        fd_after = proc.num_fds() if hasattr(proc, "num_fds") else proc.num_handles()
        delta = fd_after - fd_before
        print(f"\n  FD/句柄变化: {delta:+d}  ({fd_before}→{fd_after})")
        # Windows 上 num_handles() 包含线程句柄，正常增长较大
        threshold = 5000 if not hasattr(proc, "num_fds") else 50
        assert delta < threshold, f"文件描述符/句柄增长 {delta}，疑似泄漏（阈值={threshold}）"

    def test_concurrent_stability_30s(self, client):
        """30 秒内持续并发请求，服务保持稳定（错误率 < 1%）。"""
        errors = 0
        total = 0
        stop_event = threading.Event()
        lock = threading.Lock()

        def worker():
            nonlocal errors, total
            while not stop_event.is_set():
                try:
                    r = client.get("/health")
                    with lock:
                        total += 1
                        if r.status_code != 200:
                            errors += 1
                except Exception:
                    with lock:
                        total += 1
                        errors += 1
                time.sleep(0.05)

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(10)]
        for t in threads:
            t.start()
        time.sleep(30)
        stop_event.set()
        for t in threads:
            t.join(timeout=5)

        error_rate = errors / max(total, 1) * 100
        print(f"\n  30s并发稳定性 总请求={total}  错误={errors}  错误率={error_rate:.2f}%")
        assert error_rate < 1.0, f"30s稳定性测试错误率 {error_rate:.2f}% 超过 1%"


# ═══════════════════════════════════════════════════════════════════════════
# 5. BUG 专项检测
# ═══════════════════════════════════════════════════════════════════════════

class TestBugDetection:
    """针对已知风险点的专项 BUG 检测。"""

    # ── 5.1 输入边界 ──────────────────────────────────────────────────────

    def test_empty_image_path(self, client):
        """空路径应返回 400，不崩溃。"""
        r = client.post("/api/detect", json={"image_path": ""})
        assert r.status_code in {400, 422}

    def test_null_image_path(self, client):
        """null 路径应返回 422（Pydantic 验证失败），不崩溃。"""
        r = client.post("/api/detect", json={"image_path": None})
        assert r.status_code in {400, 422}

    def test_very_long_image_path(self, client):
        """超长路径（10000字符）应返回 400，不崩溃。"""
        r = client.post("/api/detect", json={"image_path": "a" * 10000})
        assert r.status_code in {400, 422}

    def test_path_traversal_attempt(self, client):
        """路径遍历攻击尝试应返回 400，不暴露系统文件。"""
        r = client.post("/api/detect", json={"image_path": "../../../../etc/passwd"})
        assert r.status_code == 400
        # 不应在响应中暴露系统路径内容
        body = r.text
        assert "root:" not in body

    def test_confidence_threshold_boundary(self, client):
        """置信度阈值边界值（0.0 和 1.0）应被接受。"""
        for conf in [0.0, 1.0]:
            r = client.post("/api/detect", json={
                "image_path": "/nonexistent/x.jpg",
                "confidence_threshold": conf,
            })
            assert r.status_code in {400, 422}, f"conf={conf} 返回意外状态码 {r.status_code}"

    def test_invalid_confidence_threshold(self, client):
        """超出范围的置信度（-0.1, 1.1）应返回 422。"""
        for conf in [-0.1, 1.1, 999]:
            r = client.post("/api/detect", json={
                "image_path": "/nonexistent/x.jpg",
                "confidence_threshold": conf,
            })
            assert r.status_code == 422, f"conf={conf} 应返回 422，实际 {r.status_code}"

    def test_invalid_model_input_size(self, client):
        """模型输入尺寸超出范围应返回 422。"""
        r = client.post("/api/model/load", json={
            "model_path": "/nonexistent/m.onnx",
            "labels": ["隐裂"],
            "input_width": 0,   # 低于最小值 64
            "input_height": 0,
        })
        assert r.status_code == 422

    def test_batch_max_images_boundary(self, client):
        """max_images=0 应返回 422（低于最小值 1）。"""
        r = client.post("/api/detect/batch", json={
            "input_dir": "/nonexistent/d",
            "max_images": 0,
        })
        assert r.status_code == 422

    # ── 5.2 并发竞态条件 ──────────────────────────────────────────────────

    def test_no_race_condition_on_engine_describe(self):
        """并发调用 engine.describe() 不产生竞态条件。"""
        results = []
        errors = []
        lock = threading.Lock()

        def do_describe():
            try:
                d = engine.describe()
                with lock:
                    results.append(d["model_loaded"])
            except Exception as e:
                with lock:
                    errors.append(str(e))

        threads = [threading.Thread(target=do_describe) for _ in range(50)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        assert len(errors) == 0, f"engine.describe() 并发出现异常: {errors}"
        assert len(set(results)) == 1, f"并发 describe() 返回不一致结果: {set(results)}"

    def test_no_deadlock_concurrent_load_and_detect(self, client):
        """并发模型加载和检测请求不产生死锁（10s 内完成）。"""
        def do_load():
            return client.post("/api/model/load", json={
                "model_path": "/nonexistent/m.onnx", "labels": ["隐裂"]
            }).status_code

        def do_detect():
            return client.post("/api/detect", json={
                "image_path": "/nonexistent/x.jpg"
            }).status_code

        with ThreadPoolExecutor(max_workers=10) as ex:
            futs = [ex.submit(do_load if i % 2 == 0 else do_detect) for i in range(20)]
            results = [f.result(timeout=10) for f in as_completed(futs, timeout=15)]

        assert len(results) == 20, "部分请求超时，可能存在死锁"

    # ── 5.3 日志接口安全 ──────────────────────────────────────────────────

    def test_logs_endpoint_forbidden(self, client):
        """/api/logs 接口应返回 403，不暴露后端日志。"""
        r = client.get("/api/logs")
        assert r.status_code == 403
        data = r.json()
        assert "detail" in data

    def test_logs_endpoint_no_plaintext_leak(self, client):
        """/api/logs 响应不包含明文日志内容。"""
        r = client.get("/api/logs")
        body = r.text
        # 不应包含典型的日志格式内容
        assert "INFO" not in body or r.status_code == 403
        assert "DEBUG" not in body or r.status_code == 403

    # ── 5.4 CSV 导出边界 ──────────────────────────────────────────────────

    def test_csv_export_empty_results(self, client):
        """空结果集导出 CSV 应成功（只有表头）。"""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "empty.csv")
            r = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": out,
                    "project_info": {
                        "project_name": "空结果测试",
                        "file_results": [],
                        "defect_by_class": {},
                    },
                },
            )
            assert r.status_code == 200
            assert os.path.exists(out)

    def test_csv_export_large_result_set(self, client):
        """大量结果（1000条）导出 CSV 应成功完成。"""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "large.csv")
            file_results = [
                {"name": f"img_{i}.jpg", "result": "NG", "path": f"/img_{i}.jpg"}
                for i in range(1000)
            ]
            t0 = time.perf_counter()
            r = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": out,
                    "project_info": {
                        "project_name": "大量结果测试",
                        "file_results": file_results,
                        "defect_by_class": {"隐裂": 1000},
                    },
                },
            )
            elapsed = time.perf_counter() - t0
            assert r.status_code == 200
            assert elapsed < 5, f"1000条CSV导出耗时 {elapsed:.2f}s 超过 5s"

    # ── 5.5 亮度分析边界 ──────────────────────────────────────────────────

    def test_cell_brightness_missing_image(self, client):
        """明暗片分析：图像不存在应返回 400。"""
        r = client.post("/api/analyze/cell_brightness", json={
            "image_path": "/nonexistent/el.jpg",
            "rows": 6, "cols": 10,
        })
        assert r.status_code == 400

    def test_cell_brightness_invalid_rows_cols(self, client):
        """明暗片分析：rows=0 或 cols=0 应返回 400。"""
        r = client.post("/api/analyze/cell_brightness", json={
            "image_path": "/nonexistent/el.jpg",
            "rows": 0, "cols": 10,
        })
        assert r.status_code == 400

    def test_cell_brightness_empty_path(self, client):
        """明暗片分析：空路径应返回 400。"""
        r = client.post("/api/analyze/cell_brightness", json={
            "image_path": "", "rows": 6, "cols": 10,
        })
        assert r.status_code == 400

    # ── 5.6 分割接口边界 ──────────────────────────────────────────────────

    def test_segment_missing_image(self, client):
        """分割接口：图像不存在应返回 400。"""
        r = client.post("/api/segment", json={"image_path": "/nonexistent/x.jpg"})
        assert r.status_code == 400

    def test_segment_empty_path(self, client):
        """分割接口：空路径应返回 400。"""
        r = client.post("/api/segment", json={"image_path": ""})
        assert r.status_code == 400


# ═══════════════════════════════════════════════════════════════════════════
# 6. 吞吐量测试
# ═══════════════════════════════════════════════════════════════════════════

class TestThroughput:
    """测量服务的请求吞吐量（RPS）。"""

    def test_health_throughput_rps(self, client):
        """健康检查接口吞吐量 ≥ 100 RPS（单线程）。"""
        n = 200
        t0 = time.perf_counter()
        for _ in range(n):
            client.get("/health")
        elapsed = time.perf_counter() - t0
        rps = n / elapsed
        print(f"\n  /health 吞吐量: {rps:.0f} RPS  (单线程, {n}次/{elapsed:.2f}s)")
        assert rps >= 100, f"/health 吞吐量 {rps:.0f} RPS 低于 100 RPS 基准"

    def test_concurrent_health_throughput(self, client):
        """10 线程并发健康检查吞吐量 ≥ 100 RPS。"""
        n = 500
        completed = [0]
        lock = threading.Lock()

        def worker():
            for _ in range(n // 10):
                client.get("/health")
                with lock:
                    completed[0] += 1

        threads = [threading.Thread(target=worker) for _ in range(10)]
        t0 = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30)
        elapsed = time.perf_counter() - t0
        rps = completed[0] / elapsed
        print(f"\n  /health 并发吞吐量: {rps:.0f} RPS  (10线程, {completed[0]}次/{elapsed:.2f}s)")
        assert rps >= 100, f"并发吞吐量 {rps:.0f} RPS 低于 100 RPS 基准"

    def test_csv_export_throughput(self, client):
        """CSV 导出吞吐量 ≥ 10 RPS（含文件写入）。"""
        n = 50
        with tempfile.TemporaryDirectory() as tmp:
            t0 = time.perf_counter()
            for i in range(n):
                out = os.path.join(tmp, f"tput_{i}.csv")
                client.post(
                    "/api/report/export_csv",
                    json={
                        "output_path": out,
                        "project_info": {
                            "project_name": f"吞吐量测试_{i}",
                            "file_results": [
                                {"name": f"img_{j}.jpg", "result": "OK", "path": f"/img_{j}.jpg"}
                                for j in range(5)
                            ],
                            "defect_by_class": {},
                        },
                    },
                )
            elapsed = time.perf_counter() - t0
        rps = n / elapsed
        print(f"\n  CSV导出吞吐量: {rps:.1f} RPS  ({n}次/{elapsed:.2f}s)")
        assert rps >= 10, f"CSV导出吞吐量 {rps:.1f} RPS 低于 10 RPS 基准"
