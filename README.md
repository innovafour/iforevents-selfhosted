# IForevents, self-hosted

Product analytics on your own servers. Events from your apps, a dashboard to
query them, and the data never leaves your infrastructure.

This repository is the install: one `docker-compose.yml`, public images, no
account with us, no license key.

## Install

Requirements: Docker Engine 24+ with Docker Compose v2, 2 CPUs, 4 GB RAM,
20 GB disk. Linux, macOS or Windows with Docker Desktop.

```bash
mkdir iforevents && cd iforevents
curl -fsSLO https://raw.githubusercontent.com/innovafour/iforevents-selfhosted/main/docker-compose.yml
curl -fsSLO --create-dirs --output-dir clickhouse https://raw.githubusercontent.com/innovafour/iforevents-selfhosted/main/clickhouse/iforevents.xml
docker compose up -d
```

Or clone the repository and run `docker compose up -d` inside it.

Then open http://localhost:8010. The first visit asks for the admin account
(name, e-mail, password, organization). That form appears once: afterwards
new users come from team invitations in Settings, and signup is closed.

The API listens on http://localhost:8000. Point your SDKs at it: the dashboard
shows a ready-made snippet for each project under Projects, with the right
URL and key filled in.

```bash
curl -X POST http://localhost:8000/v1/events/track \
  -H "X-Project-Key: $PROJECT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"event_name":"signup","custom_uuid":"user-42"}'
```

## What runs

| Service | Image | Role | Published port |
|---|---|---|---|
| `dashboard` | `ghcr.io/innovafour/iforevents-dashboard` | Web UI | 8010 |
| `api` | `ghcr.io/innovafour/iforevents-api` | Ingest, analytics, auth | 8000 |
| `clickhouse` | `clickhouse/clickhouse-server` | Events, users, projects | none |
| `redis` | `redis` | Project cache, rate limits | none |
| `rabbitmq` | `rabbitmq` | Batch ingest queue | none |

Data lives in named volumes: `clickhouse_data`, `redis_data`,
`rabbitmq_data` and `api_data` (the generated session secret). Removing the
containers keeps them; `docker compose down -v` deletes everything.

Migrations run automatically when the api starts, on first boot and after
every upgrade.

## Configure

Nothing is required. To change a default, create a `.env` file next to the
compose file with the lines you need. [`.env.example`](.env.example) lists
every variable with its default; the ones people set most:

| Variable | Why |
|---|---|
| `PUBLIC_URL`, `API_PUBLIC_URL` | You reach the install through a domain or a LAN address instead of localhost |
| `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_PASSWORD` | Create the admin at boot, for unattended installs |
| `SMTP_*` | Send invitations and password resets by e-mail |
| `DB_PASSWORD`, `RABBITMQ_PASSWORD`, `TOKEN_SECRET` | Your own secrets instead of the internal defaults |
| `IFOREVENTS_VERSION` | Pin a release |
| `EVENTS_RETENTION_DAYS` | Drop raw events after N days |

Apply with `docker compose up -d` again.

## A domain and HTTPS

The overlay [`docker-compose.caddy.yml`](docker-compose.caddy.yml) puts Caddy
in front of both services on one domain with an automatic Let's Encrypt
certificate. Point the DNS record at the host, open ports 80 and 443, then:

```bash
cat >> .env <<'ENV'
DOMAIN=analytics.example.com
ACME_EMAIL=you@example.com
PUBLIC_URL=https://analytics.example.com
API_PUBLIC_URL=https://analytics.example.com
BIND_ADDRESS=127.0.0.1
TRUSTED_PROXY_CIDRS=172.28.0.0/16
ENV
docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d
```

`/v1/*`, `/mcp` and `/.well-known/*` go to the api, everything else to the
dashboard, so SDKs and the browser use the same origin.

Already have nginx or Traefik? Keep the base compose, set `BIND_ADDRESS=127.0.0.1`,
proxy `PUBLIC_URL` to `127.0.0.1:8010` and `API_PUBLIC_URL` to
`127.0.0.1:8000`, and put the proxy's address in `TRUSTED_PROXY_CIDRS`.

## Upgrade

```bash
docker compose pull
docker compose up -d
```

Releases and their notes: https://github.com/innovafour/iforevents-selfhosted/releases.
Image tags follow the release (`1.4.2`, `1.4`, `1`, `latest`); both images
of one release are tested together, so upgrade them together.

## Back up

The state worth keeping is the ClickHouse database and `api_data`:

```bash
docker compose exec clickhouse clickhouse-client --query "BACKUP DATABASE iforevents TO Disk('backups', 'iforevents-$(date +%F).zip')"
docker run --rm -v iforevents_api_data:/data -v "$PWD/backups":/out alpine tar czf /out/api_data.tgz -C /data .
```

Both land in `./backups`. Restore with
`RESTORE DATABASE iforevents FROM Disk('backups', 'iforevents-<date>.zip')`
on an empty database, and untar `api_data.tgz` into the `api_data` volume.

Redis and RabbitMQ hold caches and in-flight batches only; they rebuild
themselves.

## Uninstall

```bash
docker compose down -v
```

## Security notes

- Only ports 8010 and 8000 are published. ClickHouse, Redis and RabbitMQ are
  internal to the Docker network; that is why their default passwords are
  acceptable on a host you control. Change them on a shared host.
- Session cookies are `Secure` when `PUBLIC_URL` is https. Over plain http on
  a LAN they are not, which is the trade-off of not having a certificate.
- The api refuses wildcard CORS and the RabbitMQ guest account, and never
  ships a default session secret: it generates one per install.
- Report vulnerabilities privately to security@iforevents.com. Do not open a
  public issue.

## Help

- Documentation: https://iforevents.com/docs
- Issues and questions: https://github.com/innovafour/iforevents-selfhosted/issues

MIT licensed. The hosted edition at iforevents.com runs the same images with
a managed control plane; it is available by invitation.
