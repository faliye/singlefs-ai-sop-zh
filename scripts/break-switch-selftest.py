#!/usr/bin/env python3
"""python 写的门禁与钩子共用的自证收尾：弄坏开关下怎么报、逐个打开弄坏开关核它红在点名的样本上
（rules/test-discipline.md「每一个弄坏开关都必须会红」）。

约定：被测脚本带 `--selftest` 时先判自己的红绿样本，得到判错的样本列表 `[(样本名, 期望, 实际), …]`，交给 finish_selftest：
  环境变量里开着弄坏开关时按开关报；没开时判错就点名，再逐个开关另起子进程跑 `<脚本> --selftest`，
  要求退出码 1、输出里有「判错的样本：<点名的样本>（」。

不单独跑，由 duplicate-definitions.py、code-name-lint.py、borrowed-convention.py 按路径载入（preflight.py 的 load_package_module），函数照原名调。
"""
import os
import subprocess
import sys

sys.dont_write_bytecode = True


def report_under_break_switch(switch_name, misjudged_cases, case_count):
    """开着弄坏开关时的收尾：判错就退 1 并逐个点名，没判错退 0（由不带开关的自证判它是不是该红）。"""
    for case_name, expected, actual in misjudged_cases:
        print(f"      判错的样本：{case_name}（期望 {expected}，实际 {actual}）")   # gate-lint:detail
    if misjudged_cases:
        print(f"  ✗ 弄坏开关 {switch_name} 下自证判错 {len(misjudged_cases)} 个样本")
        print("     → 怎么办：这是弄坏开关下的预期结果，由不带开关的自证核它红在点名的样本上；单跑时去掉这个环境变量。")
        return 1
    print(f"  ✓ 弄坏开关 {switch_name} 下自证居然通过了（{case_count} 个样本）")
    return 0


def report_misjudged_cases(script_name, misjudged_cases, case_count, functions_to_fix):
    """不带开关的自证判错了样本：逐个点名，退 1。没判错退 0、不打印。"""
    if not misjudged_cases:
        return 0
    for case_name, expected, actual in misjudged_cases:
        print(f"      {case_name}：期望 {expected}，实际 {actual}")   # gate-lint:detail
    print(f"  ✗ {script_name} 自证判错 {len(misjudged_cases)} 个样本（共 {case_count} 个）")
    print(f"     → 怎么办：看判错的样本，修 {script_name} 的 {functions_to_fix} 再跑 --selftest。")
    return 1


def verify_break_switches(script_path, environment_variable, break_switches):
    """break_switches：开关名 → 打开后必须红在的样本名。全部红在点名处退 0、不打印；否则逐个点名，退 1。"""
    silent_switches = []
    for switch_name, expected_case_name in break_switches.items():
        switch_environment = dict(os.environ)
        switch_environment[environment_variable] = switch_name
        switch_run = subprocess.run([sys.executable, os.path.abspath(script_path), "--selftest"], env=switch_environment,
                                    capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
        if switch_run.returncode != 1 or f"判错的样本：{expected_case_name}（" not in switch_run.stdout:
            silent_switches.append((switch_name, expected_case_name, switch_run.returncode))
    if not silent_switches:
        return 0
    for switch_name, expected_case_name, returncode in silent_switches:
        print(f"      {switch_name}：退出码 {returncode}，或者没有红在「{expected_case_name}」上")   # gate-lint:detail
    print(f"  ✗ 有 {len(silent_switches)} 个弄坏开关打开后自证没红在点名的样本上（共 {len(break_switches)} 个开关）")
    print("     → 怎么办：改样本让它红在开关表点名的那一格，或改开关让它真的弄坏点名的那一处；两样都修不了就删掉这个开关"
          f"（rules/test-discipline.md「每一个弄坏开关都必须会红」）。单跑：{environment_variable}=<开关名> python3 {os.path.realpath(script_path)} --selftest")
    return 1


def finish_selftest(script_path, environment_variable, break_switches, misjudged_cases, case_count, functions_to_fix):
    """被测脚本判完红绿样本之后调。开着弄坏开关：按开关报；没开：判错就点名，再逐个打开开关核。
    返回 None 表示全对、由调用方报成功并退 0；否则返回退出码。"""
    switch_name = os.environ.get(environment_variable, "")
    if switch_name:
        return report_under_break_switch(switch_name, misjudged_cases, case_count)
    if report_misjudged_cases(os.path.basename(script_path), misjudged_cases, case_count, functions_to_fix) != 0:
        return 1
    if verify_break_switches(script_path, environment_variable, break_switches) != 0:
        return 1
    return None
