# Mulesoft → Traceable Publish Job

Automated script that publishes Mulesoft API assets into Traceable. Runs as a scheduled cron job on the integration EC2 host.

**Author:** vijay.venkatachalam@traceable.ai

---

## Overview

This job runs in two parts:

1. **Role cleanup** — Removes the `Asset Administrator` and `Project Administrator` roles from the configured Mulesoft service user before each publish. These roles can accumulate on the service account across runs and cause permission conflicts during publishing.
2. **Asset publishing** — Launches the `integrations-mulesoft.jar` Spring Boot application, which discovers Mulesoft APIs and publishes them as Traceable services using the configuration in `application-prod.yml`.

Each environment (dev / uat / preprod / prod) has its own publish script and its own YAML config file. This README documents the **prod** publish script, but the same pattern applies to the others.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Java 21 | Required by `integrations-mulesoft.jar` |
| `curl` | For Mulesoft API calls |
| `jq` | For parsing JSON responses |
| `nohup` | Runs the Java process in the background |
| Network egress to `anypoint.mulesoft.com` | Mulesoft OAuth + roles API |
| Network egress to the configured Traceable endpoint | See `traceable.endpoint` in the YAML |
| EC2 host timezone | Set via `CRON_TZ` in crontab (UTC system, Central scheduling) |

---

## File Layout

```
/home/ec2-user/Mulesoft/
├── prod-publish.sh                 # This script
├── dev-publish.sh                  # Environment-equivalent scripts
├── uat-publish.sh
├── preprod-publish.sh
├── cleanup_tmp.sh                  # Daily /tmp cleanup
├── application-prod.yml            # Spring Boot config (see below)
├── application-dev.yml
├── application-uat.yml
├── application-preprod.yml
├── integrations-mulesoft.jar       # The publish application
└── logs/
    └── prod-publish-job_<TIMESTAMP>.log
```

---

## Configuration — Required Inputs

Edit the placeholders at the top of `prod-publish.sh` before first run:

| Variable | What it is | Where to find it |
|---|---|---|
| `CLIENT_ID` | Mulesoft Connected App client ID | Anypoint → Access Management → Connected Apps |
| `CLIENT_SECRET` | Mulesoft Connected App client secret | Same as above |
| `ORG_ID` | Mulesoft organization ID | Anypoint → Access Management → Business Groups |
| `USER_ID` | Mulesoft service user ID whose roles are managed | Anypoint → Access Management → Users |

Keep credentials out of version control. Consider sourcing them from an environment file with restricted permissions (e.g., `chmod 600 /home/ec2-user/Mulesoft/.env`) and reading them in the script via `source`.

---

## What the Script Does — Step by Step

### Part 1: Role Cleanup

1. Initializes a timestamped log file at `/home/ec2-user/Mulesoft/logs/prod-publish-job_<TIMESTAMP>.log`.
2. Requests an OAuth access token from Mulesoft using client credentials grant.
3. Queries the total role count for the configured user.
4. Pages through the user's roles in batches of 100.
5. For each role, if the name is `Asset Administrator` or `Project Administrator`, deletes it (one deletion of each role per run, then stops looking).
6. Logs success/failure of each HTTP call.

### Part 2: Asset Publishing

1. Starts `integrations-mulesoft.jar` via `nohup` so it survives shell exit.
2. Passes the prod config: `-Dspring.config.additional-location=file:/home/ec2-user/Mulesoft/application-prod.yml`.
3. Pins the management server to port 8085 so it does not collide with the default 8080 used by the embedded Tomcat application server.
4. Appends stdout/stderr from the Java process to the same timestamped log file as Part 1.

The shell script exits immediately after launching Java. The Java process continues to run and finishes when publishing is complete.

---

## Application Config (`application-prod.yml`)

Annotated reference. Replace all `<enter_your_*>` placeholders with real values.

```yaml
runOnInit: true        # Publish immediately when the JVM starts
cronEnabled: false     # Internal scheduler disabled — we use system cron instead

traceable:
  endpoint: "<enter_your_traceable_endpoint_url>"   # e.g. https://api.traceable.ai
  token: "<enter_your_token>"                       # Traceable API token
  defaultTimeRange: "now-1d"                        # Window of Mule data to consider per run
  httpClientSpec: "readTimeout=30s,connectTimeout=2s,callTimeout=32s"

  environments:
    # Only environments whose name matches this regex are published.
    # Current value targets prod-style environments (ps, pn, prod).
    includes: [".*(ps|pn|prod).*"]
    excludes: []
    limit: 1000
    includeInactive: true

  services:
    includes: [".*"]      # All services within matched environments
    excludes: []
    limit: 50000
    includeInactive: true

  apis:
    includes: [".*"]      # All APIs within matched services
    excludes: []
    limit: 100000
    includeInactive: true
    inclLearning: true    # Include APIs still in Traceable's learning phase

mule:
  httpClientSpec: "readTimeout=30s,connectTimeout=2s,callTimeout=32s"
  clientId: "<enter_client_id>"
  clientSecret: "<enter_client_secret>"
  apiGroupId: "ai.traceable.mule"

  forcePublish: true                # Overwrite existing assets in Anypoint Exchange
  lifeCycleState: development       # Lifecycle for published assets
  tags: ["Traceable"]               # Tag applied to every published asset
  orgId: "0672bf70-041f-41d5-8acd-68b5bfcec5e0"
  orgGroupId: "0672bf70-041f-41d5-8acd-68b5bfcec5e0"
  apiVersion: "1.0.1"

  serviceTags:
    enabled: true
    detectContactName: true         # Auto-detect contact name from service labels
    detectContactEmail: true        # Auto-detect contact email from service labels
    nonContactTags: ["test"]        # Labels to exclude from contact-name detection
```

### Key fields to verify per environment

| Field | Dev | UAT | PreProd | Prod |
|---|---|---|---|---|
| `environments.includes` | dev pattern | uat pattern | preprod pattern | `.*(ps\|pn\|prod).*` |
| `mule.lifeCycleState` | development | development | development | development |
| `mule.forcePublish` | true | true | true | true |

---

## Scheduling

The script is run from root's crontab. The crontab uses `CRON_TZ` so all times are interpreted in Central time:

```cron
CRON_TZ=America/Chicago
* * * * * echo "Cron is working at $(date)" >> /tmp/cron-test.log
0 0 * * *   /home/ec2-user/Mulesoft/cleanup_tmp.sh
0 0 * * 1,3 /home/ec2-user/Mulesoft/dev-publish.sh
0 0 * * 2,4 /home/ec2-user/Mulesoft/uat-publish.sh
0 0 * * 5,6 /home/ec2-user/Mulesoft/preprod-publish.sh
0 0 * * *   /home/ec2-user/Mulesoft/prod-publish.sh
```

| Job | Frequency | Time |
|---|---|---|
| `cleanup_tmp.sh` | Daily | 12:00 AM CT |
| `dev-publish.sh` | Mon, Wed | 12:00 AM CT |
| `uat-publish.sh` | Tue, Thu | 12:00 AM CT |
| `preprod-publish.sh` | Fri, Sat | 12:00 AM CT |
| `prod-publish.sh` | Daily | 12:00 AM CT |

> Note: `cleanup_tmp.sh` and `prod-publish.sh` both fire at exactly midnight CT. If their behavior is coupled (e.g., cleanup removing files the publish job needs), stagger them — for example, move cleanup to `55 23 * * *`.

The EC2 host's system timezone is UTC. Cron log timestamps and `$(date)` output inside scripts will therefore appear in UTC, even though scheduling is interpreted in Central. Midnight CT = 05:00 UTC during CDT (Mar–Nov) and 06:00 UTC during CST (Nov–Mar).

---

## Running Manually

To run the prod publish job ad hoc (e.g., to validate config changes):

```bash
sudo /home/ec2-user/Mulesoft/prod-publish.sh
```

To follow the log as it streams:

```bash
tail -f /home/ec2-user/Mulesoft/logs/prod-publish-job_*.log | tail -n +1
```

To confirm the Java process is running:

```bash
ps -ef | grep integrations-mulesoft
```

---

## Logs

- **Location:** `/home/ec2-user/Mulesoft/logs/`
- **Naming:** `prod-publish-job_<YYYY-MM-DD_HH-MM-SS>.log`
- **Contents:** Bash log lines from the cleanup phase, followed by Spring Boot logs from the Java publishing phase.
- **Timestamps inside logs:** UTC (system timezone). To convert a log timestamp to Central, subtract 5 hours during CDT or 6 hours during CST.

### Log retention

The log directory is not rotated by the script. Add a logrotate config or extend `cleanup_tmp.sh` to age out files older than N days, e.g.:

```bash
find /home/ec2-user/Mulesoft/logs -name "prod-publish-job_*.log" -mtime +30 -delete
```

---

## Troubleshooting

| Symptom | Likely cause | Where to look |
|---|---|---|
| `Failed to fetch access token. HTTP Status: 401` | Bad `CLIENT_ID` / `CLIENT_SECRET`, or the Connected App was disabled | Anypoint → Connected Apps |
| `No roles found for user ID` | Wrong `USER_ID`, or the user has zero roles in this org | Anypoint → Users |
| `The apis are empty for service ...` | The Traceable service matches an environment, but has no APIs in the configured `defaultTimeRange` | Widen `defaultTimeRange`, or verify the environment regex actually targets active traffic |
| Java process exits immediately | Bad YAML, port 8085 already in use, or missing JAR | Check the bottom of the timestamped log file |
| Cron job did not fire at expected Central time | `CRON_TZ` missing from crontab, or cron daemon not reloaded | `crontab -l` should show `CRON_TZ=America/Chicago` at the top; reload with `sudo systemctl reload crond` |
| Two jobs starting at the same time interfere with each other | `cleanup_tmp.sh` and `prod-publish.sh` both at `0 0 * * *` | Stagger one of them |

### Useful one-liners

```bash
# Did prod-publish actually fire today?
sudo grep prod-publish /var/log/cron | tail

# Most recent log file
ls -lt /home/ec2-user/Mulesoft/logs/prod-publish-job_*.log | head -1

# Did the Java process complete the job?
grep -E "Starting the Job|Completed the Job" /home/ec2-user/Mulesoft/logs/prod-publish-job_*.log | tail
```

---

## Security Notes

- The crontab runs as **root**. Limit `chmod` on the script and YAML files to `600` (or `640` with a tightly controlled group) since they contain credentials.
- `application-prod.yml` contains the Mulesoft client secret and the Traceable token. Treat it as a secrets file — never commit it to a public repo.
- Consider moving secrets to AWS Secrets Manager / Parameter Store and templating the YAML at deploy time rather than storing live credentials on disk.

---

## Change Log

| Date | Change |
|---|---|
| 2026-05-21 | Migrated crontab to `CRON_TZ=America/Chicago` so schedules are interpreted in Central time. |
