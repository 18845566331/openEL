"""
Feature: announcement-notification — 公告通知功能属性测试

使用 Hypothesis 对公告 CRUD、toggle、active 过滤、版本发布自动公告
以及重复发布幂等性进行属性验证。
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

import pytest
from hypothesis import given, settings, assume, HealthCheck
import hypothesis.strategies as st

# ---------------------------------------------------------------------------
# 将服务器模块目录加入 sys.path
# ---------------------------------------------------------------------------
_server_dir = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "服务器系统", "license_manager")
)
if _server_dir not in sys.path:
    sys.path.insert(0, _server_dir)

import server as license_server  # noqa: E402

# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------
_safe_text = st.text(
    min_size=1,
    max_size=100,
    alphabet=st.characters(
        whitelist_categories=("L", "N", "P", "S", "Z"),
        blacklist_characters="\x00",
    ),
).filter(lambda s: s.strip())

_ann_type_st = st.sampled_from(["general", "release"])
_priority_st = st.sampled_from(["normal", "important"])

_version_st = st.from_regex(r"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}", fullmatch=True)


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
@pytest.fixture
def client():
    tmpdir = tempfile.mkdtemp()
    db_path = os.path.join(tmpdir, "test.db")
    release_dir = os.path.join(tmpdir, "releases")
    os.makedirs(release_dir, exist_ok=True)

    original_db = license_server.DB_PATH
    original_release = license_server.RELEASE_DIR
    license_server.DB_PATH = db_path
    license_server.RELEASE_DIR = release_dir

    license_server.init_db()

    with license_server.app.test_client() as c:
        yield c

    license_server.DB_PATH = original_db
    license_server.RELEASE_DIR = original_release
    shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _create_announcement(client, title="t", content="c", ann_type="general",
                         priority="normal", related_version=""):
    """通过 API 创建公告并返回 (response, json_data)。"""
    resp = client.post(
        "/api/announcements",
        data=json.dumps({
            "title": title,
            "content": content,
            "type": ann_type,
            "priority": priority,
            "related_version": related_version,
        }),
        content_type="application/json",
    )
    return resp, resp.get_json()


def _publish_release(client, version, source_path, channel="stable", notes=""):
    """通过 API 发布版本并返回 (response, json_data)。"""
    resp = client.post(
        "/api/releases/publish",
        data=json.dumps({
            "source_path": source_path,
            "version": version,
            "channel": channel,
            "notes": notes,
        }),
        content_type="application/json",
    )
    return resp, resp.get_json()

def _clean_announcements(client):
    """删除所有公告，确保 hypothesis 每次迭代从干净状态开始。"""
    resp = client.get("/api/announcements")
    if resp.status_code == 200:
        for ann in resp.get_json():
            client.delete(f"/api/announcements/{ann['id']}")



# ===========================================================================
# Property 1: 公告创建 round-trip
# ===========================================================================

class TestProperty1AnnouncementCreateRoundTrip:
    """Feature: announcement-notification, Property 1: 公告创建 round-trip"""

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        title=_safe_text,
        content=_safe_text,
        ann_type=_ann_type_st,
        priority=_priority_st,
    )
    def test_create_roundtrip(self, client, title, content, ann_type, priority):
        """Feature: announcement-notification, Property 1: 公告创建 round-trip

        对于任意有效公告数据（非空 title 和 content），POST 创建后返回对象
        应包含所有提交字段，且 created_at / updated_at 为正整数。
        """
        resp, body = _create_announcement(
            client, title=title, content=content,
            ann_type=ann_type, priority=priority,
        )

        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {body}"
        assert body["title"] == title.strip()
        assert body["content"] == content.strip()
        assert body["type"] == ann_type
        assert body["priority"] == priority
        assert isinstance(body["id"], int) and body["id"] > 0
        assert isinstance(body["created_at"], int) and body["created_at"] > 0
        assert isinstance(body["updated_at"], int) and body["updated_at"] > 0
        assert body["enabled"] == 1


# ===========================================================================
# Property 2: 公告列表排序不变量
# ===========================================================================

class TestProperty2AnnouncementListOrdering:
    """Feature: announcement-notification, Property 2: 公告列表排序不变量"""

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        items=st.lists(
            st.fixed_dictionaries({
                "title": _safe_text,
                "content": _safe_text,
            }),
            min_size=1,
            max_size=10,
        ),
    )
    def test_list_ordering(self, client, items):
        """Feature: announcement-notification, Property 2: 公告列表排序不变量

        创建 1-10 条公告后，GET 列表应按 created_at 降序排列（非严格递减）。
        """
        _clean_announcements(client)
        for item in items:
            resp, _ = _create_announcement(client, title=item["title"], content=item["content"])
            assert resp.status_code == 200

        resp = client.get("/api/announcements")
        assert resp.status_code == 200
        data = resp.get_json()

        assert len(data) == len(items)

        timestamps = [a["created_at"] for a in data]
        for i in range(len(timestamps) - 1):
            assert timestamps[i] >= timestamps[i + 1], (
                f"List not in created_at DESC order: {timestamps}"
            )


# ===========================================================================
# Property 5: Toggle 双次恢复原状态
# ===========================================================================

class TestProperty5ToggleDoubleRestore:
    """Feature: announcement-notification, Property 5: Toggle 双次恢复原状态"""

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        title=_safe_text,
        content=_safe_text,
    )
    def test_toggle_twice_restores(self, client, title, content):
        """Feature: announcement-notification, Property 5: Toggle 双次恢复原状态

        对于任意公告，连续两次 toggle 应恢复原始 enabled 状态。
        """
        resp, created = _create_announcement(client, title=title, content=content)
        assert resp.status_code == 200
        ann_id = created["id"]
        original_enabled = created["enabled"]

        # 第一次 toggle
        resp1 = client.post(f"/api/announcements/{ann_id}/toggle")
        assert resp1.status_code == 200
        toggled = resp1.get_json()
        assert toggled["enabled"] != original_enabled

        # 第二次 toggle
        resp2 = client.post(f"/api/announcements/{ann_id}/toggle")
        assert resp2.status_code == 200
        restored = resp2.get_json()
        assert restored["enabled"] == original_enabled, (
            f"Double toggle did not restore: original={original_enabled}, "
            f"after two toggles={restored['enabled']}"
        )


# ===========================================================================
# Property 6: API 错误条件
# ===========================================================================

class TestProperty6APIErrorConditions:
    """Feature: announcement-notification, Property 6: API 错误条件"""

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        fake_id=st.integers(min_value=10000, max_value=99999),
    )
    def test_nonexistent_id_returns_404(self, client, fake_id):
        """Feature: announcement-notification, Property 6: API 错误条件 — 404

        对于任意不存在的 ID，PUT / DELETE / toggle 应返回 404。
        """
        # PUT
        resp_put = client.put(
            f"/api/announcements/{fake_id}",
            data=json.dumps({"title": "x"}),
            content_type="application/json",
        )
        assert resp_put.status_code == 404

        # DELETE
        resp_del = client.delete(f"/api/announcements/{fake_id}")
        assert resp_del.status_code == 404

        # Toggle
        resp_toggle = client.post(f"/api/announcements/{fake_id}/toggle")
        assert resp_toggle.status_code == 404

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        has_title=st.booleans(),
        has_content=st.booleans(),
    )
    def test_missing_fields_returns_400(self, client, has_title, has_content):
        """Feature: announcement-notification, Property 6: API 错误条件 — 400

        缺少 title 或 content 时，POST 创建应返回 400。
        """
        # 至少一个字段缺失才是有效的 400 测试
        assume(not (has_title and has_content))

        payload = {}
        if has_title:
            payload["title"] = "valid title"
        if has_content:
            payload["content"] = "valid content"

        resp = client.post(
            "/api/announcements",
            data=json.dumps(payload),
            content_type="application/json",
        )
        assert resp.status_code == 400, (
            f"Expected 400 for payload {payload}, got {resp.status_code}"
        )


# ===========================================================================
# Property 7: Active 端点过滤不变量
# ===========================================================================

class TestProperty7ActiveEndpointFiltering:
    """Feature: announcement-notification, Property 7: Active 端点过滤不变量"""

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        enabled_flags=st.lists(
            st.booleans(),
            min_size=1,
            max_size=8,
        ),
        since_offset=st.integers(min_value=-5, max_value=5),
    )
    def test_active_filter_invariant(self, client, enabled_flags, since_offset):
        """Feature: announcement-notification, Property 7: Active 端点过滤不变量

        对于任意 enabled/disabled 公告组合和任意 since 时间戳，
        GET /api/announcements/active?since=<ts> 应仅返回 enabled=1 且
        created_at > since 的公告，且 total 等于数组长度。
        """
        _clean_announcements(client)
        created_ids = []
        for i, enabled in enumerate(enabled_flags):
            resp, body = _create_announcement(
                client, title=f"ann_{i}", content=f"content_{i}",
            )
            assert resp.status_code == 200
            ann_id = body["id"]
            created_ids.append(ann_id)

            # 如果需要禁用，toggle 一次
            if not enabled:
                toggle_resp = client.post(f"/api/announcements/{ann_id}/toggle")
                assert toggle_resp.status_code == 200

        # 获取所有公告以确定 created_at 范围
        all_resp = client.get("/api/announcements")
        all_anns = all_resp.get_json()
        assert len(all_anns) == len(enabled_flags)

        # 选取一个 since 值：基于第一条公告的 created_at 加偏移
        base_ts = all_anns[0]["created_at"]
        since_val = base_ts + since_offset

        # 查询 active
        active_resp = client.get(f"/api/announcements/active?since={since_val}")
        assert active_resp.status_code == 200
        active_data = active_resp.get_json()
        active_list = active_data["announcements"]
        total = active_data["total"]

        # total 等于数组长度
        assert total == len(active_list), (
            f"total={total} != len(announcements)={len(active_list)}"
        )

        # 每条返回的公告都应 enabled=1 且 created_at > since_val
        for ann in active_list:
            assert ann["enabled"] == 1, (
                f"Active endpoint returned disabled announcement id={ann['id']}"
            )
            assert ann["created_at"] > since_val, (
                f"Announcement id={ann['id']} created_at={ann['created_at']} "
                f"<= since={since_val}"
            )

        # 反向验证：所有 enabled=1 且 created_at > since_val 的公告都应出现
        expected_ids = set()
        for ann in all_anns:
            if ann["enabled"] == 1 and ann["created_at"] > since_val:
                expected_ids.add(ann["id"])
        returned_ids = {ann["id"] for ann in active_list}
        assert returned_ids == expected_ids, (
            f"Mismatch: expected {expected_ids}, got {returned_ids}"
        )


# ===========================================================================
# Property 8: 版本发布自动创建公告
# ===========================================================================

class TestProperty8PublishAutoAnnouncement:
    """Feature: announcement-notification, Property 8: 版本发布自动创建公告"""

    @settings(
        max_examples=100,
        suppress_health_check=[HealthCheck.function_scoped_fixture],
    )
    @given(version=_version_st)
    def test_publish_creates_release_announcement(self, client, version):
        """Feature: announcement-notification, Property 8: 版本发布自动创建公告

        对于任意版本发布，应存在一条 type=release、priority=important、
        enabled=1 且 related_version 匹配的公告。
        """
        # 创建临时源文件
        tmpfile = tempfile.NamedTemporaryFile(
            delete=False, suffix=".zip", dir=license_server.RELEASE_DIR,
        )
        tmpfile.write(b"fake release content")
        tmpfile.close()

        try:
            resp, body = _publish_release(client, version=version, source_path=tmpfile.name)
            assert resp.status_code == 200, f"Publish failed: {body}"

            # 检查公告列表
            ann_resp = client.get("/api/announcements")
            assert ann_resp.status_code == 200
            anns = ann_resp.get_json()

            release_anns = [
                a for a in anns
                if a["type"] == "release" and a["related_version"] == version
            ]
            assert len(release_anns) >= 1, (
                f"No release announcement found for version {version}"
            )

            ann = release_anns[0]
            assert ann["priority"] == "important"
            assert ann["enabled"] == 1
            assert ann["related_version"] == version
        finally:
            if os.path.exists(tmpfile.name):
                os.unlink(tmpfile.name)


# ===========================================================================
# Property 9: 重复版本发布幂等性
# ===========================================================================

class TestProperty9DuplicatePublishIdempotency:
    """Feature: announcement-notification, Property 9: 重复版本发布幂等性"""

    @settings(
        max_examples=100,
        suppress_health_check=[HealthCheck.function_scoped_fixture],
    )
    @given(version=_version_st)
    def test_duplicate_publish_single_announcement(self, client, version):
        """Feature: announcement-notification, Property 9: 重复版本发布幂等性

        对于任意版本号，发布两次后应仅存在 1 条该版本的 release 公告。
        """
        # 创建临时源文件
        tmpfile = tempfile.NamedTemporaryFile(
            delete=False, suffix=".zip", dir=license_server.RELEASE_DIR,
        )
        tmpfile.write(b"fake release v1")
        tmpfile.close()

        try:
            # 第一次发布
            resp1, body1 = _publish_release(
                client, version=version, source_path=tmpfile.name, notes="first publish",
            )
            assert resp1.status_code == 200, f"First publish failed: {body1}"

            # 第二次发布（不同 notes）
            resp2, body2 = _publish_release(
                client, version=version, source_path=tmpfile.name, notes="second publish",
            )
            assert resp2.status_code == 200, f"Second publish failed: {body2}"

            # 检查公告列表
            ann_resp = client.get("/api/announcements")
            assert ann_resp.status_code == 200
            anns = ann_resp.get_json()

            release_anns = [
                a for a in anns
                if a["type"] == "release" and a["related_version"] == version
            ]
            assert len(release_anns) == 1, (
                f"Expected exactly 1 release announcement for version {version}, "
                f"got {len(release_anns)}"
            )

            # 内容应为第二次发布的 notes
            assert release_anns[0]["content"] == "second publish"
        finally:
            if os.path.exists(tmpfile.name):
                os.unlink(tmpfile.name)
