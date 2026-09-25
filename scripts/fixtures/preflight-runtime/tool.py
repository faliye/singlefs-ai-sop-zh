#!/usr/bin/env python3
# 样本：python 脚本在 __main__ 段第一句判条件；设了 SAMPLE_BLOCKED 就不许跑。
# admission: always 样本：每次调都有意义
# run-condition: check test -z "${SAMPLE_BLOCKED:-}" :: 样本：设了 SAMPLE_BLOCKED 就不许跑，先 unset 它
import os
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

if __name__ == '__main__':
    preflight(__file__)
    print(f'跑了 参数={sys.argv[1:]} 强制=[{os.environ.get("PREFLIGHT_FORCED", "")}]')
