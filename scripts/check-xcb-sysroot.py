#!/usr/bin/env python3
"""盘点 Qt xcb QPA 所需的 sysroot 依赖，缺关键件时立刻失败。

Qt 5.15.2 的 xcb feature 需要 libs.xkbcommon、libs.xkbcommon_x11、
libs.xcb_icccm 以及 tests.xcb_syslibs 用到的一整套 xcb 扩展。这些包由
20-build-deps.sh 的 D0 只下载解压到 sysroot，不会装进系统；若某件缺失，
Qt configure 会静默禁用 xcb，等 2~4 小时编译结束才发现桌面 GUI 起不来。
本脚本在重编 Qt 之前完成盘点并产出 xcb-sysroot.json。

用法: check-xcb-sysroot.py <sysroot> <report_dir>
退出码: 0 = 关键件齐备, 1 = 缺关键件
"""
import glob
import json
import os
import subprocess
import sys

sysroot, rep = sys.argv[1:3]
inc = os.path.join(sysroot, 'usr', 'include')
lib = os.path.join(sysroot, 'usr', 'lib64')

PCS = ['xcb', 'xcb-icccm', 'xcb-util', 'xcb-image', 'xcb-keysyms',
       'xcb-randr', 'xcb-render', 'xcb-renderutil', 'xcb-shape', 'xcb-shm',
       'xcb-sync', 'xcb-xfixes', 'xcb-xinerama', 'xcb-xkb',
       'xkbcommon', 'xkbcommon-x11', 'x11', 'x11-xcb']
HEADERS = ['xcb/xcb.h', 'xcb/xcb_icccm.h', 'xcb/xcb_util.h', 'xcb/xcb_image.h',
           'xcb/xcb_keysyms.h', 'xcb/randr.h', 'xcb/render.h',
           'xcb/xcb_renderutil.h', 'xcb/shape.h', 'xcb/shm.h', 'xcb/sync.h',
           'xcb/xfixes.h', 'xcb/xinerama.h', 'xcb/xkb.h',
           'xkbcommon/xkbcommon.h', 'xkbcommon/xkbcommon-x11.h', 'X11/Xlib.h']
LIB_GLOBS = ['libxcb.so*', 'libxcb-icccm.so*', 'libxcb-util.so*',
             'libxkbcommon.so*', 'libxkbcommon-x11.so*', 'libX11.so*']
REQUIRED = {
    'pc': ['xcb', 'xcb-icccm', 'xkbcommon', 'xkbcommon-x11'],
    'header': ['xcb/xcb_icccm.h', 'xkbcommon/xkbcommon.h',
               'xkbcommon/xkbcommon-x11.h'],
    'lib': ['libxkbcommon.so*', 'libxkbcommon-x11.so*', 'libxcb-icccm.so*'],
}


def pkg_version(pc):
    try:
        proc = subprocess.run(['pkg-config', '--modversion', pc],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=20)
        return proc.stdout.strip() if proc.returncode == 0 else None
    except Exception:
        return None


report = {'sysroot': sysroot, 'pkgconfig': {}, 'headers': {}, 'libs': {},
          'missing_required': [], 'missing_optional': []}
for pc in PCS:
    version = pkg_version(pc)
    report['pkgconfig'][pc] = version
    if version is None:
        key = 'missing_required' if pc in REQUIRED['pc'] else 'missing_optional'
        report[key].append('pc:' + pc)
for header in HEADERS:
    ok = os.path.isfile(os.path.join(inc, header))
    report['headers'][header] = ok
    if not ok:
        key = 'missing_required' if header in REQUIRED['header'] else 'missing_optional'
        report[key].append('header:' + header)
for pattern in LIB_GLOBS:
    found = sorted(os.path.basename(p)
                   for p in glob.glob(os.path.join(lib, pattern)))
    report['libs'][pattern] = found
    if not found:
        key = 'missing_required' if pattern in REQUIRED['lib'] else 'missing_optional'
        report[key].append('lib:' + pattern)

report['verdict'] = 'PASS' if not report['missing_required'] else 'FAIL'
with open(os.path.join(rep, 'xcb-sysroot.json'), 'w', encoding='utf-8') as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2)

print('xcb-sysroot: %s  pkgconfig=%d/%d headers=%d/%d libs=%d/%d' % (
    report['verdict'],
    sum(1 for v in report['pkgconfig'].values() if v), len(PCS),
    sum(1 for v in report['headers'].values() if v), len(HEADERS),
    sum(1 for v in report['libs'].values() if v), len(LIB_GLOBS)))
for item in report['missing_required'] + report['missing_optional']:
    print('  MISSING', item)
sys.exit(0 if report['verdict'] == 'PASS' else 1)
