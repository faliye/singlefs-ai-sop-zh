#!/usr/bin/env python3
"""项目根 .claude/doc-lint-exclude 登记的冻结证据目录：只在这一处读。

原样保存的证据不扫（rules/evidence-discipline.md「门禁也得绕开这批目录」）。doc-lint.sh 自己判这份清单写得对不对
（理由、目录在不在、排没排到东西）；这里只读出目录，给按前缀跳过的几道门禁共用。

不单独跑，由别的脚本按路径载入（preflight.py 的 load_package_module），函数照原名调。
"""
import os
import sys

# 不写 __pycache__：避免门禁跑的过程中生成未跟踪文件
sys.dont_write_bytecode = True


def frozen_evidence_directories(repository_root):
    """登记的目录，相对项目根，去掉结尾的 `/`；按前缀跳过时由调用方补上 `/`。清单不在就是空的。"""
    registered_directories = []
    try:
        with open(os.path.join(str(repository_root), '.claude', 'doc-lint-exclude'), encoding='utf-8') as exclude_file:
            for line in exclude_file:
                registered_path = line.split('#')[0].strip()
                while registered_path.startswith('./'):
                    registered_path = registered_path[2:]
                registered_path = registered_path.rstrip('/')
                if registered_path:
                    registered_directories.append(registered_path)
    except OSError:
        pass
    return tuple(registered_directories)


def frozen_evidence_prefixes(repository_root):
    """同一份清单，每条补上结尾的 `/`，给 `path.startswith(prefix)` 用。"""
    return tuple(directory + '/' for directory in frozen_evidence_directories(repository_root))
