#!/usr/bin/env bash
# Fills the demo's systems with an "orders" platform, staging and prod, which have drifted apart:
#
#   Kafka    prod has 12 partitions of orders.created where staging has 6, keeps orders.paid a day rather than a week,
#            has no payments.refunded, and has a shipments.dispatched staging has not; billing reads both, and
#            analytics reads prod only. Prod enforces ACLs and grants each service what it uses.
#   Registry prod's schema registry holds the orders' schemas, a customer's key and value, and a shared record.
#   Pulsar   staging (4.0) and prod (5.0) differ in shop/orders/paid's partitions and the namespace's message TTL, and
#            prod has a refunds topic and an audit subscription staging has not. Both grant billing and checkout what
#            they use, hold an Avro schema for shop/orders/created, and have 25 orders on it nobody has read yet.
#   SQS      prod's orders-queue hides messages for 60 s rather than 30, gives up after 3 receives rather than 5, and
#            prod has an audit-queue anyone may send to. Both encrypt orders-queue and orders-dlq with SQS's own keys
#            and orders-events.fifo with KMS, let SNS's orders topic send to orders-queue, let only orders-queue send
#            its dead letters to orders-dlq, and hold 3 orders waiting and 2 dead letters nobody has looked at.
#   SNS      prod has a shipments topic; staging's orders topic delivers raw, prod's does not. Both let EventBridge
#            publish to orders, filter its queue's deliveries on the body and redrive what fails to orders-dlq, and
#            have an encrypted orders.fifo topic feeding a FIFO queue.
#
# Safe to run again: what exists already is left as it is. Runs every client inside its own container, so nothing but
# Docker is needed here. A service that is not running is skipped, so a demo of one system needs only that one up:
#   docker compose -f demo/docker-compose.yml up -d --wait kafka-staging kafka-prod && demo/seed.sh
set -euo pipefail
cd "$(dirname "$0")"

compose() { docker compose -f docker-compose.yml "$@"; }

up() { compose ps --status running --services 2>/dev/null | grep -qx "$1"; }

# Runs the rest of the line when every service named before -- is running, and says so when one is not.
when() {
  local services=()
  while [ "$1" != "--" ]; do services+=("$1"); shift; done
  shift
  for service in "${services[@]}"; do
    if ! up "$service"; then echo "  skipped: $service is not running"; return 0; fi
  done
  "$@"
}

kafka() {
  local service=$1 port=$2; shift 2
  compose exec -T "$service" /opt/kafka/bin/"$@" --bootstrap-server "localhost:$port"
}

topic() {
  local service=$1 port=$2 name=$3 partitions=$4; shift 4
  kafka "$service" "$port" kafka-topics.sh --create --if-not-exists --topic "$name" --partitions "$partitions" --replication-factor 1 "$@" > /dev/null
}

# A consumer group that has read and committed, and gone: what a service leaves behind between deploys.
group() {
  local service=$1 port=$2 name=$3; shift 3
  for t in "$@"; do
    compose exec -T "$service" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "localhost:$port" \
      --topic "$t" --group "$name" --from-beginning --timeout-ms 3000 > /dev/null 2>&1 || true
  done
}

kafka_staging() {
  topic kafka-staging 19092 orders.created 6 --config retention.ms=604800000
  topic kafka-staging 19092 orders.paid 3 --config retention.ms=604800000
  topic kafka-staging 19092 payments.refunded 3
  topic kafka-staging 19092 customers.updated 1 --config cleanup.policy=compact
  group kafka-staging 19092 billing orders.created orders.paid
}

# An ACL binding on prod; adding one that is there already changes nothing.
acl() {
  kafka kafka-prod 29092 kafka-acls.sh --add "$@" > /dev/null
}

kafka_prod() {
  topic kafka-prod 29092 orders.created 12 --config retention.ms=604800000
  topic kafka-prod 29092 orders.paid 3 --config retention.ms=86400000
  topic kafka-prod 29092 customers.updated 1 --config cleanup.policy=compact
  topic kafka-prod 29092 shipments.dispatched 6
  group kafka-prod 29092 billing orders.created orders.paid
  group kafka-prod 29092 analytics orders.created
  acl --allow-principal User:orders-service --operation Write --topic orders. --resource-pattern-type prefixed
  acl --allow-principal User:billing --operation Read --topic orders.created --topic orders.paid --group billing
  acl --allow-principal User:analytics --operation Read --topic orders. --resource-pattern-type prefixed --group analytics
  acl --deny-principal User:analytics --operation Read --topic customers.updated
}

echo "Kafka staging (localhost:19092)"
when kafka-staging -- kafka_staging
echo "Kafka prod (localhost:29092)"
when kafka-prod -- kafka_prod

# A schema registered under a subject, as a producer's serializer registers it; the same schema again is the same version.
schema() {
  local subject=$1 type=$2 schema=$3
  local escaped=${schema//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  compose exec -T registry curl -sf -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    --data "{\"schemaType\":\"$type\",\"schema\":\"$escaped\"}" \
    "http://localhost:8080/apis/ccompat/v7/subjects/$subject/versions" > /dev/null
}

registry() {
  schema orders.created-value AVRO '{"type":"record","name":"OrderCreated","namespace":"com.shop.orders","fields":[{"name":"id","type":"string"},{"name":"customer","type":"string"},{"name":"total","type":{"type":"bytes","logicalType":"decimal","precision":10,"scale":2}}]}'
  schema orders.paid-value AVRO '{"type":"record","name":"OrderPaid","namespace":"com.shop.orders","fields":[{"name":"id","type":"string"},{"name":"paidAt","type":{"type":"long","logicalType":"timestamp-millis"}}]}'
  schema customers.updated-key AVRO '"string"'
  schema customers.updated-value JSON '{"$schema":"http://json-schema.org/draft-07/schema#","title":"Customer","type":"object","properties":{"id":{"type":"string"},"email":{"type":"string","format":"email"}},"required":["id"]}'
  schema com.shop.Money AVRO '{"type":"record","name":"Money","namespace":"com.shop","fields":[{"name":"amount","type":"long"},{"name":"currency","type":"string"}]}'
}

echo "Schema registry, prod's (http://localhost:18081)"
when registry -- registry

pulsar() {
  local service=$1; shift
  compose exec -T "$service" bin/pulsar-admin "$@" > /dev/null 2>&1 || true
}

shop() {
  local service=$1 partitions=$2 ttl=$3
  pulsar "$service" tenants create shop --allowed-clusters standalone
  pulsar "$service" namespaces create shop/orders
  pulsar "$service" namespaces set-retention shop/orders --time 60m --size 1G
  pulsar "$service" namespaces set-message-ttl shop/orders --messageTTL "$ttl"
  pulsar "$service" namespaces set-deduplication shop/orders --enable
  pulsar "$service" topics create persistent://shop/orders/created
  pulsar "$service" topics create-partitioned-topic persistent://shop/orders/paid --partitions "$partitions"
  pulsar "$service" topics create-subscription persistent://shop/orders/created --subscription billing
  # What a preview has to show beside the retention: a quota, a compatibility rule, who may do what, a backlog, a schema.
  pulsar "$service" namespaces set-backlog-quota shop/orders --limit 512M --policy producer_request_hold --type destination_storage
  pulsar "$service" namespaces set-schema-compatibility-strategy shop/orders --compatibility BACKWARD
  pulsar "$service" namespaces grant-permission shop/orders --role billing --actions consume
  pulsar "$service" namespaces grant-permission shop/orders --role checkout --actions produce
  pulsar "$service" topics grant-permission persistent://shop/orders/created --role audit --actions consume
}

# Once every subscription is there: 25 orders none of them has read yet, and the schema they are written in.
filled() {
  backlog "$1"
  created_schema "$1"
}

# Produced into an empty topic only, so a second run does not add 25 more. pulsar-client splits -m on commas.
backlog() {
  local service=$1
  if compose exec -T "$service" bin/pulsar-admin topics stats-internal persistent://shop/orders/created 2>/dev/null | grep -q '"numberOfEntries" : 0'; then
    compose exec -T "$service" bin/pulsar-client produce persistent://shop/orders/created -m 'order' -n 25 > /dev/null 2>&1 || true
  fi
}

created_schema() {
  compose exec -T "$1" sh -c 'cat > /tmp/created.json && bin/pulsar-admin schemas upload persistent://shop/orders/created -f /tmp/created.json' > /dev/null 2>&1 <<'JSON' || true
{"type": "AVRO", "schema": "{\"type\":\"record\",\"name\":\"OrderCreated\",\"namespace\":\"com.shop\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"total\",\"type\":\"long\"}]}", "properties": {"owner": "checkout"}}
JSON
}

shop_staging() {
  shop pulsar-staging 4 3600
  filled pulsar-staging
}

shop_prod() {
  shop pulsar-prod 6 600
  pulsar pulsar-prod topics create persistent://shop/orders/refunds
  pulsar pulsar-prod topics create-subscription persistent://shop/orders/created --subscription audit
  filled pulsar-prod
}

echo "Pulsar staging, 4.0 (http://localhost:18080)"
when pulsar-staging -- shop_staging
echo "Pulsar prod, 5.0 (http://localhost:28080)"
when pulsar-prod -- shop_prod

aws() {
  local account=$1; shift
  compose exec -T -e AWS_ACCESS_KEY_ID="$account" -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 localstack awslocal "$@"
}

queue_url() { aws "$1" sqs get-queue-url --queue-name "$2" --query QueueUrl --output text; }

# Sets a queue's attributes, given as name=value; a value may be JSON, escaped here into the request. Setting them after
# the queue is made keeps a second run, and a LocalStack seeded before, from being refused as a different queue.
queue_set() {
  local account=$1 queue=$2; shift 2
  local pairs=() pair value
  for pair in "$@"; do
    value=${pair#*=}
    pairs+=("\"${pair%%=*}\":\"${value//\"/\\\"}\"")
  done
  aws "$account" sqs set-queue-attributes --queue-url "$(queue_url "$account" "$queue")" --attributes "{$(IFS=,; echo "${pairs[*]}")}"
}

# Sends messages into an empty queue only, so a second run does not add more.
fill() {
  local account=$1 queue=$2 count=$3 body=$4 url
  url=$(queue_url "$account" "$queue")
  [ "$(aws "$account" sqs get-queue-attributes --queue-url "$url" --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text)" = "0" ] || return 0
  for n in $(seq 1 "$count"); do aws "$account" sqs send-message --queue-url "$url" --message-body "$body $n" > /dev/null; done
}

queues() {
  local account=$1 visibility=$2 receives=$3
  aws "$account" sqs create-queue --queue-name orders-dlq > /dev/null
  local dlq="arn:aws:sqs:us-east-1:$account:orders-dlq"
  aws "$account" sqs create-queue --queue-name orders-queue --attributes \
    "{\"VisibilityTimeout\":\"$visibility\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq\\\",\\\"maxReceiveCount\\\":\\\"$receives\\\"}\"}" > /dev/null
  # Only orders-queue may send its dead letters to orders-dlq; SNS's orders topic may send to orders-queue, on this
  # account's behalf only. Both are encrypted with SQS's own keys.
  queue_set "$account" orders-dlq SqsManagedSseEnabled=true \
    "RedriveAllowPolicy={\"redrivePermission\":\"byQueue\",\"sourceQueueArns\":[\"arn:aws:sqs:us-east-1:$account:orders-queue\"]}"
  queue_set "$account" orders-queue SqsManagedSseEnabled=true \
    "Policy={\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"orders-topic\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"arn:aws:sqs:us-east-1:$account:orders-queue\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"arn:aws:sns:us-east-1:$account:orders\"}}}]}"
  # Orders waiting to be processed, and a couple that kept failing.
  fill "$account" orders-queue 3 order
  fill "$account" orders-dlq 2 "failed order"
}

topics() {
  local account=$1 raw=$2
  local orders="arn:aws:sns:us-east-1:$account:orders"
  aws "$account" sns create-topic --name orders > /dev/null
  # Who may publish: the account itself, and EventBridge on its behalf only.
  aws "$account" sns set-topic-attributes --topic-arn "$orders" --attribute-name Policy --attribute-value \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"owner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::$account:root\"},\"Action\":[\"SNS:Publish\",\"SNS:Subscribe\",\"SNS:GetTopicAttributes\"],\"Resource\":\"$orders\"},{\"Sid\":\"events\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"events.amazonaws.com\"},\"Action\":\"sns:Publish\",\"Resource\":\"$orders\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$account\"}}}]}"
  local subscription
  subscription=$(aws "$account" sns subscribe --topic-arn "$orders" --protocol sqs \
    --notification-endpoint "arn:aws:sqs:us-east-1:$account:orders-queue" --query SubscriptionArn --output text)
  aws "$account" sns set-subscription-attributes --subscription-arn "$subscription" --attribute-name RawMessageDelivery --attribute-value "$raw"
  # Only paid orders reach the queue, matched on the message itself; what cannot be delivered waits in orders-dlq.
  aws "$account" sns set-subscription-attributes --subscription-arn "$subscription" --attribute-name FilterPolicy --attribute-value '{"status":["paid"]}'
  aws "$account" sns set-subscription-attributes --subscription-arn "$subscription" --attribute-name FilterPolicyScope --attribute-value MessageBody
  aws "$account" sns set-subscription-attributes --subscription-arn "$subscription" --attribute-name RedrivePolicy \
    --attribute-value "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:$account:orders-dlq\"}"

  aws "$account" sns create-topic --name orders.fifo \
    --attributes FifoTopic=true,ContentBasedDeduplication=true,KmsMasterKeyId=alias/aws/sns > /dev/null
  aws "$account" sqs create-queue --queue-name orders-events.fifo --attributes FifoQueue=true > /dev/null
  queue_set "$account" orders-events.fifo KmsMasterKeyId=alias/aws/sqs
  aws "$account" sns subscribe --topic-arn "arn:aws:sns:us-east-1:$account:orders.fifo" --protocol sqs \
    --notification-endpoint "arn:aws:sqs:us-east-1:$account:orders-events.fifo" > /dev/null
}

aws_staging() {
  queues 111111111111 30 5
  topics 111111111111 true
}

aws_prod() {
  queues 222222222222 60 3
  aws 222222222222 sqs create-queue --queue-name audit-queue > /dev/null
  # Anyone at all may send to it: what the preview warns about.
  queue_set 222222222222 audit-queue \
    "Policy={\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"anyone\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"arn:aws:sqs:us-east-1:222222222222:audit-queue\"}]}"
  topics 222222222222 false
  aws 222222222222 sns create-topic --name shipments > /dev/null
}

echo "SQS and SNS staging (LocalStack, account 111111111111)"
when localstack -- aws_staging
echo "SQS and SNS prod (LocalStack, account 222222222222)"
when localstack -- aws_prod

echo "Seeded. Now: source demo/env.sh && cd demo && kurkik"
