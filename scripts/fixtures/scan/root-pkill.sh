#!/usr/bin/env bash
# 包根的脚本：按模式杀进程，必须被扫到。
stop_worker() {
  pkill -f batch-job-runner
}
