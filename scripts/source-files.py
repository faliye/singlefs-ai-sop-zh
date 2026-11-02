#!/usr/bin/env python3
"""扫全仓源码的几道门禁共用的走法：从仓根往下取某几种后缀的文件，跳过冻结证据。

扫哪些：仓根下的每个顶层目录，SKIP_TOP_DIRECTORIES（.git、node_modules、target、fixtures）与点开头的不扫，点开头里 `.claude` 起头的照扫；
往下走时 SKIPPED_DIRECTORY_NAMES（.git、target、node_modules、__pycache__）不进。
不扫：项目根 `.claude/doc-lint-exclude` 登记的目录（evidence-exclude.py 读），那是原样保存的证据（rules/evidence-discipline.md「原样保存的证据不许事后改」）；
每个登记目录里跳过了几个文件现数出来，交给调用方报进统计。

不单独跑，由 relay-timing-lint.py、duplicate-definitions.py 与 code-name-lint.py（只用 default_root）按路径载入（preflight.py 的 load_package_module），函数照原名调；
不给仓库根时判哪个仓（default_root）也在这里，两边一样。
"""
import dataclasses
import os
import pathlib
import subprocess
import sys

# 不写 __pycache__：避免门禁跑的过程中生成未跟踪文件
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module  # noqa: E402
EVIDENCE_EXCLUDE = load_package_module("evidence_exclude", "evidence-exclude.py")

SKIP_TOP_DIRECTORIES = {".git", "node_modules", "target", "fixtures"}
SKIPPED_DIRECTORY_NAMES = (".git", "target", "node_modules", "__pycache__")


@dataclasses.dataclass
class SourceWalk:
    relative_paths: list        # 相对仓根、以 / 分隔，按目录序排好
    frozen_file_counts: dict    # 冻结证据目录 → 在里面跳过的、后缀对得上的文件数


def scanned_top_directories(repository_root: pathlib.Path) -> tuple:
    entries = sorted(os.listdir(repository_root))
    return tuple(
        name for name in entries
        if (repository_root / name).is_dir() and name not in SKIP_TOP_DIRECTORIES and not name.startswith(".")
    ) + tuple(
        name for name in entries
        if (repository_root / name).is_dir() and name.startswith(".claude")
    )


def walk_source_files(repository_root: pathlib.Path, suffixes: tuple) -> SourceWalk:
    frozen_directories = EVIDENCE_EXCLUDE.frozen_evidence_directories(repository_root)
    frozen_file_counts = {directory: 0 for directory in frozen_directories}
    relative_paths = []
    for top_directory in scanned_top_directories(repository_root):
        for directory, subdirectories, file_names in os.walk(repository_root / top_directory):
            subdirectories[:] = sorted(name for name in subdirectories if name not in SKIPPED_DIRECTORY_NAMES)
            for file_name in sorted(file_names):
                if not file_name.endswith(suffixes):
                    continue
                relative_path = (pathlib.Path(directory) / file_name).relative_to(repository_root).as_posix()
                frozen_directory = next((candidate for candidate in frozen_directories if relative_path.startswith(candidate + "/")), None)
                if frozen_directory is not None:
                    frozen_file_counts[frozen_directory] += 1
                    continue
                relative_paths.append(relative_path)
    return SourceWalk(relative_paths, frozen_file_counts)


def default_root() -> pathlib.Path:
    """不给仓库根时判当前目录所在的 git 仓（不在 git 仓里就是当前目录）。不按本文件的位置往上数：
    它装在上游包的 scripts/ 下、也装在项目的 .claude/<包名>/scripts/ 下，往上数几层都数不到被判的那个仓。"""
    git_toplevel_run = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False,
                                      stdin=subprocess.DEVNULL)
    toplevel_directory = git_toplevel_run.stdout.strip()
    return pathlib.Path(toplevel_directory) if git_toplevel_run.returncode == 0 and toplevel_directory else pathlib.Path.cwd()
