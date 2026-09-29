#!/usr/bin/env python3
# admission: always 是纯函数式的文本转换，没有可缓存的输入
# run-condition: none 只读标准输入、写标准输出，没有环境要求
"""从一份 kb 文档的文本里抽「历史条目的位置钥匙」，给 history-ordinal.sh 判撞号用。

读标准输入（一份 .md 文件的整份内容），每条**带编号**的历史条目产一行到标准输出，
四段用 \\x1f 隔开：最近的「## 」标题、最近的「### 日期」标题、点名词（或去掉编号后的整句）、
「（其 N）」编号本身。没有编号的条目不产行——这份脚本只管编号撞不撞，不管别的。

两种输入形态都认：
  - 新形态：`### 2026-09-28` 单独一行，下面挂 `#### 已定项 7（其一）：……` 这样的子标题；
  - 旧形态（还没搬迁的文件）：日期与编号融合在同一行，`### 2026-09-28（其一）：……`。
"""
import os
import re
import sys
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

H2 = re.compile(r'^## (.*)')
H3_DATE = re.compile(r'^### (20\d\d-\d\d-\d\d)(.*)$')
H4 = re.compile(r'^#### (.*)$')
ORDINAL = re.compile(r'（其[^）]*）')
# 点名词：已定项 N / 未定项 N / E<n>（后面跟左括号，避免把普通单词里的 E 加数字也认成点名词）
MENTION = re.compile(r'已定项\s*\d+|未定项\s*\d+|E\d+（')


def ordinal_of(text):
    """旧融合写法（日期后面直接跟内容）的键：只认「（其 N）」本身，title 文字不算进键——
    旧约定里编号是按整个日期编的，不按标题文字分组，见文件头。"""
    match = ORDINAL.search(text)
    return match.group(0) if match else ''


def stem_and_ordinal(text):
    """新嵌套写法（H4 子标题）的键：编号 +（点名词，没有就用去掉编号后的整句）。"""
    match = ORDINAL.search(text)
    ordinal = match.group(0) if match else ''
    without_ordinal = (text[:match.start()] + text[match.end():]) if match else text
    mention = MENTION.search(without_ordinal)
    stem = mention.group(0) if mention else without_ordinal.strip()
    return stem, ordinal


def keys_of(text):
    h2 = ''
    h3_date = None
    keys = []
    for line in text.splitlines():
        m2 = H2.match(line)
        if m2:
            h2 = m2.group(1).strip()
            h3_date = None
            continue
        m3 = H3_DATE.match(line)
        if m3:
            date, suffix = m3.group(1), m3.group(2).strip()
            if suffix:
                # 融合旧写法：日期后面直接跟内容，整段当一条目；键不含 title 文字
                ordinal = ordinal_of(suffix)
                if ordinal:
                    keys.append((h2, date, '', ordinal))
                h3_date = None
            else:
                h3_date = date
            continue
        m4 = H4.match(line)
        if m4 and h3_date is not None:
            stem, ordinal = stem_and_ordinal(m4.group(1).strip())
            if ordinal:
                keys.append((h2, h3_date, stem, ordinal))
    return keys


def main():
    text = sys.stdin.read()
    for key in keys_of(text):
        sys.stdout.write('\x1f'.join(key) + '\n')


if __name__ == '__main__':
    preflight(__file__)
    main()
