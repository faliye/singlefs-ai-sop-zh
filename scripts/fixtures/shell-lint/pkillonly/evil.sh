#!/usr/bin/env bash
# 样本：只有 pkill -f。
stop_worker() {
  pkill -f batch-job-runner
}
stop_worker
