#!/usr/bin/env python3
# admission: always 样本：每次调都有意义，它判的是此刻的输入
# run-condition: command python3
"""样本工具。"""
import os
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402
print("先干活")


def main():
    return len(sys.argv)


preflight(__file__)
sys.exit(main())
