from __future__ import annotations

import os
import sys
import argparse
import logging


import uvicorn

LOG_FORMAT = "%(asctime)s [%(levelname)s] %(name)s - %(message)s"
LOG_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"


def _configure_logging(log_level: str = "info") -> None:
    """配置控制台日志；内存缓冲 handler 由 app.main 模块自动安装。"""
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)

    # 避免重复添加 StreamHandler
    if not any(isinstance(h, logging.StreamHandler) and not hasattr(h, '_is_memory') for h in root.handlers):
        fmt = logging.Formatter(LOG_FORMAT, datefmt=LOG_DATE_FORMAT)
        console = logging.StreamHandler()
        console.setLevel(getattr(logging, log_level.upper(), logging.INFO))
        console.setFormatter(fmt)
        root.addHandler(console)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="EL 缺陷检测后端服务启动器")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--reload", action="store_true")
    parser.add_argument("--log-level", default="info",
                        choices=["debug", "info", "warning", "error"])
    return parser.parse_args()


def _uvicorn_log_config(log_level: str) -> dict:
    """
    自定义 uvicorn 日志配置：让 uvicorn/uvicorn.access/uvicorn.error
    全部 propagate=True，不设独立 handler，日志统一流向 root logger。
    这样内存缓冲 handler（由 app.main 安装在 root）可以捕获所有 uvicorn 日志。
    """
    level = log_level.upper()
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "default": {
                "format": LOG_FORMAT,
                "datefmt": LOG_DATE_FORMAT,
            },
        },
        "handlers": {},  # 不设独立 handler，全部走 root
        "loggers": {
            "uvicorn": {"level": level, "propagate": True},
            "uvicorn.error": {"level": level, "propagate": True},
            "uvicorn.access": {"level": "INFO", "propagate": True},
            "fastapi": {"level": level, "propagate": True},
        },
        "root": {"level": "DEBUG"},
    }


def main() -> None:
    args = parse_args()
    _configure_logging(args.log_level)
    uvicorn.run(
        "app.main:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        log_level=args.log_level,
        log_config=_uvicorn_log_config(args.log_level),
    )


if __name__ == "__main__":
    main()
