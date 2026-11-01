#!/usr/bin/env bash
# 样本：这几种都不判。
set -uo pipefail
cgroup_directory="/sys/fs/cgroup/system.slice/inference.service"
log_file="${TMPDIR:-/tmp}/run.log"

# 读出内容再判——这是出路本身。
if [[ -n "$(< "$cgroup_directory/cgroup.procs")" ]]; then echo "服务里还有进程"; fi

# 普通文件拿大小判，没问题；同一行别的命令里的 /proc 不是 -s 的参数。
[[ -s "$log_file" ]] && cat /proc/loadavg
size_in_bytes="$(stat -c %s "$log_file")"
find "${TMPDIR:-/tmp}" -maxdepth 1 -name '*.log' -empty -print

# 前面接着变量的 /proc 不是伪文件系统：这是镜像根下面的普通目录。
image_root="${TMPDIR:-/tmp}/image"
[ -s "$image_root/proc/config" ] && echo "镜像里有配置"

# 别的命令的 -s 选项不是测试：curl 的静默、sort 的稳定排序。
curl -s http://localhost/health > /dev/null || true
sort -s /proc/self/maps > /dev/null
