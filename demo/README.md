# kurkik demo

![kurkik: doctor, trusting the project's connections, and the terminal UI on a Kafka cluster](assets/kurkik-demo.gif)

A staging and a prod of Apache Kafka, Apache Pulsar, Amazon SNS and Amazon SQS, running in Docker on your machine, a
little apart from each other, and a connections file that names them. Use it for a first look at kurkik, a talk or a
recording. Everything kurkik does here only reads, except the seed script and the optional sync at the end.

The recording above shows `kurkik doctor`, the project's connections going from `untrusted` to `ok`, and the terminal UI
on the Kafka prod cluster: overview, topics, brokers, consumer groups, ACLs and schemas.

## Prerequisites

- **kurkik, installed.** See [Install](../README.md#install). `kurkik version` must show an `ends:` date that has not
  passed: past it, every command exits with code 77 until you install a newer release. The demo uses whatever `kurkik`
  is on your `PATH` (or `~/.kurkik/bin`); nothing is built.
- **Docker with Compose v2** (`docker compose version`). The whole stack needs about **5 GB** of memory in Docker, and
  the first start pulls about 3 GB of images. To run one system, see [One system at a time](#one-system-at-a-time).
- **bash and curl.** macOS or Linux; on Windows, use WSL.
- **Free ports** 19092, 29092, 18080, 28080, 18081 and 14566. They are off the defaults on purpose, so a Kafka, a
  Pulsar or a LocalStack of your own that is already running is left alone.

## Start

Run these from the root of this repository.

```bash
docker compose -f demo/docker-compose.yml up -d --wait   # the systems; the first time it pulls the images
demo/seed.sh                                             # fills them with an "orders" platform
source demo/env.sh                                       # this shell: kurkik, and kurkik's files kept under demo/.state
cd demo && kurkik                                        # the terminal UI
```

`env.sh` prints the version of the kurkik it found, and when that release stops working. It sets the shell up so that
your own `~/.config/kurkik` is neither read nor written: the connections file, the trust records and the snapshots a
sync writes all go under `demo/.state`. Open a new shell to get your own settings back.

The project's connections have to be trusted before kurkik uses them, since the file could have come from anybody:

```bash
kurkik conn ls     # eight connections, all "untrusted"
kurkik trust       # what the file would contact, and which variables it reads; answer y
kurkik conn ls     # all "ok"
```

## What is launched

| Service | Address | Image | Is |
|---|---|---|---|
| `kafka-staging` | `localhost:19092` | `apache/kafka:3.9.1` | the staging Kafka cluster |
| `kafka-prod` | `localhost:29092` | `apache/kafka:3.9.1` | the prod Kafka cluster; it enforces ACLs |
| `registry` | `http://localhost:18081` | `apicurio/apicurio-registry-mem:2.6.5.Final` | prod's schema registry, in memory |
| `pulsar-staging` | `http://localhost:18080` | `apachepulsar/pulsar:4.0.14` | Pulsar on the 4.0 LTS line |
| `pulsar-prod` | `http://localhost:28080` | `apachepulsar/pulsar:5.0.0` | Pulsar 5.0 |
| `localstack` | `http://localhost:14566` | `localstack/localstack:4.9` | SNS and SQS; staging is account `111111111111`, prod `222222222222` |

Nothing is kept: `down` forgets all of it. Each service has a small heap and a memory limit, about 5 GB in all.

`seed.sh` fills them with an "orders" platform whose staging and prod have drifted apart:

- **Kafka:** prod has 12 partitions of `orders.created` where staging has 6, keeps `orders.paid` a day rather than a week,
  has no `payments.refunded`, and has a `shipments.dispatched` staging does not. Prod grants each service what it uses
  and denies `analytics` the customers topic.
- **Schema registry:** prod's holds the orders' Avro schemas, a customer's key and JSON value, and a shared `Money` record.
- **Pulsar:** the partitions of `shop/orders/paid` and the namespace's message TTL differ; prod has a `refunds` topic
  and an `audit` subscription staging has not; both have 25 orders on `created` nobody has read.
- **SQS:** prod's `orders-queue` hides messages for 60 s rather than 30 and gives up after 3 receives rather than 5, and
  prod has an `audit-queue` that anyone may send to.
- **SNS:** prod has a `shipments` topic, and its `orders` subscription delivers wrapped where staging's is raw.

The files here:

- `docker-compose.yml` starts the systems; `seed.sh` fills them, and is safe to run again.
- `.kurkik/connections.yaml` names eight connections: `staging`, `prod`, `shop-staging`, `shop-prod`, `queues-staging`,
  `queues-prod`, `topics-staging`, `topics-prod`. It holds no secret.
- `env.sh` sets up the shell, as above. `reader.sh` keeps a consumer reading `orders.created` on prod, so a group has a
  member: `./reader.sh &` from `demo/`, and `kill %1` to stop it.

## Try it

From `demo/`, after `source demo/env.sh` and trusting the connections:

```bash
kurkik doctor                                        # what this installation can reach
kurkik conn test prod                                # does it answer
kurkik topology prod --consumers                     # topics, the settings somebody changed, who reads them
kurkik topology prod --all                           # every setting and where it comes from, the ACLs, the registry
kurkik topology shop-prod --all                      # the same for Pulsar; topics-prod for SNS, queues-prod for SQS
kurkik export staging                                # staging written down as an AsyncAPI 3.0 document
kurkik diff staging-kafka.yaml prod                  # that document against prod: exit 2, drift
kurkik diff shop-staging shop-prod --consumers       # a Pulsar 4.0 cluster against a 5.0 one, in one run
kurkik                                               # the terminal UI
```

Exit codes: `0` no drift, `2` drift, `3` nothing drifted but something stayed unchecked.

To see a sync, start somebody reading first, then make prod what staging's document says:

```bash
./reader.sh &
kurkik kafka sync staging-kafka.yaml prod --dry-run                # the plan, and what each change costs
kurkik kafka sync staging-kafka.yaml prod --overwrite --force --delete-topic shipments.dispatched
                                                                   # names who is reading what it destroys, asks for "prod" typed
kurkik kafka sync history prod                                     # the syncs that can be reverted
kurkik kafka sync revert <the snapshot> --force                    # prod back as it was
kill %1
```

## One system at a time

`seed.sh` skips what is not running, so a demo of one system needs only that one:

```bash
docker compose -f demo/docker-compose.yml up -d --wait kafka-staging kafka-prod registry   # about 1.8 GB
docker compose -f demo/docker-compose.yml up -d --wait localstack                          # about 0.5 GB
docker compose -f demo/docker-compose.yml up -d --wait pulsar-staging pulsar-prod          # about 2.8 GB
demo/seed.sh
```

## Stop, and start over

```bash
docker compose -f demo/docker-compose.yml down   # the systems forget everything
rm -rf demo/.state                               # kurkik forgets the trust, the user file and the snapshots
```

## If something goes wrong

- **Every command exits 77:** this kurkik release has stopped working. Install a newer one.
- **A container was killed:** Docker's VM ran out of memory. Give it more, or start one system.
- **A port is in use:** something on this machine uses one of the ports above. Stop it, or edit the port in
  `docker-compose.yml` and in `.kurkik/connections.yaml`.
- **`seed.sh` says "skipped: ... is not running":** start that service, then run `seed.sh` again.
- **A connection is `untrusted`:** run `kurkik trust`.

Report anything else as an [issue](https://github.com/Pakisan/kurkik-app/issues), with the output of `kurkik version`
and `kurkik doctor`.

## Record the GIF again

The GIF is made with [VHS](https://github.com/charmbracelet/vhs) (`brew install vhs`, which brings ttyd and ffmpeg).
Start the Kafka system and seed it (the first line of [One system at a time](#one-system-at-a-time)), then from the root
of this repository:

```bash
vhs demo/tapes/tour.tape     # about 3 minutes; writes demo/assets/kurkik-demo.gif
```

`tapes/tour.tape` is the script; `tapes/setup.tape` is the look. It uses the `kurkik` on your `PATH`, and shows paths
under your checkout, so record it from a directory whose path you are happy to publish.
