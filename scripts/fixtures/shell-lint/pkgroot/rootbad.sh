#!/usr/bin/env bash
# 样本：仓根的脚本也要扫。
stop_worker() {
  pkill -f batch-job-runner
}
stop_worker
