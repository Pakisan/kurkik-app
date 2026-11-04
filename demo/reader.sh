#!/usr/bin/env bash
# Keeps a consumer in group analytics reading orders.created on prod, until stopped with Ctrl-C - so a sync that would
# destroy orders.created has somebody connected to name. The groups seed.sh leaves have read, committed and gone.
#
#   demo/reader.sh &
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec docker compose -f "$here/docker-compose.yml" exec -T kafka-prod /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:29092 --topic orders.created --group analytics > /dev/null 2>&1
