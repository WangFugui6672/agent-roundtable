.PHONY: help db-up db-down docker-up docker-down docker-smoke docker-purge \
	backend-install backend-migrate backend-purge backend-run backend-test \
	backend-lint backend-check ios-project ios-build ios-app-build ios-test \
	ios-lint ios-app-test ios-ui-test record-demo scripts-test secret-scan \
	android-core-purity android-lint android-test verify release-check

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "%-20s %s\n", $$1, $$2}'

db-up: ## 启动本地 PostgreSQL
	docker compose up -d db

db-down: ## 停止本地 PostgreSQL
	docker compose stop db

docker-up: ## 构建并启动后端（PostgreSQL + Redis + Daphne + Celery）
	docker compose up --build --detach --wait

docker-down: ## 停止完整后端并保留数据卷
	docker compose down

docker-smoke: ## 用隔离项目从零启动 Compose 并验证健康/Redis/Celery
	./scripts/verify_compose.sh

docker-purge: ## 在 Compose 数据库中执行 90 天保留清理
	docker compose --profile ops run --rm purge

backend-install: ## 安装后端依赖
	cd backend && uv sync

backend-migrate: ## 执行数据库迁移
	cd backend && uv run python manage.py migrate

backend-purge: ## 删除最后活动超过 90 天的圆桌数据
	cd backend && uv run python manage.py purge_roundtables

backend-run: ## 启动单进程开发服务器（HTTP + WebSocket，0.0.0.0:8000）
	cd backend && DJANGO_DEBUG=1 uv run daphne -b 0.0.0.0 -p 8000 roundtable.asgi:application

backend-test: ## 运行后端测试
	cd backend && uv run pytest

backend-lint: ## 后端 Ruff 与格式检查
	cd backend && uv run ruff check . && uv run ruff format --check .

backend-check: ## 后端 lint、格式、Django、迁移与全量测试
	cd backend && uv run ruff check .
	cd backend && uv run ruff format --check .
	cd backend && uv run python manage.py check
	cd backend && uv run python manage.py makemigrations --check --dry-run
	cd backend && uv run pytest -q

ios-project: ## 生成 Xcode 工程（需要 xcodegen）
	cd ios && xcodegen generate

ios-build: ## 编译 RoundtableCore（Command Line Tools 即可）
	cd ios/RoundtableCore && swift build

ios-app-build: ios-project ## 在可用 iPhone 模拟器上编译 App 与测试包
	@SIMULATOR_ID="$${SIMULATOR_ID:-$$(python3 scripts/select_simulator.py)}"; \
		cd ios && xcodebuild \
			-project AgentRoundtable.xcodeproj \
			-scheme AgentRoundtable \
			-destination "platform=iOS Simulator,id=$$SIMULATOR_ID" \
			build-for-testing

ios-test: ## 运行 RoundtableCore 测试
	cd ios/RoundtableCore && swift test

ios-lint: ## SwiftLint 严格检查
	cd ios && swiftlint lint --strict

ios-app-test: ios-project ## 运行 App 单元测试（自动选择可用 iPhone 模拟器）
	@SIMULATOR_ID="$${SIMULATOR_ID:-$$(python3 scripts/select_simulator.py)}"; \
		cd ios && xcodebuild \
			-project AgentRoundtable.xcodeproj \
			-scheme AgentRoundtable \
			-destination "platform=iOS Simulator,id=$$SIMULATOR_ID" \
			-only-testing:AgentRoundtableTests \
			-collect-test-diagnostics never \
			test

ios-ui-test: ios-project ## 运行完整 UI 回归（需 localhost:8000 后端）
	@curl --fail --silent http://127.0.0.1:8000/api/v1/health >/dev/null || \
		(echo "请先运行 make docker-up 或 make backend-run"; exit 1)
	@SIMULATOR_ID="$${SIMULATOR_ID:-$$(python3 scripts/select_simulator.py)}"; \
		cd ios && xcodebuild \
			-project AgentRoundtable.xcodeproj \
			-scheme AgentRoundtable \
			-destination "platform=iOS Simulator,id=$$SIMULATOR_ID" \
			-only-testing:AgentRoundtableUITests \
			-parallel-testing-enabled NO \
			-collect-test-diagnostics never \
			test

record-demo: ios-project ## 录制完整 UI 演示到 docs/assets/demo-v0.1.0.mp4
	./scripts/record_demo.sh

scripts-test: ## 测试发布脚本中的模拟器选择等纯逻辑
	python3 -m unittest discover -s scripts -p 'test_*.py'

secret-scan: scripts-test ## 扫描密钥、.env、生成工程和构建产物
	python3 scripts/secret_scan.py

android-core-purity: ## :core 不得引用 android.* 或 androidx.*
	@if grep -rnE '^import (android|androidx)\.' android/core/src; then \
		echo ':core 必须保持纯 JVM 语义，不得引用 android.* 或 androidx.*' >&2; exit 1; \
	fi

android-lint: ## Android Lint（:core 与 :app 的 debug 变体）
	cd android && ./gradlew :core:lintDebug :app:lintDebug

android-test: ## Android 纯 JVM 单测、应用单测与调试包编译
	cd android && ./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug

verify: backend-lint backend-test ios-build ios-lint android-core-purity android-lint android-test ## 提交前最小验证

release-check: backend-check ios-test ios-lint ios-app-test secret-scan docker-smoke ## 发布静态/后端/App/Compose 门禁
