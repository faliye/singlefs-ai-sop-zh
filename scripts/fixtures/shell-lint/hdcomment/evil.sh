#!/usr/bin/env bash
# 样本：注释里的 heredoc 不该让其后整个文件免检。下面 S1 那处违规必须照样红。
# 用法示例： cat <<EOF
run_one() {
  log_path="/tmp/x.log"
  echo done
}
out="$(run_one)"
echo "$log_path"
