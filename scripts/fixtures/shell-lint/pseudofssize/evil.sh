#!/usr/bin/env bash
# 样本：拿文件大小判 /proc、/sys、cgroupfs 下的文件空不空。
# procfs 与 cgroupfs 报 0、sysfs 报 4096，这几行判出来的跟内容无关。
set -uo pipefail
cgroup_directory="/sys/fs/cgroup/system.slice/inference.service"

if [ -s "$cgroup_directory/cgroup.procs" ]; then echo "服务里还有进程"; fi
[[ ! -s /proc/self/status ]] && echo "读不到进程状态"
if [[ -n "$cgroup_directory" && -s "${cgroup_directory}/cgroup.events" ]]; then echo "有事件"; fi
test -s /sys/class/net/lo/mtu || echo "没有 mtu"
size_in_bytes="$(stat -c %s /proc/meminfo)"
find /sys/fs/cgroup -name cgroup.procs -empty -print
