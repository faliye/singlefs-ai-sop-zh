#!/usr/bin/env python3
# admission: always 判的是此刻工作区里的文件与这一次给的基准，上一次的结论不替这一次作保
# run-condition: command git
"""Rust 源文件的改动是不是只动了注释：去掉注释与空白之后，代码词元与基准那一版逐个相同。

用法：
    comment-only-change.py <项目根> <基准> <路径>…   # 逐个判，只改了注释的路径一行一个打到标准输出
    comment-only-change.py --selftest                 # 自证；弄坏开关见下

判法：
  - 基准那一版取 `git -C <项目根> show <基准>:<路径>`，此刻那一版读工作区里的文件；
    基准里没有（新文件）、工作区里没有（删掉的）、不是 .rs 的，都不算只改注释。
  - 词元：标识符与数字连成一个，标点一个字符一个，字符串、原始字符串、字节串、字符字面量整个算一个（里面的 // 与 /* 不是注释），
    生命周期的 ' 照标点算；行注释 // 到行尾、块注释 /* */（可嵌套）去掉；空白只分词，不算词元。
  - 文档注释（///、//!、/** */、/*! */）是给 rustdoc 的：里面的代码块会被编成 doctest 跑，所以代码块里的行
    （``` 围栏之间的，与围栏外缩进 4 格起的）要逐行相同；别的文档文字照注释算。
  - `#[doc = "…"]` 这类属性是代码，照词元比。
  - 注释在不在本身会改编译结果的两种照代码算：文档注释（开了 missing_docs 这类 lint 时，有没有决定编不编得过）与
    `// SAFETY:` 注释（clippy 的 undocumented_unsafe_blocks 按它判）。词元流里各记一个占位，增删、挪位置算改了代码，只改文字不算。
用途：门禁判「改了代码要带测试」「改了产品代码要走评审」时，把只改了注释的文件摘出去，逐个报出来。
退出码：0 判完（只改注释的一行一个打出来，一个没有就什么都不打）；2 用法错、项目根不是 git 仓；
  3 某个路径的基准那一版取不出来、而 git 报的不是「基准里没有这个文件」（原话打到标准错误），不打任何路径。
弄坏开关（只给 --selftest 证红用）：
  COMMENT_ONLY_CHANGE_BREAK=strings-as-comments  字符串字面量也当注释去掉；自证「改了字符串里的 //」那一格红
  COMMENT_ONLY_CHANGE_BREAK=doc-code-ignored     文档注释里的代码块不比；自证「改了文档注释里的 doctest」那一格红
  COMMENT_ONLY_CHANGE_BREAK=flat-block-comments  块注释不认嵌套（第一个 */ 就收）；自证「嵌套块注释里改字」那一格红
  COMMENT_ONLY_CHANGE_BREAK=lint-comments-ignored 不给文档注释与 SAFETY 注释记占位；自证「删了 SAFETY 注释」「删掉整段文档注释」两格红
"""
import os
import re
import subprocess
import sys
import tempfile
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

ENABLED_BREAK_SWITCH = os.environ.get('COMMENT_ONLY_CHANGE_BREAK', '')
RAW_STRING_START = re.compile(r'(?:b|c)?r(#*)"')
IDENTIFIER_CHARACTER = re.compile(r'[0-9A-Za-z_]')
CODE_FENCE = re.compile(r'^\s*```')
DOCUMENTATION_COMMENT_MARK = '\x00doc-comment'
SAFETY_COMMENT_MARK = '\x00safety-comment'
SAFETY_TAG = re.compile(r'^\s*SAFETY:')


def is_identifier_character(character):
    return bool(IDENTIFIER_CHARACTER.match(character)) or (not character.isascii() and character.isalnum())


def rust_code_tokens_and_documentation_code(text):
    """→ (代码词元的列表, 文档注释里代码块的行的列表)。"""
    tokens, word, documentation_comment_lines = [], [], []
    text_length = len(text)
    position = 0

    def flush_word():
        if word:
            tokens.append(''.join(word))
            word.clear()

    def mark_comment(comment_text, is_documentation_comment):
        """文档注释与 SAFETY 注释在词元流里记占位：在不在会改编译结果，只改文字不会。连着的几行文档注释只记一个。"""
        if ENABLED_BREAK_SWITCH == 'lint-comments-ignored':
            return
        if is_documentation_comment and not (tokens and tokens[-1] == DOCUMENTATION_COMMENT_MARK):
            tokens.append(DOCUMENTATION_COMMENT_MARK)
        if SAFETY_TAG.match(comment_text):
            tokens.append(SAFETY_COMMENT_MARK)

    while position < text_length:
        character = text[position]
        if text.startswith('//', position):
            end = text.find('\n', position)
            end = text_length if end < 0 else end
            line_comment = text[position:end]
            is_documentation_comment = (line_comment.startswith('///') and not line_comment.startswith('////')) or line_comment.startswith('//!')
            if is_documentation_comment:
                documentation_comment_lines.append(line_comment[3:])
            flush_word()
            mark_comment(line_comment[3:] if is_documentation_comment else line_comment[2:], is_documentation_comment)
            position = end
            continue
        if text.startswith('/*', position):
            nesting_depth, end = 1, position + 2
            while end < text_length and nesting_depth:
                if ENABLED_BREAK_SWITCH != 'flat-block-comments' and text.startswith('/*', end):
                    nesting_depth, end = nesting_depth + 1, end + 2
                elif text.startswith('*/', end):
                    nesting_depth, end = nesting_depth - 1, end + 2
                else:
                    end += 1
            block_comment = text[position:end]
            is_documentation_comment = (block_comment.startswith('/**') and not block_comment.startswith('/***') and block_comment != '/**/') or block_comment.startswith('/*!')
            if is_documentation_comment:
                documentation_comment_lines.extend(block_comment[3:-2].split('\n'))
            flush_word()
            mark_comment(block_comment[3:-2] if is_documentation_comment else block_comment[2:-2], is_documentation_comment)
            position = end
            continue
        raw_string_start = RAW_STRING_START.match(text, position)
        if raw_string_start and (position == 0 or not is_identifier_character(text[position - 1])):
            raw_string_closing = '"' + raw_string_start.group(1)
            end = text.find(raw_string_closing, raw_string_start.end())
            end = text_length if end < 0 else end + len(raw_string_closing)
            flush_word()
            if ENABLED_BREAK_SWITCH != 'strings-as-comments':
                tokens.append(text[position:end])
            position = end
            continue
        if character == '"':
            end = position + 1
            while end < text_length and text[end] != '"':
                end += 2 if text[end] == '\\' else 1
            end = min(end + 1, text_length)
            flush_word()
            if ENABLED_BREAK_SWITCH != 'strings-as-comments':
                tokens.append(text[position:end])
            position = end
            continue
        if character == "'":
            if position + 1 < text_length and text[position + 1] == '\\':
                end = text.find("'", position + 3)
                end = text_length if end < 0 else end + 1
                flush_word()
                tokens.append(text[position:end])
                position = end
                continue
            if position + 2 < text_length and text[position + 2] == "'":
                flush_word()
                tokens.append(text[position:position + 3])
                position += 3
                continue
            flush_word()
            tokens.append("'")
            position += 1
            continue
        if character.isspace():
            flush_word()
            position += 1
            continue
        if is_identifier_character(character):
            word.append(character)
        else:
            flush_word()
            tokens.append(character)
        position += 1
    flush_word()
    return tokens, documentation_code_lines(documentation_comment_lines)


def documentation_code_lines(documentation_comment_lines):
    """文档注释里会被当 doctest 编译的行：``` 围栏之间的，与围栏外去掉一个前导空格后缩进 4 格起的。"""
    if ENABLED_BREAK_SWITCH == 'doc-code-ignored':
        return []
    code_lines, inside_fence = [], False
    for line in documentation_comment_lines:
        if CODE_FENCE.match(line):
            inside_fence = not inside_fence
            code_lines.append(line.strip())
            continue
        line_without_leading_space = line[1:] if line.startswith(' ') else line
        if inside_fence or (line_without_leading_space.startswith('    ') and line_without_leading_space.strip()):
            code_lines.append(line.rstrip())
    return code_lines


def only_comments_changed(base_text, current_text):
    return rust_code_tokens_and_documentation_code(base_text) == rust_code_tokens_and_documentation_code(current_text)


def file_text_at_base_revision(project_root, base_revision, path):
    """→ (文本, None)；基准里没有这个文件 → (None, None)；git 报别的错 → (None, 原话)。"""
    git_show_result = subprocess.run(['git', '-C', project_root, 'show', f'{base_revision}:{path}'], capture_output=True)
    if git_show_result.returncode == 0:
        return git_show_result.stdout.decode('utf-8', errors='surrogateescape'), None
    git_error_message = git_show_result.stderr.decode('utf-8', errors='replace')
    if 'does not exist in' in git_error_message or 'exists on disk, but not in' in git_error_message or 'invalid object name' in git_error_message.lower():
        return None, None
    return None, git_error_message.strip()


def comment_only_paths(project_root, base_revision, paths):
    comment_only_paths_found = []
    for path in paths:
        if not path.endswith('.rs'):
            continue
        current_file_path = os.path.join(project_root, path)
        if not os.path.isfile(current_file_path):
            continue
        base_text, problem = file_text_at_base_revision(project_root, base_revision, path)
        if problem is not None:
            raise RuntimeError(f'取不出 {base_revision}:{path}：{problem}')
        if base_text is None:
            continue
        with open(current_file_path, encoding='utf-8', errors='surrogateescape') as handle:
            current_text = handle.read()
        if only_comments_changed(base_text, current_text):
            comment_only_paths_found.append(path)
    return comment_only_paths_found


def selftest():
    cases = [
        ('改了行注释', 'fn a() {\n    // 旧的说法\n    let x = 1;\n}\n', 'fn a() {\n    // 新的说法，长一点\n    let x = 1;\n}\n', True),
        ('只改空白与换行', 'fn a(){let x=1+2;}\n', 'fn a() {\n    let x = 1 + 2;\n}\n', True),
        ('嵌套块注释里改字', 'fn a() { /* 外 /* 里 */ 还在注释里 x */ let y = 2; }\n',
         'fn a() { /* 外 /* 里改了 */ 还在注释里 z */ let y = 2; }\n', True),
        ('改了字符串里的 //', 'fn a() { let s = "http://a"; }\n', 'fn a() { let s = "http://b"; }\n', False),
        ('改了原始字符串里的 /*', 'fn a() { let s = r#"/* x */"#; }\n', 'fn a() { let s = r#"/* y */"#; }\n', False),
        ('改了代码', 'fn a() { let x = 1; }\n', 'fn a() { let x = 2; }\n', False),
        ('字符字面量是引号后面跟注释', "fn a() { let q = '\"'; // 旧\n}\n", "fn a() { let q = '\"'; // 新\n}\n", True),
        ('生命周期后面的注释', "fn a<'x>(v: &'x u8) {} // 旧\n", "fn a<'x>(v: &'x u8) {} // 新的\n", True),
        ('改了文档注释的文字', '/// 旧说明\nfn a() {}\n', '/// 新说明，写清契约\nfn a() {}\n', True),
        ('改了文档注释里的 doctest', '/// ```\n/// assert_eq!(1, 1);\n/// ```\nfn a() {}\n',
         '/// ```\n/// assert_eq!(1, 2);\n/// ```\nfn a() {}\n', False),
        ('改了 #[doc] 属性', '#[doc = "旧"]\nfn a() {}\n', '#[doc = "新"]\nfn a() {}\n', False),
        ('改了 SAFETY 注释的文字', 'fn a(p: *const u8) -> u8 {\n    // SAFETY: 旧理由\n    unsafe { *p }\n}\n',
         'fn a(p: *const u8) -> u8 {\n    // SAFETY: 调用方保证 p 指向活的一个字节\n    unsafe { *p }\n}\n', True),
        ('删了 SAFETY 注释', 'fn a(p: *const u8) -> u8 {\n    // SAFETY: 调用方保证\n    unsafe { *p }\n}\n',
         'fn a(p: *const u8) -> u8 {\n    // 调用方保证\n    unsafe { *p }\n}\n', False),
        ('删掉整段文档注释', '/// 返回 1\n/// 不会 panic\npub fn a() -> u32 { 1 }\n', '// 返回 1\npub fn a() -> u32 { 1 }\n', False),
    ]
    failures = []
    for case_name, before, after, expected_only_comments in cases:
        if only_comments_changed(before, after) != expected_only_comments:
            failures.append(f'{case_name}：应当判{"只改注释" if expected_only_comments else "改了代码"}，实际相反')
    with tempfile.TemporaryDirectory() as scratch_repository:
        def run_git_in_scratch_repository(*arguments):
            subprocess.run(['git', '-C', scratch_repository, *arguments], check=True, capture_output=True)
        run_git_in_scratch_repository('init', '-q')
        run_git_in_scratch_repository('config', 'user.email', 'selftest@example.invalid')
        run_git_in_scratch_repository('config', 'user.name', 'selftest')
        os.makedirs(os.path.join(scratch_repository, 'crates/sample/src'))
        file_contents_before_and_after = {'crates/sample/src/comment.rs': ('// a\nfn f() {}\n', '// b\nfn f() {}\n'),
                 'crates/sample/src/code.rs': ('fn f() { 1; }\n', 'fn f() { 2; }\n'),
                 'crates/sample/src/gone.rs': ('fn f() {}\n', None)}
        for path, (before, _) in file_contents_before_and_after.items():
            with open(os.path.join(scratch_repository, path), 'w', encoding='utf-8') as handle:
                handle.write(before)
        run_git_in_scratch_repository('add', '-A')
        run_git_in_scratch_repository('commit', '-q', '-m', 'base')
        for path, (_, after) in file_contents_before_and_after.items():
            if after is None:
                os.remove(os.path.join(scratch_repository, path))
            else:
                with open(os.path.join(scratch_repository, path), 'w', encoding='utf-8') as handle:
                    handle.write(after)
        with open(os.path.join(scratch_repository, 'crates/sample/src/new.rs'), 'w', encoding='utf-8') as handle:
            handle.write('// 新文件\nfn f() {}\n')
        paths_asked = ['crates/sample/src/comment.rs', 'crates/sample/src/code.rs', 'crates/sample/src/gone.rs', 'crates/sample/src/new.rs', 'README.md']
        paths_reported = comment_only_paths(scratch_repository, 'HEAD', paths_asked)
        if paths_reported != ['crates/sample/src/comment.rs']:
            failures.append(f'git 那一格：只该报 crates/sample/src/comment.rs（新文件、删掉的、改了代码的、不是 .rs 的都不报），实际 {paths_reported}')
    if failures:
        for failure in failures:
            print(f'  ✗ comment-only-change 自证：{failure}')  # gate-lint:detail
        print(f'  ✗ comment-only-change 自证有 {len(failures)} 格判错（共 {len(cases) + 1} 格）')
        print('    → 怎么办：看 rust_code_tokens_and_documentation_code() 与 comment_only_paths()；COMMENT_ONLY_CHANGE_BREAK 设着的话这里本来就该红')
        return 1
    print(f'  ✓ comment-only-change 自证通过：{len(cases) + 1} 格都对（行注释、空白、嵌套块注释、字符串与原始字符串、字符字面量、生命周期、文档文字、doctest、#[doc]、SAFETY 注释、文档注释的有无、git 取基准）')
    return 0


def main(arguments):
    if arguments == ['--selftest']:
        return selftest()
    if len(arguments) < 2:
        print('  ✗ 用法：comment-only-change.py <项目根> <基准> <路径>…', file=sys.stderr)
        print('    → 怎么办：照文件头的用法给项目根、基准（提交号或树）与要判的路径', file=sys.stderr)
        return 2
    project_root, base_revision, paths = arguments[0], arguments[1], arguments[2:]
    if subprocess.run(['git', '-C', project_root, 'rev-parse', '--git-dir'], capture_output=True).returncode != 0:
        print(f'  ✗ {project_root} 不是 git 仓，取不出基准那一版', file=sys.stderr)
        print('    → 怎么办：给 git 工作树的根', file=sys.stderr)
        return 2
    try:
        comment_only_paths_found = comment_only_paths(project_root, base_revision, paths)
    except RuntimeError as problem:
        print(f'  ✗ {problem}', file=sys.stderr)
        print('    → 怎么办：核基准在不在（git rev-parse 它）、路径写对没有；判不了的不当只改注释', file=sys.stderr)
        return 3
    for path in comment_only_paths_found:
        print(path)
    return 0


if __name__ == '__main__':
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
