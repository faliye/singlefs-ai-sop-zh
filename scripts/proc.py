#!/usr/bin/env python3
"""找进程、按 pid 等进程、按 pid 停进程：替掉 `pgrep -f` / `pkill -f` / `killall`。

为什么：`pgrep -f` / `pkill -f` 拿模式串去比整条命令行，而发出这条命令的 shell 自己的命令行里就带着那个模式串——
拿它当等待条件的循环永远不退出，拿它杀进程会连自己一起杀（singlefs 2026-09-17、2026-09-19 两次实测；
rules/command-safety.md 禁用这几种写法，脚本里由 scripts/shell-lint.sh 的 S2、S3 判，会话里手敲的命令由
scripts/claude-hooks/pattern-process-guard.sh 在执行前拒绝）。这里三件事都按 pid 办：

    proc.py find 可执行文件名 [--argument 参数]   # 列出进程：可执行文件名（argv[0] 或 /proc/<pid>/exe 的文件名）逐字相等，
                                                  # 给了 --argument 时还要有一个参数逐字等于它（或文件名等于它的文件名）；
                                                  # 发出这条命令的那一支进程树（自己与全部祖先）一律不列
    proc.py wait 进程号… --timeout 秒 [--interval 秒]  # 等这几个进程都退出；超时退出码 3 并列出还活着的（--timeout 必给）
    proc.py stop 进程号 [--grace 秒]               # 先 TERM，过 grace 秒还在就 KILL；自己与祖先拒绝停
    proc.py --selftest                           # 起几个 sleep 走一遍；PROC_BREAK=ancestors|timeout|stopself 时必须判红

等自己起的进程，最省事的仍是起的时候 `process_id=$!` 记下来、`wait "$process_id"`；要会话在它跑完时叫醒调度的一方，
就放后台起（Claude Code 的 run_in_background）、等完成通知。这个脚本给的是「进程不是自己起的、或 pid 没记下来」时的写法：
先 `find` 拿到 pid，再 `wait` / `stop` 那个 pid。

退出码：0 成；1 自检不过；2 参数错或拒绝（停自己、停祖先、进程号不存在）；3 等超时。
"""
import argparse
import os
import signal
import subprocess
import sys
import time

BROKEN = os.environ.get("PROC_BREAK", "")


def ancestor_process_ids():
    """自己与全部祖先的进程号。"""
    found, current = set(), os.getpid()
    while current and current not in found:
        found.add(current)
        try:
            with open(f"/proc/{current}/stat") as handle:
                current = int(handle.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return found


def arguments_of(process_id):
    try:
        with open(f"/proc/{process_id}/cmdline", "rb") as handle:
            return [part.decode(errors="replace") for part in handle.read().split(b"\0") if part]
    except OSError:
        return []


def executable_name_of(process_id, arguments):
    names = set()
    if arguments:
        names.add(os.path.basename(arguments[0]))
    try:
        names.add(os.path.basename(os.readlink(f"/proc/{process_id}/exe")))
    except OSError:
        pass
    return names


def is_alive(process_id):
    try:
        with open(f"/proc/{process_id}/stat") as handle:
            return handle.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def find(executable_name, argument):
    excluded = set() if BROKEN == "ancestors" else ancestor_process_ids()
    matches = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) in excluded:
            continue
        process_id = int(entry)
        arguments = arguments_of(process_id)
        if not arguments or executable_name not in executable_name_of(process_id, arguments):
            continue
        if argument is not None and not any(value == argument or os.path.basename(value) == os.path.basename(argument) for value in arguments[1:]):
            continue
        matches.append((process_id, arguments))
    return sorted(matches)


def wait(process_ids, timeout_seconds, interval_seconds):
    deadline = time.monotonic() + timeout_seconds
    while True:
        alive = [process_id for process_id in process_ids if is_alive(process_id)]
        if not alive:
            return []
        if BROKEN != "timeout" and time.monotonic() >= deadline:
            return alive
        time.sleep(min(interval_seconds, max(0.05, deadline - time.monotonic())))


def stop(process_id, grace_seconds):
    if process_id in ancestor_process_ids() and BROKEN != "stopself":
        return "refused"
    if not is_alive(process_id):
        return "missing"
    os.kill(process_id, signal.SIGTERM)
    if not wait([process_id], grace_seconds, 0.1):
        return "terminated"
    os.kill(process_id, signal.SIGKILL)
    return "killed" if not wait([process_id], 5, 0.1) else "still-alive"


def selftest():
    failures = []
    # sleep 的参数：只有这一份自检起的 sleep 带它。带上本进程号：几份自检同时跑时（三个语言仓并行跑 selftest），
    # 参数写死的话 find 会把别的那份起的 sleep 也列出来，两份一起判红（2026-09-19 实测）
    marker = f"4242.{os.getpid()}"
    sleepers = [subprocess.Popen(["sleep", marker]) for _ in range(2)]
    try:
        found_ids = [process_id for process_id, _ in find("sleep", marker)]
        if sorted(found_ids) != sorted(process.pid for process in sleepers):
            failures.append(f"find sleep --argument {marker} 应当正好列出起的两个 sleep {[p.pid for p in sleepers]}，实际 {found_ids}")
        own_ids = [process_id for process_id, _ in find(os.path.basename(sys.executable), None)]
        if os.getpid() in own_ids:
            failures.append("find 列出了发出这条命令的进程自己（祖先那一支应当排除）")
        # 超时那一项在子进程里跑、外面套硬超时：破坏开关打开时 wait 不会自己返回，不能把自检挂死
        try:
            timed = subprocess.run([sys.executable, os.path.abspath(__file__), "wait", str(sleepers[0].pid), "--timeout", "0.3", "--interval", "0.05"],
                                   capture_output=True, text=True, timeout=10)
            if timed.returncode != 3:
                failures.append(f"wait 在进程还活着时应当超时退出码 3，实际 {timed.returncode}")
        except subprocess.TimeoutExpired:
            failures.append("wait 给了 --timeout 0.3 却 10 秒没返回")
        outcome = stop(sleepers[0].pid, 2)
        sleepers[0].wait()
        if outcome not in ("terminated", "killed"):
            failures.append(f"stop 应当停掉 sleep，实际 {outcome}")
        if wait([sleepers[0].pid], 2, 0.05) != []:
            failures.append("停掉之后 wait 应当立刻返回")
        # 拒绝停祖先：在一次性的 bash 里让 proc.py 去停这个 bash（它的父进程）。拒绝时 bash 接着打出退出码；
        # 破坏开关打开时被停掉的只是这个一次性的 bash，不是跑自检的那一支（singlefs 2026-09-19 实测：拿真的 getppid 试，把调用它的 shell 一起停了）
        refusal = subprocess.run(["bash", "-c", f'"{sys.executable}" "{os.path.abspath(__file__)}" stop $$ --grace 1; echo "exit=$?"'],
                                 capture_output=True, text=True, timeout=30)
        if "exit=2" not in refusal.stdout:
            failures.append(f"stop 停自己的祖先应当拒绝（退出码 2），实际输出 {refusal.stdout.strip()[:80]!r}、bash 退出码 {refusal.returncode}")
    finally:
        for process in sleepers:
            if process.poll() is None:
                process.kill()
                process.wait()
    for failure in failures:
        print(f"  ✗ 自检：{failure}")  # gate-lint:detail
    if failures:
        print("    → 看 find() 的祖先排除、wait() 的超时与 stop() 的祖先拒绝；PROC_BREAK 设着的话这里本来就该红")
        return 1
    print("  ✓ proc.py 自检通过：find 按可执行文件名加参数逐字找、不列自己那一支，wait 到点超时、进程没了立刻返回，stop 停得掉、停祖先拒绝（查了 6 项）")
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        return selftest()
    parser = argparse.ArgumentParser(description="找进程、按 pid 等进程、按 pid 停进程（替掉 pgrep -f / pkill -f / killall）")
    commands = parser.add_subparsers(dest="command", required=True)
    find_command = commands.add_parser("find")
    find_command.add_argument("executable_name")
    find_command.add_argument("--argument")
    wait_command = commands.add_parser("wait")
    wait_command.add_argument("process_ids", nargs="+", type=int)
    wait_command.add_argument("--timeout", type=float, required=True)
    wait_command.add_argument("--interval", type=float, default=5)
    stop_command = commands.add_parser("stop")
    stop_command.add_argument("process_id", type=int)
    stop_command.add_argument("--grace", type=float, default=10)
    arguments = parser.parse_args()
    if arguments.command == "find":
        for process_id, process_arguments in find(arguments.executable_name, arguments.argument):
            print(process_id, " ".join(process_arguments)[:200])
        return 0
    if arguments.command == "wait":
        alive = wait(arguments.process_ids, arguments.timeout, arguments.interval)
        if alive:
            print(f"  ✗ 等了 {arguments.timeout:g} 秒，这些进程还在：{alive}")
            print("    → 怎么办：看它在不在动（ps -o pid,etimes,time,args -p 进程号），在动就再等一次；不动就报给调度的一方定，不自己停")
            return 3
        print(f"  ✓ {arguments.process_ids} 都已退出")
        return 0
    outcome = stop(arguments.process_id, arguments.grace)
    if outcome == "refused":
        print(f"  ✗ {arguments.process_id} 是发出这条命令的进程自己或它的祖先，不停")
        print("    → 怎么办：先 ps -eo pid,ppid,etimes,cmd 看清要停的是哪一个，再给它的进程号")
        return 2
    if outcome == "missing":
        print(f"  ✗ {arguments.process_id} 已经不在了")
        print("    → 怎么办：它可能已经跑完；用 proc.py find 或 ps 再核一次要停的是不是这个号")
        return 2
    print(f"  ✓ {arguments.process_id}：{outcome}")
    return 0 if outcome in ("terminated", "killed") else 2


if __name__ == "__main__":
    sys.exit(main())
