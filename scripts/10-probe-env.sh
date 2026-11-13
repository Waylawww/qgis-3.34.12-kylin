#!/usr/bin/env bash
# 阶段 0b：在真实银河麒麟 V10 主机上采集环境事实（工具链 / 头文件 / 库 /
# pkg-config / 运行时版本 / 软件源可用版本 / 下载端点连通性）。
# 只读、不安装、不改系统；结果同时写入 reports 与 REPORT_DIR。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

python3 - "$REPORT_DIR" "$REPO_ROOT" <<'PY'
import concurrent.futures
import json
import os
import platform
import re
import shutil
import subprocess
import sys

report_dir, repo_root = sys.argv[1:3]
os.makedirs(report_dir, exist_ok=True)


def run(cmd, timeout=25):
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                           text=True, timeout=timeout)
        return (p.stdout + p.stderr).strip(), p.returncode
    except Exception as exc:
        return '%s: %s' % (type(exc).__name__, exc), -1


def first_line(text):
    lines = [x.strip() for x in text.splitlines() if x.strip()]
    return lines[0] if lines else ''


os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1)
            os_release[k] = v.strip().strip('"')

tools = {}
for name in ('git', 'cmake', 'ninja', 'make', 'gcc', 'g++', 'python3', 'pip3',
             'rpm', 'rpmbuild', 'rpm2cpio', 'cpio', 'flex', 'bison', 'bzip2',
             'xz', 'tar', 'curl', 'wget', 'pkg-config', 'sha256sum', 'tee',
             'qmake', 'qmake-qt5', 'sip', 'patchelf', 'ldd', 'ldconfig',
             'gdal-config', 'geos-config', 'proj', 'sqlite3', 'swig'):
    path = shutil.which(name)
    version = ''
    if path:
        for flag in ('--version', '-v', 'version'):
            out, rc = run([path, flag], timeout=8)
            if rc == 0 and out:
                version = first_line(out)
                break
    tools[name] = {'path': path, 'version': version[:180]}

pkgconfig = {}
for mod in ('Qt5Core', 'Qt5Gui', 'Qt5Widgets', 'Qt5Network', 'Qt5Svg', 'Qt5Xml',
            'Qt5Concurrent', 'Qt5Sql', 'Qt5PrintSupport', 'Qt5Positioning',
            'Qt5SerialPort', 'Qt5WebKitWidgets', 'Qt5Test', 'Qt5UiTools',
            'proj', 'geos', 'gdal', 'sqlite3', 'spatialindex', 'libspatialite',
            'libzip', 'protobuf', 'gsl', 'qca2-qt5', 'Qt5Qwt6', 'qscintilla2',
            'qtkeychain', 'libpq', 'expat', 'libtiff-4', 'libcurl', 'freetype2',
            'fontconfig', 'xcb', 'xkbcommon', 'gl', 'libxml-2.0', 'libzstd'):
    out, rc = run(['pkg-config', '--modversion', mod], timeout=8)
    pkgconfig[mod] = out if rc == 0 else None

headers = {}
for h in ('/usr/include/proj.h', '/usr/include/geos_c.h',
          '/usr/include/gdal/gdal.h', '/usr/include/gdal.h',
          '/usr/include/qt5/QtCore/qglobal.h', '/usr/include/QtCore/qglobal.h',
          '/usr/include/qwt-qt5/qwt.h', '/usr/include/qwt/qwt.h',
          '/usr/include/QScintilla2/Qsci/qsciscintilla.h',
          '/usr/include/qt5/QtCA/qca.h', '/usr/include/qtkeychain/keychain.h',
          '/usr/include/spatialindex/SpatialIndex.h',
          '/usr/include/libspatialite/spatialite.h',
          '/usr/include/sip.h', '/usr/include/python3.7m/Python.h',
          '/usr/include/zip.h', '/usr/include/postgresql/libpq-fe.h'):
    headers[h] = os.path.exists(h)

py_info = {}
out, _ = run(['python3', '-c',
              'import sys,sysconfig;print(sys.version.split()[0]);'
              'print(sysconfig.get_paths()["purelib"]);'
              'print(sysconfig.get_config_var("EXT_SUFFIX") or "")'])
py_info['version_lines'] = out.splitlines()
for mod, code in (('PyQt5.QtCore', 'import PyQt5.QtCore as m;print(m.PYQT_VERSION_STR)'),
                  ('sip', 'import sip;print(sip.SIP_VERSION_STR)'),
                  ('numpy', 'import numpy;print(numpy.__version__)'),
                  ('osgeo', 'from osgeo import gdal;print(gdal.__version__)'),
                  ('qsci', 'from PyQt5 import Qsci;print("ok")'),
                  ('yaml', 'import yaml;print(yaml.__version__)')):
    out, rc = run(['python3', '-c', code], timeout=12)
    py_info[mod] = out if rc == 0 else None

ldconfig_out, _ = run(['ldconfig', '-p'], timeout=20)
interesting = re.compile(r'Qt5Core|libproj|libgeos|libgdal|libqca|libqwt|'
                         r'libqscintilla|libqtkeychain|libspatialindex|'
                         r'libspatialite|libzip|libprotobuf|libpq|libgsl|'
                         r'libsqlite3|libtiff|libcurl')
ldconfig = [ln.strip() for ln in ldconfig_out.splitlines() if interesting.search(ln)]

rpm_pkgs, _ = run(['rpm', '-qa'], timeout=30)
rpm_re = re.compile(r'(qt5|qt-|proj|geos|gdal|qca|qwt|qscintilla|keychain|'
                    r'spatialite|spatialindex|libzip|protobuf|gsl|sip|pyqt|'
                    r'postgresql|sqlite|flex|bison|gcc|cmake|ninja|rpm-build|'
                    'mesa|fontconfig|freetype|xcb|libtiff|libcurl|expat)', re.I)
rpm_list = sorted({ln.strip() for ln in rpm_pkgs.splitlines() if rpm_re.search(ln)})

repo_versions = {}
pm = shutil.which('dnf') or shutil.which('yum')
if pm:
    out, _ = run([pm, '-q', 'list', '--showduplicates',
                  'qt5-qtbase-devel', 'proj-devel', 'geos-devel', 'gdal-devel',
                  'qwt-qt5-devel', 'qca-qt5-devel', 'qtkeychain-qt5-devel',
                  'qscintilla-qt5-devel', 'libspatialindex-devel',
                  'libspatialite-devel', 'python3-pyqt5', 'python3-sip'], timeout=90)
    repo_versions['raw_tail'] = out.splitlines()[-60:]

urls = {
    'github_api': 'https://api.github.com',
    'github_archive': 'https://github.com/qgis/QGIS/archive/refs/tags/final-3_34_12.tar.gz',
    'codeload': 'https://codeload.github.com/qgis/QGIS/tar.gz/refs/tags/final-3_34_12',
    'raw_githubusercontent': 'https://raw.githubusercontent.com/qgis/QGIS/final-3_34_12/CMakeLists.txt',
    'qgis_org': 'https://download.qgis.org/downloads/qgis-3.34.12.tar.bz2',
    'qt_download': 'https://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz',
    'proj_download': 'https://download.osgeo.org/proj/proj-8.2.1.tar.gz',
    'geos_download': 'https://download.osgeo.org/geos/geos-3.10.3.tar.bz2',
    'gdal_download': 'https://download.osgeo.org/gdal/3.4.3/gdal-3.4.3.tar.gz',
    'pypi': 'https://pypi.org/simple/sip/',
    'ghproxy': 'https://ghproxy.net/https://raw.githubusercontent.com/qgis/QGIS/final-3_34_12/CMakeLists.txt',
}


def probe_url(item):
    key, url = item
    out, rc = run(['curl', '-sS', '-L', '--max-time', '15', '-r', '0-0',
                   '-o', os.devnull, '-w', '%{http_code}', url], timeout=22)
    return key, out.strip() if rc == 0 else 'ERR:' + first_line(out)[:100]


network = {}
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    for key, status in pool.map(probe_url, urls.items()):
        network[key] = status

mem = {}
for line in open('/proc/meminfo', encoding='utf-8', errors='replace'):
    if line.startswith(('MemTotal:', 'MemAvailable:', 'SwapTotal:')):
        k, v = line.split(':', 1)
        mem[k] = v.strip()

df_out, _ = run(['df', '-Pk', repo_root, os.environ.get('WORK_DIR', repo_root),
                 os.environ.get('DEPS_PREFIX', repo_root)], timeout=15)
cpu_out, _ = run(['lscpu'], timeout=15)
cpu = {k.strip(): v.strip() for k, v in
       (ln.split(':', 1) for ln in cpu_out.splitlines() if ':' in ln)
       if k.strip() in ('Architecture', 'Model name', 'CPU(s)', 'Vendor ID', 'Flags')}

data = {
    'os_release': os_release,
    'kernel': platform.release(),
    'glibc': first_line(run(['ldd', '--version'])[0]),
    'machine': platform.machine(),
    'user': run(['id', '-un'])[0],
    'uid': run(['id', '-u'])[0],
    'nproc': os.cpu_count(),
    'cpu': cpu,
    'memory': mem,
    'df': df_out.splitlines(),
    'tools': tools,
    'pkgconfig': pkgconfig,
    'headers_present': headers,
    'python': py_info,
    'ldconfig_matches': ldconfig[:80],
    'rpm_packages': rpm_list[:200],
    'repo_available_versions': repo_versions,
    'network_http_status': network,
}
with open(os.path.join(report_dir, 'probe-env.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
if os.path.isdir(os.path.join(repo_root, 'reports')):
    with open(os.path.join(repo_root, 'reports', 'probe-env.json'), 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

print('=== TARGET ENVIRONMENT FACTS ===')
print('os          :', os_release.get('PRETTY_NAME'), '| ID=', os_release.get('ID'))
print('kernel      :', data['kernel'], '| glibc:', data['glibc'])
print('cpu         :', cpu.get('Model name'), '| cpus:', data['nproc'])
print('user        :', data['user'], '| uid:', data['uid'])
print('memory      :', mem)
print('--- toolchain ---')
for k, v in tools.items():
    print('  %-14s %-7s %s' % (k, 'OK' if v['path'] else 'MISSING', v['version']))
print('--- pkg-config (None = unusable) ---')
for k, v in pkgconfig.items():
    print('  %-20s %s' % (k, v))
print('--- python ---')
for k, v in py_info.items():
    print('  %-20s %s' % (k, v))
print('--- installed rpms (filtered, %d) ---' % len(rpm_list))
for p in rpm_list[:60]:
    print('  ', p)
print('--- network (HTTP status / error) ---')
for k, v in network.items():
    print('  %-24s %s' % (k, v))
print('--- headers present ---')
for k, v in headers.items():
    print('  %-55s %s' % (k, v))
print('=== report written: probe-env.json ===')
PY
