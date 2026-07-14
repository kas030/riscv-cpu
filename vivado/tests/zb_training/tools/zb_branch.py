#!/usr/bin/env python3
"""管理 39 条 RV32 Zb 单指令分支及本地验证状态。"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from zb_tool import SPECS, InstructionSpec, resolve_spec


BASE_BRANCH = "zb/base"
REMOTE = "origin"
STATE_VERSION = 1
STATE_FILE = "zb-branch-status.json"
LOCK_FILE = "zb-branch-status.lock"
LOCK_TIMEOUT_SECONDS = 5.0
STALE_LOCK_SECONDS = 60.0

IMPLEMENTATION_STATES = ("pending", "implemented")
VERIFICATION_STATES = ("pending", "pass", "fail")


class BranchToolError(RuntimeError):
    """可直接展示给用户的分支管理错误。"""


def run_git(
    args: list[str],
    cwd: Path | str | None = None,
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "未知 Git 错误"
        raise BranchToolError(f"git {' '.join(args)} 失败：{detail}")
    return result


def repo_root(cwd: Path | str | None = None) -> Path:
    result = run_git(["rev-parse", "--show-toplevel"], cwd)
    return Path(result.stdout.strip()).resolve()


def git_common_dir(cwd: Path | str | None = None) -> Path:
    result = run_git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip()).resolve()

    root = repo_root(cwd)
    fallback = run_git(["rev-parse", "--git-common-dir"], cwd).stdout.strip()
    path = Path(fallback)
    return (path if path.is_absolute() else root / path).resolve()


def state_path(cwd: Path | str | None = None) -> Path:
    return git_common_dir(cwd) / STATE_FILE


def default_state() -> dict[str, object]:
    return {
        "version": STATE_VERSION,
        "base_branch": BASE_BRANCH,
        "instructions": {},
    }


def default_record() -> dict[str, str]:
    return {
        "implementation": "pending",
        "verification": "pending",
        "implementation_note": "",
        "verification_note": "",
        "updated_at": "",
    }


def validate_state(data: object, path: Path) -> dict[str, object]:
    if not isinstance(data, dict):
        raise BranchToolError(f"状态文件不是 JSON 对象：{path}")
    if data.get("version") != STATE_VERSION:
        raise BranchToolError(
            f"状态文件版本不兼容：{path}；期望 {STATE_VERSION}，"
            f"实际 {data.get('version')!r}"
        )
    if data.get("base_branch") != BASE_BRANCH:
        raise BranchToolError(
            f"状态文件基线不是 {BASE_BRANCH}：{path}；"
            "请迁移或移走旧状态文件后重试"
        )
    records = data.get("instructions")
    if not isinstance(records, dict):
        raise BranchToolError(f"状态文件 instructions 字段无效：{path}")

    known = {spec.name for spec in SPECS}
    for name, record in records.items():
        if name not in known or not isinstance(record, dict):
            raise BranchToolError(f"状态文件包含未知或无效指令记录 {name!r}：{path}")
        if record.get("implementation", "pending") not in IMPLEMENTATION_STATES:
            raise BranchToolError(f"{name} 的 implementation 状态无效：{path}")
        if record.get("verification", "pending") not in VERIFICATION_STATES:
            raise BranchToolError(f"{name} 的 verification 状态无效：{path}")
    return data


def load_state(path: Path) -> dict[str, object]:
    if not path.exists():
        return default_state()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BranchToolError(
            f"无法读取状态文件 {path}：{error}；不会自动覆盖损坏文件"
        ) from error
    return validate_state(data, path)


@contextmanager
def state_lock(common_dir: Path):
    lock_path = common_dir / LOCK_FILE
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    fd: int | None = None
    while fd is None:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                age = time.time() - lock_path.stat().st_mtime
                if age > STALE_LOCK_SECONDS:
                    lock_path.unlink()
                    continue
            except FileNotFoundError:
                continue
            if time.monotonic() >= deadline:
                raise BranchToolError(f"状态文件正被其他进程使用：{lock_path}")
            time.sleep(0.1)
    try:
        os.write(fd, f"pid={os.getpid()}\n".encode("ascii"))
        os.close(fd)
        fd = None
        yield
    finally:
        if fd is not None:
            os.close(fd)
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


def atomic_write_state(path: Path, data: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
            temp_path = Path(output.name)
        os.replace(temp_path, path)
        temp_path = None
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass


def update_state(
    cwd: Path | str | None,
    mutator: Callable[[dict[str, object]], None],
) -> dict[str, object]:
    path = state_path(cwd)
    with state_lock(path.parent):
        data = load_state(path)
        mutator(data)
        validate_state(data, path)
        atomic_write_state(path, data)
    return data


def canonical_spec(name: str) -> InstructionSpec:
    try:
        return resolve_spec(name)
    except ValueError as error:
        raise BranchToolError(str(error)) from error


def instruction_slug(spec: InstructionSpec) -> str:
    return spec.name.replace(".", "-")


def branch_name(spec: InstructionSpec) -> str:
    return f"zb/{spec.extension.lower()}-{instruction_slug(spec)}"


def image_slug(spec: InstructionSpec) -> str:
    return spec.name.replace(".", "_")


def current_branch(cwd: Path | str | None = None) -> str:
    result = run_git(["branch", "--show-current"], cwd)
    branch = result.stdout.strip()
    if not branch:
        raise BranchToolError("当前处于 detached HEAD，无法推断指令分支")
    return branch


def spec_from_current_branch(cwd: Path | str | None = None) -> InstructionSpec:
    current = current_branch(cwd)
    for spec in SPECS:
        if branch_name(spec) == current:
            return spec
    raise BranchToolError(
        f"当前分支 {current!r} 不是单指令分支；请显式提供指令名"
    )


def select_spec(name: str | None, cwd: Path | str | None = None) -> InstructionSpec:
    return canonical_spec(name) if name else spec_from_current_branch(cwd)


def ref_exists(ref: str, cwd: Path | str | None = None) -> bool:
    return run_git(["show-ref", "--verify", "--quiet", ref], cwd, check=False).returncode == 0


def local_branch_exists(branch: str, cwd: Path | str | None = None) -> bool:
    return ref_exists(f"refs/heads/{branch}", cwd)


def remote_branch_exists(branch: str, cwd: Path | str | None = None) -> bool:
    return ref_exists(f"refs/remotes/{REMOTE}/{branch}", cwd)


def branch_location(spec: InstructionSpec, cwd: Path | str | None = None) -> str:
    branch = branch_name(spec)
    local = local_branch_exists(branch, cwd)
    remote = remote_branch_exists(branch, cwd)
    if local and remote:
        return "local+remote"
    if local:
        return "local"
    if remote:
        return "remote"
    return "missing"


def record_for(data: dict[str, object], spec: InstructionSpec) -> dict[str, str]:
    records = data["instructions"]
    assert isinstance(records, dict)
    stored = records.get(spec.name)
    record = default_record()
    if isinstance(stored, dict):
        for key in record:
            value = stored.get(key)
            if isinstance(value, str):
                record[key] = value
    return record


def overall_status(location: str, record: dict[str, str]) -> str:
    if location == "missing":
        return "not-started"
    if record["implementation"] != "implemented":
        return "developing"
    if record["verification"] == "pass":
        return "complete"
    if record["verification"] == "fail":
        return "verification-failed"
    return "awaiting-verification"


STATUS_LABELS = {
    "not-started": "未开始",
    "developing": "开发中",
    "awaiting-verification": "待验证",
    "verification-failed": "验证失败",
    "complete": "已完成",
}


def status_rows(cwd: Path | str | None = None) -> list[dict[str, str]]:
    data = load_state(state_path(cwd))
    rows: list[dict[str, str]] = []
    for spec in SPECS:
        location = branch_location(spec, cwd)
        record = record_for(data, spec)
        overall = overall_status(location, record)
        rows.append(
            {
                "extension": spec.extension,
                "instruction": spec.name,
                "branch": branch_name(spec),
                "location": location,
                "implementation": record["implementation"],
                "verification": record["verification"],
                "overall": overall,
                "implementation_note": record["implementation_note"],
                "verification_note": record["verification_note"],
                "updated_at": record["updated_at"],
            }
        )
    return rows


def print_status(
    instruction: str | None,
    filter_name: str,
    cwd: Path | str | None = None,
) -> None:
    rows = status_rows(cwd)
    if instruction:
        spec = canonical_spec(instruction)
        row = next(item for item in rows if item["instruction"] == spec.name)
        print(f"指令：{row['extension']} {row['instruction']}")
        print(f"分支：{row['branch']} ({row['location']})")
        print(f"实现：{row['implementation']}")
        print(f"验证：{row['verification']}")
        print(f"总体：{STATUS_LABELS[row['overall']]}")
        if row["implementation_note"]:
            print(f"实现备注：{row['implementation_note']}")
        if row["verification_note"]:
            print(f"验证备注：{row['verification_note']}")
        if row["updated_at"]:
            print(f"更新时间：{row['updated_at']}")
        return

    if filter_name == "complete":
        rows = [row for row in rows if row["overall"] == "complete"]
    elif filter_name == "incomplete":
        rows = [row for row in rows if row["overall"] != "complete"]

    for row in rows:
        print(
            f"{row['extension']:<4} {row['instruction']:<8} "
            f"{STATUS_LABELS[row['overall']]:<6} "
            f"impl={row['implementation']:<11} "
            f"verify={row['verification']:<7} "
            f"ref={row['location']:<12} {row['branch']}"
        )
    all_rows = status_rows(cwd)
    completed = sum(row["overall"] == "complete" for row in all_rows)
    print(f"汇总：已完成 {completed}/39，未完成 {39 - completed}/39")


def ensure_clean_worktree(cwd: Path | str | None = None) -> None:
    dirty = run_git(["status", "--porcelain"], cwd).stdout.strip()
    if dirty:
        raise BranchToolError("工作区不干净，拒绝切换分支；请先提交、暂存或移走更改")


def ensure_descends_from_base(ref: str, cwd: Path | str | None = None) -> None:
    result = run_git(
        ["merge-base", "--is-ancestor", BASE_BRANCH, ref],
        cwd,
        check=False,
    )
    if result.returncode != 0:
        raise BranchToolError(
            f"分支 {ref} 不是从当前 {BASE_BRANCH} 派生，拒绝自动切换；"
            "请先人工核对分支历史"
        )


def open_instruction(spec: InstructionSpec, cwd: Path | str | None = None) -> str:
    ensure_clean_worktree(cwd)
    target = branch_name(spec)
    if not local_branch_exists(BASE_BRANCH, cwd):
        raise BranchToolError(f"缺少本地公共基线 {BASE_BRANCH}")

    if local_branch_exists(target, cwd):
        ensure_descends_from_base(target, cwd)
        run_git(["switch", target], cwd)
        return f"已切换到本地分支 {target}"

    remote_target = f"{REMOTE}/{target}"
    if remote_branch_exists(target, cwd):
        ensure_descends_from_base(remote_target, cwd)
        run_git(["switch", "-c", target, "--track", remote_target], cwd)
        return f"已创建本地跟踪分支并切换到 {target}"

    run_git(["switch", "-c", target, BASE_BRANCH], cwd)
    return f"已从 {BASE_BRANCH} 创建并切换到 {target}"


def require_instruction_branch(spec: InstructionSpec, cwd: Path | str | None = None) -> None:
    if branch_location(spec, cwd) == "missing":
        raise BranchToolError(
            f"指令 {spec.name} 尚无分支；请先执行 open {spec.name}"
        )


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def set_implementation(
    spec: InstructionSpec,
    status: str,
    note: str,
    cwd: Path | str | None = None,
) -> dict[str, str]:
    require_instruction_branch(spec, cwd)

    def mutate(data: dict[str, object]) -> None:
        records = data["instructions"]
        assert isinstance(records, dict)
        record = record_for(data, spec)
        record["implementation"] = status
        record["implementation_note"] = note
        if status == "pending":
            record["verification"] = "pending"
            record["verification_note"] = ""
        record["updated_at"] = timestamp()
        records[spec.name] = record

    data = update_state(cwd, mutate)
    return record_for(data, spec)


def set_verification(
    spec: InstructionSpec,
    status: str,
    note: str,
    cwd: Path | str | None = None,
) -> dict[str, str]:
    require_instruction_branch(spec, cwd)

    def mutate(data: dict[str, object]) -> None:
        records = data["instructions"]
        assert isinstance(records, dict)
        record = record_for(data, spec)
        record["verification"] = status
        record["verification_note"] = note
        record["updated_at"] = timestamp()
        records[spec.name] = record

    data = update_state(cwd, mutate)
    return record_for(data, spec)


def print_verification(spec: InstructionSpec, cwd: Path | str | None = None) -> None:
    data = load_state(state_path(cwd))
    record = record_for(data, spec)
    location = branch_location(spec, cwd)
    slug = image_slug(spec)
    print(f"指令：{spec.extension} {spec.name}")
    print(f"分支：{branch_name(spec)} ({location})")
    print(f"实现：{record['implementation']}")
    print(f"验证：{record['verification']}")
    print(f"总体：{STATUS_LABELS[overall_status(location, record)]}")
    if record["verification_note"]:
        print(f"验证备注：{record['verification_note']}")
    print("\n验证流程（全部完成后再记录 pass）：")
    print("1. 生成器自测")
    print("   python vivado/tests/zb_training/tools/zb_tool.py selftest")
    print("2. 构建目标指令镜像")
    print(f"   cd vivado/tests && make zb-test ZB_INSN={spec.name}")
    print("3. 核对目标机器码")
    print(f"   检查 vivado/tests/build/zb_{slug}.dump")
    print("4. 运行目标指令 CPU-only 仿真")
    print(
        "   cd sim_cpu_only && make sim-verilator "
        f"IROM_COE=../vivado/tests/build/zb_{slug}.coe "
        "PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE"
    )
    print("5. 运行基础回归并检查单指令 RTL 差异")
    print("   ./sim_cpu_only/run_regression.sh")
    print(f"   git diff {BASE_BRANCH}...HEAD -- rtl")
    print("6. 记录结果")
    print(f"   python vivado/tests/zb_training/tools/zb_branch.py verify-set pass {spec.name}")


def create_test_repo(root: Path) -> tuple[Path, Path]:
    repo = root / "repo"
    remote = root / "remote.git"
    repo.mkdir()
    run_git(["init", "-q"], repo)
    run_git(["config", "user.name", "Zb Branch Selftest"], repo)
    run_git(["config", "user.email", "selftest@example.invalid"], repo)
    run_git(["config", "commit.gpgsign", "false"], repo)
    (repo / "README.md").write_text("selftest\n", encoding="utf-8")
    run_git(["add", "README.md"], repo)
    run_git(["commit", "-q", "-m", "test: base"], repo)
    run_git(["branch", "-M", BASE_BRANCH], repo)
    run_git(["init", "--bare", "-q", str(remote)], repo)
    run_git(["remote", "add", REMOTE, str(remote)], repo)
    run_git(["push", "-q", "-u", REMOTE, BASE_BRANCH], repo)
    return repo, remote


def run_selftest() -> None:
    assert len(SPECS) == 39
    assert canonical_spec("rev.b").name == "brev8"
    assert canonical_spec("xperm.n").name == "xperm4"
    assert canonical_spec("xperm.b").name == "xperm8"
    assert branch_name(canonical_spec("sext.b")) == "zb/zbb-sext-b"

    with tempfile.TemporaryDirectory(prefix="zb_branch_selftest_") as directory:
        root = Path(directory)
        repo, _ = create_test_repo(root)

        brev8 = canonical_spec("rev.b")
        message = open_instruction(brev8, repo)
        assert "创建并切换" in message
        assert current_branch(repo) == "zb/zbkb-brev8"
        assert overall_status(branch_location(brev8, repo), default_record()) == "developing"

        record = set_implementation(brev8, "implemented", "功能完成", repo)
        assert record["implementation"] == "implemented"
        assert overall_status(branch_location(brev8, repo), record) == "awaiting-verification"
        record = set_verification(brev8, "pass", "回归通过", repo)
        assert overall_status(branch_location(brev8, repo), record) == "complete"
        record = set_implementation(brev8, "pending", "继续修改", repo)
        assert record["verification"] == "pending"

        run_git(["switch", BASE_BRANCH], repo)
        andn = canonical_spec("andn")
        andn_branch = branch_name(andn)
        run_git(["branch", andn_branch, BASE_BRANCH], repo)
        run_git(["push", "-q", REMOTE, andn_branch], repo)
        run_git(["branch", "-D", andn_branch], repo)
        assert not local_branch_exists(andn_branch, repo)
        assert remote_branch_exists(andn_branch, repo)
        message = open_instruction(andn, repo)
        assert "跟踪分支" in message
        assert current_branch(repo) == andn_branch

        run_git(["switch", BASE_BRANCH], repo)
        dirty_file = repo / "dirty.txt"
        dirty_file.write_text("dirty\n", encoding="utf-8")
        try:
            open_instruction(canonical_spec("orn"), repo)
        except BranchToolError as error:
            assert "工作区不干净" in str(error)
        else:
            raise AssertionError("脏工作区未阻止分支切换")
        dirty_file.unlink()

        worktree = root / "worktree"
        run_git(["worktree", "add", "-q", "-b", "test/worktree", str(worktree), BASE_BRANCH], repo)
        assert state_path(repo) == state_path(worktree)
        assert len(status_rows(worktree)) == 39

    print("自测通过：39 条指令、别名、创建/切换、远端跟踪、状态迁移、脏树保护和 worktree 共享")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="查看 39 条指令的分支与完成状态")
    status.add_argument("instruction", nargs="?", help="可选指令名或别名")
    status.add_argument(
        "--filter",
        choices=("all", "complete", "incomplete"),
        default="all",
        help="筛选总体完成状态",
    )

    open_cmd = sub.add_parser("open", help="创建或切换到单指令分支")
    open_cmd.add_argument("instruction", help="指令名或别名")

    mark = sub.add_parser("mark", help="记录实现是否完成")
    mark.add_argument("status", choices=IMPLEMENTATION_STATES)
    mark.add_argument("instruction", nargs="?", help="省略时从当前分支推断")
    mark.add_argument("--note", default="", help="实现备注")

    verify = sub.add_parser("verify", help="查看当前指令的验证流程")
    verify.add_argument("instruction", nargs="?", help="省略时从当前分支推断")

    verify_set = sub.add_parser("verify-set", help="记录单一验证结果")
    verify_set.add_argument("status", choices=VERIFICATION_STATES)
    verify_set.add_argument("instruction", nargs="?", help="省略时从当前分支推断")
    verify_set.add_argument("--note", default="", help="验证备注")

    sub.add_parser("selftest", help="在临时 Git 仓库运行内置自测")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "status":
            print_status(args.instruction, args.filter)
        elif args.command == "open":
            print(open_instruction(canonical_spec(args.instruction)))
        elif args.command == "mark":
            spec = select_spec(args.instruction)
            record = set_implementation(spec, args.status, args.note)
            print(
                f"已记录 {spec.name}: implementation={record['implementation']}, "
                f"verification={record['verification']}"
            )
        elif args.command == "verify":
            print_verification(select_spec(args.instruction))
        elif args.command == "verify-set":
            spec = select_spec(args.instruction)
            record = set_verification(spec, args.status, args.note)
            print(
                f"已记录 {spec.name}: verification={record['verification']}, "
                f"overall={STATUS_LABELS[overall_status(branch_location(spec), record)]}"
            )
        else:
            run_selftest()
    except (BranchToolError, AssertionError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
