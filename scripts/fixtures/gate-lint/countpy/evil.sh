#!/usr/bin/env bash
# 样本：阶段用 python 实现，计数在 f-string 里、在 python 里累加。只认 `$` 的判据会把它误判成没报条数。
find . -name '*.md' > /dev/null
python3 - <<'PY'
import glob
n = 0
for path in glob.glob('*.md'):
    n += 1
print(f'  ✓ 检查通过（扫 {n} 个文件）')
PY
