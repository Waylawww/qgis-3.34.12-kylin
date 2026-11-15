#!/usr/bin/env python3
"""PyQGIS 离屏冒烟测试：不依赖 X / UKUI / GPU，验证 QGIS 能启动并渲染出地图。

检查项：
  1. qgis.core / qgis.gui / qgis.analysis 可导入，Qgis.QGIS_VERSION == 3.34.12
  2. 创建内存矢量面图层并写入 2 个要素
  3. QgsMapRendererParallelJob 离屏渲染成 PNG
  4. PNG 非空白（多种颜色 + 足够多非背景像素）
  5. qgis._3d 可导入（软检查；3D 库的硬检查在 SPEC/verify 阶段完成）
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QGIS_PREFIX_PATH", "/usr")
os.environ.pop("DISPLAY", None)

EXPECTED_VERSION = "3.34.12"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="渲染输出 PNG 路径")
    ap.add_argument("--json", required=True, help="结果 JSON 路径")
    args = ap.parse_args()

    checks: dict = {}
    result = {"test": "pyqgis_smoke", "expected_version": EXPECTED_VERSION,
              "checks": checks, "status": "FAIL"}
    try:
        from qgis.core import (
            Qgis, QgsApplication, QgsCoordinateReferenceSystem, QgsFeature,
            QgsFillSymbol, QgsGeometry, QgsMapRendererParallelJob, QgsMapSettings,
            QgsProject, QgsRectangle, QgsVectorLayer,
        )
        from qgis.PyQt.QtCore import QSize
        from qgis.PyQt.QtGui import QColor, QImage

        checks["import_qgis_core"] = "PASS"
        version = Qgis.QGIS_VERSION
        # 3.34 的 Qgis.QGIS_VERSION 带发行代号（如 "3.34.12-Prizren"），
        # 不能用严格相等与主版本号比较。
        checks["qgis_version"] = "PASS" if version.startswith(EXPECTED_VERSION) else \
            f"FAIL: got {version}"
        result["qgis_version"] = version

        app = QgsApplication([], False)
        QgsApplication.setPrefixPath(os.environ.get("QGIS_PREFIX_PATH", "/usr"), True)
        app.initQgis()
        checks["initQgis"] = "PASS"

        import importlib
        for mod in ("qgis.gui", "qgis.analysis"):
            importlib.import_module(mod)
            checks["import_" + mod.replace(".", "_")] = "PASS"
        try:
            importlib.import_module("qgis._3d")
            checks["import_qgis_3d"] = "PASS"
        except Exception as exc:  # 3D 的 C++ 库由 SPEC 硬校验，这里只作提示
            checks["import_qgis_3d"] = "WARN: " + str(exc)

        layer = QgsVectorLayer(
            "Polygon?crs=EPSG:4326&field=name:string(20)", "ci_demo", "memory")
        if not layer.isValid():
            raise RuntimeError("内存图层创建失败")
        feats = []
        for name, wkt in (
            ("alpha", "POLYGON((0 0, 5 0, 5 5, 0 5, 0 0))"),
            ("beta", "POLYGON((6 1, 10 1, 10 9, 6 9, 6 1))"),
        ):
            f = QgsFeature(layer.fields())
            f.setAttributes([name])
            f.setGeometry(QgsGeometry.fromWkt(wkt))
            feats.append(f)
        ok, _ = layer.dataProvider().addFeatures(feats)
        if not ok or layer.featureCount() != 2:
            raise RuntimeError(f"要素写入失败 featureCount={layer.featureCount()}")
        layer.updateExtents()
        layer.renderer().setSymbol(QgsFillSymbol.createSimple({
            "color": "#2b8cbe", "outline_color": "#08306b", "outline_width": "0.8",
        }))
        QgsProject.instance().addMapLayer(layer)
        checks["vector_layer"] = f"PASS ({layer.featureCount()} features)"

        crs = QgsCoordinateReferenceSystem("EPSG:4326")
        settings = QgsMapSettings()
        settings.setLayers([layer])
        settings.setDestinationCrs(crs)
        settings.setExtent(QgsRectangle(-1, -1, 11, 11))
        settings.setOutputSize(QSize(800, 600))
        settings.setOutputDpi(96)
        settings.setBackgroundColor(QColor(255, 255, 255))

        job = QgsMapRendererParallelJob(settings)
        job.start()
        job.waitForFinished()
        image = job.renderedImage()
        if image.isNull():
            raise RuntimeError("renderedImage() 为空")
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        if not image.save(args.out, "PNG"):
            raise RuntimeError("PNG 保存失败")
        checks["render_png"] = "PASS"

        # 非空白判定：采样 40x30 网格，要求至少 3 种颜色且非白像素 > 2%
        loaded = QImage(args.out)
        colors, non_white, total = set(), 0, 0
        for iy in range(30):
            for ix in range(40):
                c = loaded.pixelColor(int(loaded.width() * ix / 40),
                                     int(loaded.height() * iy / 30))
                rgb = c.rgb()
                colors.add(rgb)
                total += 1
                if (rgb & 0xFFFFFF) != 0xFFFFFF:
                    non_white += 1
        ratio = non_white / max(total, 1)
        result["render"] = {"width": loaded.width(), "height": loaded.height(),
                            "distinct_colors": len(colors),
                            "non_white_ratio": round(ratio, 4)}
        checks["non_blank_image"] = "PASS" if len(colors) >= 3 and ratio > 0.02 else \
            f"FAIL: colors={len(colors)} non_white_ratio={ratio:.4f}"

        app.exitQgis()

        failed = [k for k, v in checks.items() if isinstance(v, str) and v.startswith("FAIL")]
        result["status"] = "FAIL" if failed else "PASS"
        result["failed_checks"] = failed
    except Exception as exc:
        result["error"] = str(exc)
        result["traceback"] = traceback.format_exc()

    os.makedirs(os.path.dirname(os.path.abspath(args.json)) or ".", exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
