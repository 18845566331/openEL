#!/usr/bin/env python3
"""Git 精细化恢复工具。

功能：
  1. 按 commit ID 恢复指定文件
  2. 按时间点恢复指定文件（找到该时间前的最近 commit）
  3. 恢复前自动创建备份 commit
  4. 支持批量恢复多个文件

用法示例：
  # 按 commit ID 恢复单个文件
  python git_restore.py --commit abc1234 --file backend/app/main.py

  # 按时间点恢复（恢复到该时间前最近的版本）
  python git_restore.py --before "2026-03-01 12:00" --file backend/app/main.py

  # 批量恢复多个文件
  python git_restore.py --commit abc1234 --file file1.py --file file2.py

  # 查看某文件的历史版本
  python git_restore.py --history backend/app/main.py

  # 列出所有提交
  python git_restore.py --log
"""

import argparse
import subprocess
import sys
from datetime import datetime


def run_git(*args: str, check: bool = True) -> str:
    """执行 git 命令。"""
    cmd = ["git"] + list(args)
    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if check and result.returncode != 0:
        print(f"❌ Git 命令失败: {' '.join(cmd)}", file=sys.stderr)
        print(f"   {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def find_commit_before(date_str: str) -> str:
    """找到指定时间之前的最近 commit。"""
    output = run_git("log", f"--before={date_str}", "--format=%H", "--max-count=1")
    if not output:
        print(f"❌ 未找到 {date_str} 之前的提交记录", file=sys.stderr)
        sys.exit(1)
    return output.strip()


def show_file_history(file_path: str) -> None:
    """显示指定文件的修改历史。"""
    output = run_git("log", "--format=%h  %ai  %an  %s", "--max-count=20", "--", file_path)
    if not output:
        print(f"⚠️  文件 '{file_path}' 没有修改历史")
        return
    print(f"\n📄 文件 '{file_path}' 的最近 20 次修改：\n")
    print("  Commit   | 时间                     | 作者          | 描述")
    print("  " + "-" * 80)
    for line in output.split("\n"):
        if line.strip():
            print(f"  {line}")


def show_log(count: int = 30) -> None:
    """显示最近的提交日志。"""
    output = run_git("log", f"--max-count={count}", "--format=%h  %ai  %an  %s")
    print(f"\n📋 最近 {count} 条提交记录：\n")
    print("  Commit   | 时间                     | 作者          | 描述")
    print("  " + "-" * 80)
    for line in output.split("\n"):
        if line.strip():
            print(f"  {line}")


def restore_files(commit_id: str, files: list[str], no_backup: bool = False) -> None:
    """恢复指定文件到指定 commit 的版本。"""
    # 验证 commit
    run_git("cat-file", "-t", commit_id)
    short_id = commit_id[:8]
    
    print(f"\n🔄 准备恢复 {len(files)} 个文件到 commit {short_id}")
    print()

    for f in files:
        # 验证文件在该 commit 中存在
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{commit_id}:{f}"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  ⚠️  跳过: '{f}' 在 commit {short_id} 中不存在")
            continue

        # 备份
        if not no_backup:
            run_git("add", f, check=False)
            run_git("commit", "-m", f"backup: 恢复前自动备份 {f}", "--allow-empty", check=False)

        # 恢复
        run_git("checkout", commit_id, "--", f)
        print(f"  ✅ 已恢复: {f} <- {short_id}")

    # 提交恢复
    run_git("add", *files, check=False)
    file_list = ", ".join(files[:3])
    if len(files) > 3:
        file_list += f" 等 {len(files)} 个文件"
    run_git("commit", "-m", f"restore: 从 {short_id} 恢复 {file_list}", "--allow-empty", check=False)
    print(f"\n✅ 恢复完成，已提交恢复记录")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Git 精细化恢复工具 — 支持按 commit/时间点恢复指定文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--commit", "-c", help="要恢复到的 commit ID（或短 ID）")
    parser.add_argument("--before", "-b", help="恢复到此时间之前的最近版本，格式: YYYY-MM-DD 或 'YYYY-MM-DD HH:MM'")
    parser.add_argument("--file", "-f", action="append", dest="files", help="要恢复的文件路径（可多次指定）")
    parser.add_argument("--history", metavar="FILE", help="查看指定文件的修改历史")
    parser.add_argument("--log", action="store_true", help="显示最近的提交日志")
    parser.add_argument("--log-count", type=int, default=30, help="日志条数（默认 30）")
    parser.add_argument("--no-backup", action="store_true", help="恢复前不创建备份")

    args = parser.parse_args()

    if args.log:
        show_log(args.log_count)
        return

    if args.history:
        show_file_history(args.history)
        return

    if not args.commit and not args.before:
        parser.print_help()
        print("\n❌ 请指定 --commit 或 --before 参数")
        sys.exit(1)

    if not args.files:
        parser.print_help()
        print("\n❌ 请通过 --file 指定要恢复的文件")
        sys.exit(1)

    # 确定 commit ID
    if args.before:
        commit_id = find_commit_before(args.before)
        print(f"📌 找到 {args.before} 之前的最近提交: {commit_id[:8]}")
    else:
        commit_id = args.commit

    restore_files(commit_id, args.files, no_backup=args.no_backup)


if __name__ == "__main__":
    main()
