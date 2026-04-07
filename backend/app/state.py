"""全局状态管理模块（纯本地开源版）。"""

import threading
from app.detector import DefectDetectionEngine

_loaded_model_id = None
_model_profiles_cache = {}
_cache_lock = threading.Lock()
engine = DefectDetectionEngine()