#!/usr/bin/env python3
"""本包的 family 名与它装进项目后的副本目录：只在这一处算。

family 读本包自己的 I18N（`family=` 那一行），不从项目里猜路径去找；install.sh 把副本装在项目的 `.claude/<family>/` 下。
I18N 读不到时取本包目录的真实名字：装进项目的副本，目录名就是 family。

不单独跑，由别的脚本按路径载入（preflight.py 的 load_package_module），函数照原名调。
"""
import os

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def package_family():
    try:
        with open(os.path.join(PACKAGE_ROOT, 'I18N'), encoding='utf-8') as handle:
            for line in handle:
                if line.startswith('family='):
                    family = line.split('=', 1)[1].strip()
                    if family:
                        return family
    except OSError:
        pass
    return os.path.basename(PACKAGE_ROOT)


def installed_package_directory():
    """副本在项目里的位置，相对项目根、带结尾斜杠。"""
    return '.claude/' + package_family() + '/'
