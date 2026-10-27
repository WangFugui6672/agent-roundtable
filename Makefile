.PHONY: help db-up db-down backend-install backend-migrate backend-purge backend-run backend-test backend-lint ios-project ios-build ios-test ios-lint ios-app-test verify

# 可用 `make ios-app-test SIMULATOR="iPhone 16"` 覆盖。
SIMULATOR ?= iPhone 17

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-18s %s\n", $$1, $$2}'

db-up: ## 启动本地 PostgreSQL
	docker compose up -d db

db-down: ## 停止本地 PostgreSQL
	docker compose down

backend-install: ## 安装后端依赖
	cd backend && uv sync

backend-migrate: ## 执行数据库迁移
	cd backend && uv run python manage.py migrate

backend-purge: ## 删除最后活动超过 90 天的圆桌数据
	cd backend && uv run python manage.py purge_roundtables

backend-run: ## 启动 Django 开发服务器（HTTP + WebSocket，监听 0.0.0.0:8000）
	cd backend && DJANGO_DEBUG=1 uv run python manage.py runserver 0.0.0.0:8000

backend-test: ## 运行后端测试
	cd backend && uv run pytest

backend-lint: ## 后端静态检查与格式检查
	cd backend && uv run ruff check . && uv run ruff format --check .

ios-project: ## 生成 Xcode 工程（需要 xcodegen）
	cd ios && xcodegen generate

ios-build: ## 编译 iOS 核心包（Command Line Tools 即可）
	cd ios/RoundtableCore && swift build

ios-test: ## 运行 iOS 核心逻辑测试（需要 Xcode 提供的 XCTest）
	cd ios/RoundtableCore && swift test

ios-lint: ## SwiftLint 检查（需要 brew install swiftlint）
	cd ios && swiftlint lint --strict

ios-app-test: ios-project ## 在模拟器运行 App 单元测试（Keychain，需签名）
	cd ios && xcodebuild -project AgentRoundtable.xcodeproj -scheme AgentRoundtable \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-only-testing:AgentRoundtableTests test

verify: backend-lint backend-test ios-build ios-lint ## 本机可执行的最小验证
