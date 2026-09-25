#!/usr/bin/env bash
# 准入与运行条件的 shell 入口（rules/preflight-discipline.md）：只定义两个函数，不改 shell 选项。
# lib.sh source 它；不 source lib.sh 的钩子直接 source 它（不必为了判条件平白多出 set -e 与 gawk 这两样依赖）。
# 判据只在 preflight.py 一处：这里只摘掉 --force、转过去，按它的结果退出或往下走。
#
#   preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
#       满足 → 接着跑；不满足 → 报原因与出路、退出码 78；带了 --force → 照跑，PREFLIGHT_FORCED 置成没满足的条件摘要（导出，
#       写产物的把它写进产物）。没有 python3 时判不了，按不满足办。
#       留下：PREFLIGHT_SCRIPT（脚本的绝对路径）、PREFLIGHT_ARGUMENTS（摘掉 --force 的参数）、PREFLIGHT_FORCE_GIVEN（带没带 --force）、
#       PREFLIGHT_INPUT_FINGERPRINT（开跑时判的输入指纹；没声明 inputs-changed 时是 -）。
#   preflight_record_success
#       声明了 inputs-changed 的脚本成功跑完、退出之前调：记下开跑时判的那份指纹。强制跑的、跑的过程中输入变了的，不记。

# preflight.py 的绝对路径在 source 的这一刻算好：脚本之后 cd 到别处，相对路径就指不到了
PREFLIGHT_LIBRARY_DIRECTORY="${BASH_SOURCE[0]%/*}"
if [[ "$PREFLIGHT_LIBRARY_DIRECTORY" == "${BASH_SOURCE[0]}" ]]; then PREFLIGHT_LIBRARY_DIRECTORY=.; fi
PREFLIGHT_PROGRAM="$(cd "$PREFLIGHT_LIBRARY_DIRECTORY" && pwd -P)/preflight.py"
unset PREFLIGHT_LIBRARY_DIRECTORY

preflight() { # preflight <脚本路径> <脚本收到的参数…>
  local preflight_script_directory preflight_argument preflight_status preflight_exit_code=0 preflight_force_option=()
  preflight_script_directory="${1%/*}"
  if [[ "$preflight_script_directory" == "$1" ]]; then preflight_script_directory=.; fi
  PREFLIGHT_SCRIPT="$(cd "$preflight_script_directory" && pwd -P)/${1##*/}"; shift
  PREFLIGHT_ARGUMENTS=(); PREFLIGHT_FORCE_GIVEN=0; PREFLIGHT_FORCED=""; PREFLIGHT_INPUT_FINGERPRINT=-
  for preflight_argument in "$@"; do
    if [[ "$preflight_argument" == --force ]]; then PREFLIGHT_FORCE_GIVEN=1; else PREFLIGHT_ARGUMENTS+=("$preflight_argument"); fi
  done
  if [[ $PREFLIGHT_FORCE_GIVEN -eq 1 ]]; then preflight_force_option=(--force); fi
  if ! command -v python3 >/dev/null 2>&1; then
    if [[ $PREFLIGHT_FORCE_GIVEN -eq 1 ]]; then
      printf '  ! %s：没有 python3，准入与运行条件一条都没判；--force 照跑（这一次的结果记成「强制跑」）\n' "$PREFLIGHT_SCRIPT" >&2
      PREFLIGHT_FORCED="没有 python3，条件一条都没判"; export PREFLIGHT_FORCED
      return 0
    fi
    printf '  ✗ %s：没有 python3，判不了准入与运行条件，拒绝执行（退出码 78）\n' "$PREFLIGHT_SCRIPT" >&2
    printf '     → 怎么办： 装上 python3 再跑（判据在 scripts/preflight.py）；确认要在没判条件时照跑，加 --force\n' >&2
    exit 78
  fi
  preflight_status="$(python3 "$PREFLIGHT_PROGRAM" check "$PREFLIGHT_SCRIPT" ${preflight_force_option[@]+"${preflight_force_option[@]}"} \
    -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"})" || preflight_exit_code=$?
  case "$preflight_exit_code" in
    0)  ;;
    78) exit 78 ;;
    *)
      printf '  ✗ 判不了 %s 的准入与运行条件（preflight.py 退出码 %s）\n' "$PREFLIGHT_SCRIPT" "$preflight_exit_code" >&2
      printf '     → 怎么办： 照上面 preflight.py 的原话改那个脚本的文件头；写法见 rules/preflight-discipline.md\n' >&2
      exit 1 ;;
  esac
  case "$preflight_status" in
    forced*) PREFLIGHT_FORCED="${preflight_status#forced*$'\t'*$'\t'}" ;;
    met$'\t'*) PREFLIGHT_INPUT_FINGERPRINT="${preflight_status#met$'\t'}" ;;
  esac
  export PREFLIGHT_FORCED
}

preflight_record_success() {
  if [[ -n "${PREFLIGHT_FORCED:-}" ]]; then
    printf '  ! 这一次是强制跑的，不记成「上次成功」：下一次照判输入变没变\n' >&2
    return 0
  fi
  if [[ "${PREFLIGHT_INPUT_FINGERPRINT:--}" == - ]]; then return 0; fi
  python3 "$PREFLIGHT_PROGRAM" record "$PREFLIGHT_SCRIPT" --fingerprint "$PREFLIGHT_INPUT_FINGERPRINT" \
    -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"} \
    || printf '  ! 没记下这一次的输入指纹（preflight.py 的原话在上面）：下一次照跑\n' >&2
}
