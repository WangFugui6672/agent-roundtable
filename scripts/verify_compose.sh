#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="agent-roundtable-smoke-$$"
PORTS="$(python3 - <<'PY'
import socket

sockets = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sockets.append(sock)
print(" ".join(str(sock.getsockname()[1]) for sock in sockets))
PY
)"
read -r POSTGRES_PORT BACKEND_PORT <<< "$PORTS"
export POSTGRES_PORT BACKEND_PORT
SMOKE_BASE_URL="http://127.0.0.1:$BACKEND_PORT"

cleanup() {
  docker compose --project-name "$PROJECT_NAME" --project-directory "$ROOT" \
    down --volumes --remove-orphans
}
trap cleanup EXIT

cd "$ROOT"
docker compose --project-name "$PROJECT_NAME" up --build --detach --wait

python3 scripts/wait_for_http.py "$SMOKE_BASE_URL/api/v1/health" --timeout 90
curl --fail --silent --show-error --request POST \
  "$SMOKE_BASE_URL/api/v1/guest-sessions" \
  | python3 -c 'import json, sys, uuid; uuid.UUID(json.load(sys.stdin)["id"])'

docker compose --project-name "$PROJECT_NAME" exec --no-TTY redis redis-cli ping

TASK_ID="$(
  docker compose --project-name "$PROJECT_NAME" exec --no-TTY worker \
    celery -A roundtable call apps.roundtables.tasks.purge_expired_roundtables_task
)"
WORKER_COMPLETED=false
for _ in {1..20}; do
  if docker compose --project-name "$PROJECT_NAME" logs --no-color worker \
    | grep -q "purge_expired_roundtables_task.*succeeded"; then
    WORKER_COMPLETED=true
    break
  fi
  sleep 1
done
if [[ "$WORKER_COMPLETED" != true ]]; then
  docker compose --project-name "$PROJECT_NAME" logs worker
  echo "Celery task $TASK_ID did not complete." >&2
  exit 1
fi

docker compose --project-name "$PROJECT_NAME" exec --no-TTY backend python -c \
  "import os; os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'roundtable.settings'); from django.conf import settings; assert settings.CHANNEL_LAYERS['default']['BACKEND'] == 'channels_redis.core.RedisChannelLayer'; assert settings.CELERY_BEAT_SCHEDULE['purge-expired-roundtables']['task'] == 'apps.roundtables.tasks.purge_expired_roundtables_task'"

docker compose --project-name "$PROJECT_NAME" exec --no-TTY backend python - <<'PY'
import asyncio
import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "roundtable.settings")

from channels.layers import get_channel_layer  # noqa: E402


async def verify_idle_receive() -> None:
    layer = get_channel_layer()
    channel = await layer.new_channel()
    try:
        await asyncio.wait_for(layer.receive(channel), timeout=6)
    except TimeoutError:
        return
    raise RuntimeError("Unexpected message while verifying idle Redis channel.")


asyncio.run(verify_idle_receive())
PY

PURGE_OUTPUT="$(
  docker compose --project-name "$PROJECT_NAME" run --rm --no-deps purge \
    python manage.py purge_roundtables --dry-run
)"
grep -q "dry_run=true" <<<"$PURGE_OUTPUT"

echo "Compose smoke passed: migrations, Redis Channels, Celery worker/beat, idle receive, health, guest session, and retention purge."
