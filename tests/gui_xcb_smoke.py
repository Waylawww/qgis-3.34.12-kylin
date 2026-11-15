#!/usr/bin/env python3
"""QGIS Kylin V10 真机 GUI(xcb) 平台验收。

``mode=gui``    在真实 X11 显示（CI 上由 Xvfb 提供）下创建 QApplication +
                QMainWindow，确认 platformName() == "xcb" 并保存窗口截图。
                这是桌面 GUI 能否启动的直接证据，而不只是插件文件存在。
``mode=probe``  目标机没有 X server 时的兜底：用 QT_DEBUG_PLUGINS=1 启动一次
                QApplication，从 Qt 插件加载日志证明 libqxcb.so 确实被找到并
                加载。"could not connect to display" 是预期失败（插件已加载），
                而 "Could not find the Qt platform plugin" 才是缺失。
"""
import argparse
import json
import os
import subprocess
import sys
import traceback


def probe_mode():
    code = ("from PyQt5.QtWidgets import QApplication\n"
            "import sys\n"
            "app = QApplication(sys.argv)\n")
    env = os.environ.copy()
    env['QT_QPA_PLATFORM'] = 'xcb'
    env['QT_DEBUG_PLUGINS'] = '1'
    env.pop('DISPLAY', None)
    try:
        proc = subprocess.run(
            [sys.executable, '-c', code], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            universal_newlines=True, timeout=90)
        out = proc.stdout or ''
        returncode = proc.returncode
    except Exception as exc:
        return {'status': 'FAIL', 'error': repr(exc),
                'reason': 'probe subprocess failed'}, ''

    lowered = out.lower()
    missing = ('could not find the qt platform plugin' in lowered
               or 'no qt platform plugin could be initialized' in lowered)
    loaded = ('libqxcb.so' in lowered or 'qt.qpa.xcb' in lowered
              or 'could not connect to display' in lowered)
    detail = {
        'probe_returncode': returncode,
        'plugin_loaded': loaded,
        'plugin_missing': missing,
        'status': 'PASS' if (loaded and not missing) else 'FAIL',
    }
    return detail, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', choices=('gui', 'probe'), default='gui')
    ap.add_argument('--json', required=True)
    ap.add_argument('--shot')
    args = ap.parse_args()

    report = {
        'mode': args.mode,
        'qt_qpa_platform': 'xcb',
        'has_display': bool(os.environ.get('DISPLAY')),
        'checks': {},
        'status': 'FAIL',
    }
    probe_log = ''
    try:
        if args.mode == 'probe':
            detail, probe_log = probe_mode()
            report['probe'] = detail
            report['status'] = detail['status']
        else:
            if not os.environ.get('DISPLAY'):
                raise RuntimeError('mode=gui 需要 DISPLAY（CI 上请用 Xvfb 提供 X11 显示）')
            from PyQt5 import QtCore
            from PyQt5.QtGui import QGuiApplication
            from PyQt5.QtWidgets import QApplication, QLabel, QMainWindow

            app = QApplication(sys.argv)
            report['checks']['qapplication'] = 'PASS'
            report['qt_version'] = QtCore.QT_VERSION_STR
            platform = QGuiApplication.platformName()
            report['platform_name'] = platform
            report['checks']['platform_is_xcb'] = (
                'PASS' if platform == 'xcb' else 'FAIL: %s' % platform)

            window = QMainWindow()
            window.setWindowTitle('QGIS Kylin V10 xcb GUI selftest')
            window.resize(640, 480)
            window.setCentralWidget(QLabel('QGIS xcb platform plugin OK'))
            window.show()
            app.processEvents()
            report['checks']['window_visible'] = (
                'PASS' if window.isVisible() else 'FAIL')
            if args.shot:
                saved = window.grab().save(args.shot)
                report['checks']['screenshot'] = 'PASS' if saved else 'FAIL'
            window.close()
            app.quit()
            report['status'] = (
                'PASS' if all(v == 'PASS' for v in report['checks'].values())
                else 'FAIL')
    except Exception as exc:
        report['error'] = repr(exc)
        report['traceback'] = traceback.format_exc()

    if probe_log:
        report['probe_log_tail'] = probe_log.strip().splitlines()[-40:]
        with open(args.json + '.probe.log', 'w', encoding='utf-8') as handle:
            handle.write(probe_log)
    with open(args.json, 'w', encoding='utf-8') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
