#!/usr/bin/env bash
# 样本：拒绝写在内嵌 python 里。heredoc 体默认不当代码读，解释器 heredoc 要读。
find . -name '*.md' > /dev/null
python3 - <<'PY'
n = 3
print(f'  ✗ {n} 处编号与登记位不符')
PY
