#!/usr/bin/env bash
# 样本：bad 的四种非行首形态。BAD_CALL_PATTERN 只认行首的话，这四条全部漏检。
check_a() { [[ -f x ]] || { bad "甲不合格"; exit 1; }; }
check_b() { [[ -f x ]] && bad "乙不合格"; }
check_c() { if [[ -f x ]]; then bad "丙不合格"; fi; }
check_d() { if [[ -f x ]]; then :; else bad "丁不合格"; fi; }
