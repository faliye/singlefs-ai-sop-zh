#!/usr/bin/env python3
"""本包的 family 名、它装进项目后的副本目录、本包的语言与一份文件按后缀算的语言：只在这一处算。

family 读本包自己的 I18N（`family=` 那一行），不从项目里猜路径去找；install.sh 把副本装在项目的 `.claude/<family>/` 下。
I18N 读不到时取本包目录的真实名字：装进项目的副本，目录名就是 family。

不单独跑，由别的脚本按路径载入（preflight.py 的 load_package_module），函数照原名调。
"""
import os
import sys

# 不写 __pycache__：避免门禁跑的过程中生成未跟踪文件
sys.dont_write_bytecode = True

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def package_family():
    try:
        with open(os.path.join(PACKAGE_ROOT, 'I18N'), encoding='utf-8') as i18n_file:
            for line in i18n_file:
                if line.startswith('family='):
                    family = line.split('=', 1)[1].strip()
                    if family:
                        return family
    except OSError:
        pass
    return os.path.basename(PACKAGE_ROOT)


def package_language():
    """本包的语言：I18N 的 `this=` 那一行，读不到按 zh。"""
    try:
        with open(os.path.join(PACKAGE_ROOT, 'I18N'), encoding='utf-8') as i18n_file:
            for line in i18n_file:
                if line.startswith('this='):
                    language = line.split('=', 1)[1].strip()
                    if language:
                        return language
    except OSError:
        pass
    return 'zh'


LANGUAGE_BY_SUFFIX = {'.zh.md': 'zh', '.en.md': 'en', '.ja.md': 'ja'}


def file_language(path):
    """一份文件的语言：按语言后缀认，不带后缀的算本包的语言。编号的登记位与引用按它分组（doc-lint.sh 的 kb_file_language 同一个判法）。"""
    for suffix, language in LANGUAGE_BY_SUFFIX.items():
        if path.endswith(suffix):
            return language
    return package_language()


def installed_package_directory():
    """副本在项目里的位置，相对项目根、带结尾斜杠。"""
    return '.claude/' + package_family() + '/'
