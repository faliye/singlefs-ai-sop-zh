#!/usr/bin/env python3
# gate-similar: doc-lint.sh 它按词表与形态判文档里的字句，不解析 ](相对路径) 链接，也不数「第 <数字> 节」指到哪；这一道在盘上解析链接目标、数目标文档的节
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: none 只读仓里的 markdown，不碰别的环境
"""文档里的相对链接与「第 <数字> 节」指向，指不指得到。

两类都会静默失效：
  相对链接：`[链接文字](../../CLAUDE.md)` —— 路径少一层就指到不存在的地方，或恰好指到另一个同名文件；
  节序号：「见 <文件名>.md 第三节」 —— 目标文档加一节、删一节，序号就指向别的东西了。

枚举文件用 os.walk，不用 glob('**/*.md')：后者默认不匹配点开头的目录，`.claude/` 下的文档全漏掉、照样报绿
（实测：报「0 处指不到」时正有一条坏链接）。
"""
import os, re, sys
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__：门禁跑到一半冒出一个未跟踪的目录，「工作区跑的过程中没变」就对不上
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight, project_gate_directory  # noqa: E402
preflight(__file__)

SKIPPED_DIRECTORY_NAMES = {'.git', 'node_modules', 'target'}
# `gate.d/fixtures/` 里的红样本故意放着坏链接；样本在临时目录里以那里为根判，本仓跳过它不影响自证。
def _excluded_directories():
    """从 .claude/doc-lint-exclude 读要绕开的目录（evidence-discipline.md「门禁也得绕开这批目录」）：
    原样保存的证据不许事后改，要求人去改原件的检查只会逼断证据链。
    """
    excluded_directories = []
    try:
        with open('.claude/doc-lint-exclude', encoding='utf-8') as exclude_file:
            for line in exclude_file:
                line = line.split('#')[0].strip()
                if line:
                    excluded_directories.append(line if line.endswith('/') else line + '/')
    except OSError:
        pass
    return tuple(excluded_directories)


PACKAGE_FAMILY = load_package_module('package_family', 'package-family.py')

# 装进项目的 SOP 副本不判：副本里的 templates/ 是给别的项目用的模板，相对路径按「拷到项目根之后」写，
# 在副本里当然指不到；副本也不许在项目里就地改（改共享规则只能改上游）。templates/ 在 SOP 仓自己里也跳过，理由相同。
# gate.sh 已经 cd 到项目根，project_gate_directory('.') 读的是这个项目登记的门禁目录（没登记就是默认值 .claude/gate.d）。
SKIPPED_PATH_PREFIXES = (PACKAGE_FAMILY.installed_package_directory(), project_gate_directory('.') + '/fixtures/',
                         'scripts/fixtures/', 'templates/') + _excluded_directories()
CHINESE_NUMERAL_VALUES = {'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10}

def markdown_files(root='.'):
    for directory_path, subdirectory_names, file_names in os.walk(root):
        subdirectory_names[:] = [subdirectory_name for subdirectory_name in subdirectory_names if subdirectory_name not in SKIPPED_DIRECTORY_NAMES]
        for file_name in file_names:
            if file_name.endswith('.md'):
                yield os.path.normpath(os.path.join(directory_path, file_name))

def mask_code_spans(text):
    """把代码块与行内代码涂成同长的空格，行号不变。

    反引号里的东西不是链接：`[本该](决策|实验)` 是一条正则，不涂就会报成坏链接（实测撞过，报的是 doc-lint 自己的规则串）。
    """
    def blank_out(code_match):
        return re.sub(r'[^\n]', ' ', code_match.group(0))
    text = re.sub(r'```.*?```', blank_out, text, flags=re.S)
    text = re.sub(r'`[^`\n]*`', blank_out, text)
    return text


def section_headings(path):
    """→ 这份文档的 ## 节标题；读不了（不存在、没权限、不是 UTF-8）返回 None，别让「读不出」装成「没有这一节」。"""
    try:
        return re.findall(r'^## (.+)$', open(path, encoding='utf-8').read(), re.M)
    except (OSError, UnicodeDecodeError):
        return None

problems = []
link_count = section_reference_count = file_count = 0
for document_path in sorted(markdown_files()):
    if document_path.startswith(SKIPPED_PATH_PREFIXES):
        continue
    document_directory = os.path.dirname(document_path) or '.'
    # 读不了的文档（坏掉的符号链接、没有读权限、不是 UTF-8）判红：跳过的话它里面的链接一条都没查，而成功那句照报「都到得了」
    try:
        text = open(document_path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError) as error:
        problems.append(f"{document_path} 读不了，里面的链接一条都没查：{error}")
        continue
    file_count += 1
    text = mask_code_spans(text)
    for link_match in re.finditer(r'\[([^\]]*)\]\(([^)\s]+)\)', text):
        link_target = link_match.group(2)
        if link_target.startswith(('http://', 'https://', 'mailto:', '#')):
            continue
        target_path = link_target.partition('#')[0]
        if not target_path:
            continue
        link_count += 1
        resolved_target = os.path.normpath(os.path.join(document_directory, target_path))
        if not os.path.exists(resolved_target):
            line_number = text[:link_match.start()].count('\n') + 1
            problems.append(f"{document_path}:{line_number} 链接 [{link_match.group(1)[:24]}]({link_target}) 指到 {resolved_target}，那里没有东西")
    # 「见 <文件名>.md 第 <数字> 节」：目标文档到底有没有那么多个 `##` 节
    for section_match in re.finditer(r'\[[^\]]*\]\(([^)\s]+\.md)\)[^，。；、\n]{0,8}第([一二三四五六七八九十0-9]+)节', text):
        section_reference_count += 1
        section_number_text = section_match.group(2)
        section_number = int(section_number_text) if section_number_text.isdigit() else CHINESE_NUMERAL_VALUES.get(section_number_text, 0)
        resolved_target = os.path.normpath(os.path.join(document_directory, section_match.group(1).partition('#')[0]))
        headings = section_headings(resolved_target)
        if headings is None:
            line_number = text[:section_match.start()].count('\n') + 1
            problems.append(f"{document_path}:{line_number} 指「{section_match.group(1)} 第{section_number_text}节」，而那个文档读不出来（不存在、读不了或不是 UTF-8），数不了它有几节")
        elif not (0 < section_number <= len(headings)):
            line_number = text[:section_match.start()].count('\n') + 1
            problems.append(f"{document_path}:{line_number} 指「{section_match.group(1)} 第{section_number_text}节」，而那个文档只有 {len(headings)} 个 ## 节")

if problems:
    print(f"  ✗ 文档指向失效 {len(problems)} 处")
    for problem in problems[:40]:
        print("    ", problem)
    print("     → 相对路径按**该文件所在目录**算，不是按仓库根算；「第 <数字> 节」改成指小节标题。"
          "读不了的那几份：修好权限或编码（要 UTF-8），坏掉的符号链接删掉或指回去。")
    sys.exit(1)
print(f"  ✓ 文档指向都到得了（{file_count} 份文档、{link_count} 条相对链接、{section_reference_count} 处「第 <数字> 节」指向）")
