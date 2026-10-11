#!/usr/bin/env python3
# gate-similar: doc-lint.sh 它按词表与形态判文档里的字句，不解析 ](相对路径) 链接，也不数「第 N 节」指到哪；这一道在盘上解析链接目标、数目标文档的节
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: none 只读仓里的 markdown，不碰别的环境
"""文档里的相对链接与「第 N 节」指向，指不指得到。

两类都会静默失效：
  ① `[x](../../CLAUDE.md)` —— 路径少一层就指到不存在的地方，或恰好指到另一个同名文件；
  ② 「见 X.md 第三节」 —— 目标文档加一节、删一节，序号就指向别的东西了。

枚举文件用 os.walk，不用 glob('**/*.md')：后者默认不匹配点开头的目录，`.claude/` 下的文档全漏掉、照样报绿
（实测：报「0 处指不到」时正有一条坏链接）。
"""
import os, re, sys
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__：门禁跑到一半冒出一个未跟踪的目录，「工作区跑的过程中没变」就对不上
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight, project_gate_directory  # noqa: E402
preflight(__file__)

SKIP = {'.git', 'node_modules', 'target'}
# `gate.d/fixtures/` 里的红样本故意放着坏链接；样本在临时目录里以那里为根判，本仓跳过它不影响自证。
def _excluded_dirs():
    """从 .claude/doc-lint-exclude 读要绕开的目录（evidence-discipline.md「门禁也得绕开这批目录」）：
    原样保存的证据不许事后改，要求人去改原件的检查只会逼断证据链。
    """
    out = []
    try:
        with open('.claude/doc-lint-exclude', encoding='utf-8') as f:
            for line in f:
                line = line.split('#')[0].strip()
                if line:
                    out.append(line if line.endswith('/') else line + '/')
    except OSError:
        pass
    return tuple(out)


PACKAGE_FAMILY = load_package_module('package_family', 'package-family.py')

# 装进项目的 SOP 副本不判：副本里的 templates/ 是给别的项目用的模板，相对路径按「拷到项目根之后」写，
# 在副本里当然指不到；副本也不许在项目里就地改（改共享规则只能改上游）。templates/ 在 SOP 仓自己里也跳过，理由相同。
# gate.sh 已经 cd 到项目根，project_gate_directory('.') 读的是这个项目登记的门禁目录（没登记就是默认值 .claude/gate.d）。
SKIP_PATH = (PACKAGE_FAMILY.installed_package_directory(), project_gate_directory('.') + '/fixtures/',
             'scripts/fixtures/', 'templates/') + _excluded_dirs()
CN = {'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10}

def md_files(root='.'):
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP]
        for f in fns:
            if f.endswith('.md'):
                yield os.path.normpath(os.path.join(dp, f))

def mask_code(s):
    """把代码块与行内代码涂成同长的空格，行号不变。

    反引号里的东西不是链接：`[本该](决策|实验)` 是一条正则，不涂就会报成坏链接（实测撞过，报的是 doc-lint 自己的规则串）。
    """
    def blank(m):
        return re.sub(r'[^\n]', ' ', m.group(0))
    s = re.sub(r'```.*?```', blank, s, flags=re.S)
    s = re.sub(r'`[^`\n]*`', blank, s)
    return s


def heads(path):
    """→ 这份文档的 ## 节标题；读不了（不存在、没权限、不是 UTF-8）返回 None，别让「读不出」装成「没有这一节」。"""
    try:
        return re.findall(r'^## (.+)$', open(path, encoding='utf-8').read(), re.M)
    except (OSError, UnicodeDecodeError):
        return None

bad = []
n_link = n_sec = n_file = 0
for p in sorted(md_files()):
    if p.startswith(SKIP_PATH):
        continue
    base = os.path.dirname(p) or '.'
    # 读不了的文档（坏掉的符号链接、没有读权限、不是 UTF-8）判红：跳过的话它里面的链接一条都没查，而成功那句照报「都到得了」
    try:
        s = open(p, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError) as error:
        bad.append(f"{p} 读不了，里面的链接一条都没查：{error}")
        continue
    n_file += 1
    s = mask_code(s)
    for m in re.finditer(r'\[([^\]]*)\]\(([^)\s]+)\)', s):
        tgt = m.group(2)
        if tgt.startswith(('http://', 'https://', 'mailto:', '#')):
            continue
        path = tgt.partition('#')[0]
        if not path:
            continue
        n_link += 1
        full = os.path.normpath(os.path.join(base, path))
        if not os.path.exists(full):
            ln = s[:m.start()].count('\n') + 1
            bad.append(f"{p}:{ln} 链接 [{m.group(1)[:24]}]({tgt}) 指到 {full}，那里没有东西")
    # 「见 X.md 第 N 节」：目标文档到底有没有第 N 个 `##` 节
    for m in re.finditer(r'\[[^\]]*\]\(([^)\s]+\.md)\)[^，。；、\n]{0,8}第([一二三四五六七八九十0-9]+)节', s):
        n_sec += 1
        n = m.group(2)
        n = int(n) if n.isdigit() else CN.get(n, 0)
        full = os.path.normpath(os.path.join(base, m.group(1).partition('#')[0]))
        hs = heads(full)
        if hs is None:
            ln = s[:m.start()].count('\n') + 1
            bad.append(f"{p}:{ln} 指「{m.group(1)} 第{m.group(2)}节」，而那个文档读不出来（不存在、读不了或不是 UTF-8），数不了它有几节")
        elif not (0 < n <= len(hs)):
            ln = s[:m.start()].count('\n') + 1
            bad.append(f"{p}:{ln} 指「{m.group(1)} 第{m.group(2)}节」，而那个文档只有 {len(hs)} 个 ## 节")

if bad:
    print(f"  ✗ 文档指向失效 {len(bad)} 处")
    for b in bad[:40]:
        print("    ", b)
    print("     → 相对路径按**该文件所在目录**算，不是按仓库根算；「第 N 节」改成指小节标题。"
          "读不了的那几份：修好权限或编码（要 UTF-8），坏掉的符号链接删掉或指回去。")
    sys.exit(1)
print(f"  ✓ 文档指向都到得了（{n_file} 份文档、{n_link} 条相对链接、{n_sec} 处「第 N 节」指向）")
