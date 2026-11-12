.PHONY: help probe preflight fetch spec rpmbuild verify build test-install vm-test report all clean docker-build bootstrap shell

QGIS_BUILD_JOBS ?= 4
KYLIN_BASE_IMAGE ?= $(shell grep -E '^KYLIN_BASE_IMAGE=' config/kylin.confirmed.env 2>/dev/null | tail -n1 | cut -d= -f2-)

help:
	@echo "QGIS 3.34.12 / Kylin V10 (Halberd) / Hygon C86-3G 云端构建"
	@echo ""
	@echo "  make probe        在真实麒麟容器中探测依赖矩阵（生成 config/*.confirmed.env）"
	@echo "  make preflight    参数门禁（未确认参数一律拒绝）"
	@echo "  make fetch        拉取并校验官方 tag final-3_34_12 (3.34.12)"
	@echo "  make spec         渲染 packaging/qgis-kylin.spec"
	@echo "  make rpmbuild     全量编译 + rpmbuild 打原生 RPM"
	@echo "  make verify       RPM 静态校验（元数据/3D/PyQGIS/ldd/ISA/GLIBC）"
	@echo "  make build        以上一键（容器内）"
	@echo "  make test-install 全新麒麟容器安装 + 启动 + 离屏渲染 (STAGE_B2)"
	@echo "  make vm-test      QEMU/KVM 目标系统验证 (STAGE_C)"
	@echo "  make report       汇总分层验证报告"
	@echo "  make docker-build 构建麒麟原生编译镜像"
	@echo "  make bootstrap    从官方 ISO 生成基础镜像 rootfs（兜底）"
	@echo "  make clean        清理构建中间产物"
	@echo ""
	@echo "先读 docs/CONFIRM.md 与 docs/STAGES.md。"

probe:
	python3 scripts/probe-kylin.py --write

preflight:
	PREFLIGHT_ONLINE=1 bash scripts/00-preflight.sh --ci

fetch:
	bash scripts/10-fetch-source.sh

spec:
	bash scripts/20-render-spec.sh

rpmbuild:
	bash scripts/30-rpmbuild.sh

verify:
	bash scripts/40-verify-rpm.sh

build:
	bash scripts/build-all.sh

test-install:
	bash scripts/50-test-install.sh

vm-test:
	bash scripts/60-test-qemu-vm.sh

report:
	bash scripts/70-collect-evidence.sh

all: build test-install vm-test report

docker-build:
	docker build --progress=plain \
	  --build-arg "KYLIN_BASE_IMAGE=$(KYLIN_BASE_IMAGE)" \
	  --build-arg "QGIS_BUILD_JOBS=$(QGIS_BUILD_JOBS)" \
	  -f docker/Dockerfile.kylin -t qgis-kylin-builder:3.34.12 .

bootstrap:
	bash scripts/bootstrap/10-make-rootfs.sh

shell:
	docker run --rm -it -v "$(PWD):/work" -w /work qgis-kylin-builder:3.34.12 shell

clean:
	rm -rf work out reports/logs packaging/qgis-kylin.spec
	mkdir -p work out reports/logs
