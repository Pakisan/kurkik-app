# Kurkik

**Catch API drift before your consumers do.**

Kurkik is the messaging-infrastructure side of a self-maintaining API. It reads your on-premise or cloud brokers,
writes what it finds as AsyncAPI, and catches drift between your documents and what actually runs - then proposes the fix.

- **Guards against API drift** between your AsyncAPI documents and the brokers that actually run.
- **Keeps APIs self-maintaining:** export, compare and fix, all from one AsyncAPI document.
- **Makes setups repeatable:** apply one document to dev, staging and prod, with a plan you approve.

Works with **Apache Kafka, Apache Pulsar, Amazon SNS and Amazon SQS**. RabbitMQ is coming soon.

[Website](https://kurkik.pavelon.dev) · [Docs](https://kurkik.pavelon.dev/docs/) · [Report an issue](https://github.com/Pakisan/kurkik-app/issues)

> **Early access.** Every release here is an early-access (`-eap.N`) or release-candidate (`-rc.N`) build. Each one is
> free to use and stops working on a fixed date. See [Early access](#early-access).

## Install

Kurkik ships with its own JVM, so there is nothing to install first.

**macOS and Linux**

```bash
curl -fsSL https://kurkik.pavelon.dev/install.sh | sh
```

The script installs to `~/.kurkik` and checks the archive's SHA-256 checksum and PGP signature before it unpacks anything.
To install a specific version, add `-s -- --version=1.0.0-eap.1`. Run it with `--help` to see the other options.

**Windows, or a manual install:** download the zip for your platform from [Releases](https://github.com/Pakisan/kurkik-app/releases),
unpack it, and add its `bin` folder to your `PATH`.

| Platform | Archive |
|---|---|
| macOS, Apple silicon | `kurkik-<version>-osx-aarch_64.zip` |
| macOS, Intel | `kurkik-<version>-osx-x86_64.zip` |
| Linux x64 (glibc) | `kurkik-<version>-linux-x86_64.zip` |
| Linux arm64 (glibc) | `kurkik-<version>-linux-aarch_64.zip` |
| Windows x64 | `kurkik-<version>-windows-x86_64.zip` |

Use the script or Homebrew where you can. macOS Gatekeeper and Windows SmartScreen warn about zips saved from a browser.

Then check that it works:

```bash
➜ kurkik doctor 
ok    Pulsar 4.0.x LTS: adapter found
ok    Pulsar 5.0.x: adapter found
ok    AWS HTTP client: one, as the SDK needs
ok    AWS MSK IAM: available
ok    Keychain: available
info  Kerberos: no krb5.conf set; a connection names its own
info  Connections: /Users/pavelbodyachevskiy/.config/kurkik/connections.yaml
info  AWS profiles: none
```

## What it does

- **Inspect what actually runs.** Topics, partitions, settings and where they come from, consumer groups, ACLs and schemas.
  Browse them in a terminal UI, or get plain CLI output.
- **Export to AsyncAPI 3.0.** Channels, servers and consumers, plus the real Avro, JSON Schema or Protobuf definitions from
  Confluent-compatible registries. Anything that could not be read is stated in the document and in an export report.
  Nothing is invented.
- **Compare environments.** Staging against prod, or a document against a live system. Exit codes a script understands:
  `0` no drift, `2` drift, `3` something stayed unchecked.
- **Sync with a plan you approve** *(Apache Kafka, Apache Pulsar)*. A dry run comes first. Every change is classified by
  what it costs, and whoever reads what would be destroyed is named. A snapshot is taken before the first write, and every
  run can be reverted.
- **Share connections with your team.** A committed project file names every broker in every environment. Secrets stay
  references (keychain, `env:`, `file:`, prompt), and a project file is only used once you trust it.
- **Give your agent the evidence.** An MCP server with read-only tools: connections, topology, inventory, export and compare.
- **Fail the build on drift.** Run the same diff in CI/CD. An incomplete check is never reported as a pass.

```bash
kurkik topology prod --consumers              # what prod holds
kurkik export staging                         # staging, written down as AsyncAPI
kurkik diff staging-kafka.yaml prod           # exit 2: drift
kurkik kafka sync staging-kafka.yaml prod --dry-run
kurkik                                        # the terminal UI
claude mcp add kurkik -- kurkik mcp           # any MCP client
```

No cluster to try it on? [`demo/`](demo/) starts a staging and a prod of Kafka, Pulsar, SNS and SQS in Docker, with some
drift between them, and walks through the commands above.

## Where it runs

- **Command line** on macOS, Linux and Windows: the `kurkik` command, its terminal UI and its MCP server.
- **JetBrains IDEs:** Kurkik powers the AsyncAPI plugin. Move your connections to the CLI with `kurkik conn import --from-idea`.
- **AI agents:** Claude Code, Codex or any agent that speaks MCP. The tools only read, and secrets are redacted before an
  agent sees them.

Schemas are read from Confluent, Karapace, Redpanda and Apicurio registries.

## Is it safe in production?

Kurkik only reads, except for `kafka sync` and `pulsar sync`. Those show a dry-run plan, ask before they write, take a
snapshot first and can be reverted. Credentials are never stored in plain text. Kurkik itself collects nothing and sends
nothing home.

## Early access

Each early-access release stops working on a date fixed when it is built. `kurkik version` shows that date as `ends:`.
In the last 7 days, every command warns about it. After that date, commands exit with code `77` until you install a newer
release. There is no activation step and no network check. Use is covered by `EAP-LICENSE.txt`, which ships in every archive.

## Verify a download

Every release includes `checksums_sha256.txt` and a PGP `.asc` signature for each file.

```bash
shasum -a 256 -c checksums_sha256.txt --ignore-missing
curl -fsSLO https://raw.githubusercontent.com/Pakisan/kurkik-app/master/kurkik-release.asc
gpg --import kurkik-release.asc
gpg --verify kurkik-<version>-<platform>.zip.asc kurkik-<version>-<platform>.zip
```

The release key's fingerprint is `98E2 4FB7 BBFF 7ED2 58D5  EAF1 BFA6 A9C8 FBE4 5EDA`. Accept a signature only from that key.

## Report an issue

Open an [issue](https://github.com/Pakisan/kurkik-app/issues) and include the output of `kurkik version` and `kurkik doctor`.
Running a broker that isn't listed (NATS, MQTT, Solace…)? Tell us; custom integrations are on the table.

## Licence

Kurkik is proprietary software. Copyright (c) 2026 Pavel Bodiachevskii. Early-access and release-candidate builds are
licensed under `EAP-LICENSE.txt`. See [LICENSE](LICENSE). The source code is not public; this repository holds the
releases and the issue tracker.

---

Apache Kafka and Apache Pulsar are trademarks of The Apache Software Foundation. Amazon SNS and Amazon SQS are trademarks of
Amazon.com, Inc. JetBrains and IntelliJ IDEA are trademarks of JetBrains s.r.o. Kurkik is not affiliated with or endorsed by
any of them.
