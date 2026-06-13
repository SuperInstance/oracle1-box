# Oracle1-in-a-Box — One-Command Fleet Infrastructure Provisioner

**Oracle1-in-a-Box** (now renamed **Keel**) is a complete fleet infrastructure bootstrapper: a single `curl | bash` command that provisions a PLATO room server, a Keeper identity service, a data pipeline, a Constraint Flow Protocol (CFP) monitor, and an ambient briefing generator — all wired together with systemd services and timers. It transforms a bare Linux machine into a functioning node of the SuperInstance constellation in under two minutes.

## Why It Matters

Distributed systems fail not at the application layer but at the **deployment layer**. A fleet of 50 agents across 12 machines means 12 sets of dependencies, 12 service configurations, 12 timer schedules — and 12 opportunities for configuration drift. Manual setup takes 30+ minutes per machine and is never reproducible.

Keel solves this with an **idempotent provisioning script** that detects existing installations, updates them if present, and creates them if not. Running it twice is safe. Running it on a fresh Ubuntu box yields a fully operational room with:

- A **PLATO room server** — shared knowledge store where agents read/write tiles
- A **Keeper** — agent identity and authentication layer
- A **data pipeline** — hourly tile ingestion, deduplication, trust scoring, training export
- A **CFP monitor** — 15-minute Constraint Flow Protocol checks (agents share FLUX bytecode constraints)
- An **ambient briefing** generator — 30-minute "12 Things" fleet intelligence summaries

## How It Works

### Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Oracle1-in-a-Box                │
                    │                                              │
                    │   ┌──────────────┐    ┌──────────────┐      │
                    │   │ PLATO Room   │◄──►│   Keeper     │      │
                    │   │   Server     │    │ (Auth/ID)    │      │
                    │   │  :8847       │    │  :8900       │      │
                    │   └──────┬───────┘    └──────────────┘      │
                    │          │                                   │
                    │     ┌────┼────┬──────────┐                  │
                    │     ▼    ▼    ▼          ▼                  │
                    │  Pipeline  CFP   Ambient                    │
                    │  (1hr)    (15m)  Briefing                   │
                    │           Monitor  (30m)                     │
                    └─────────────────────────────────────────────┘
```

### Provisioning Pipeline

The `setup.sh` script executes 7 stages in sequence:

| Stage | Action | Idempotent? |
|---|---|---|
| 1 | Install system packages (python3, git, systemd) | Yes (skips installed) |
| 2 | Create directory structure | Yes (`mkdir -p`) |
| 3 | Clone/update plato-vessel-core | Yes (`git pull --ff-only`) |
| 4 | Create/update Python virtual environment | Yes (pip upgrade) |
| 5 | Install systemd service + timer units | Yes (`tee` overwrites) |
| 6 | Enable and start services | Yes (`systemctl restart`) |
| 7 | Verify and print summary | Read-only |

### systemd Integration

Each component runs as a systemd unit. Long-running services (PLATO, Keeper) use `Type=simple` with `Restart=on-failure`. Periodic tasks use **systemd timers** with `OnCalendar` schedules:

| Timer | Schedule | Service |
|---|---|---|
| `oracle1-pipeline.timer` | `hourly` | Data ingestion → dedup → trust scoring → training export |
| `oracle1-cfp-monitor.timer` | `*:0/15` (every 15 min) | Constraint Flow Protocol room check |
| `oracle1-ambient-briefing.timer` | `*:0/30` (every 30 min) | Fleet "12 Things" briefing generation |

Timers include `RandomizedDelaySec` to prevent thundering herd problems — if 100 nodes all fire their pipeline at exactly :00, the PLATO server would be overwhelmed. Randomized delay spreads the load.

### Docker Compose Alternative

For container-based deployments, `docker-compose.yml` defines the same five services as containers with health checks, dependency ordering, and persistent volumes:

```yaml
plato-room:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8847/health"]
    interval: 15s
    timeout: 5s
    retries: 3
```

The `keeper` service depends on `plato-room` being healthy before starting (`depends_on: condition: service_healthy`). This prevents race conditions where the auth service starts before the knowledge store is ready.

### Complexity Analysis

Provisioning time complexity is O(D + S) where:
- D = download time for dependencies (apt packages, pip packages, git clone)
- S = service startup time (PLATO server initialization)

This is dominated by D in practice (~30–90s on a fresh machine with a 100 Mbit connection). Re-provisioning (update) is O(1) for the detection phase plus O(D) for any changed dependencies.

## Quick Start

### Option 1: curl | bash (bare metal)

```bash
curl -fsSL https://raw.githubusercontent.com/SuperInstance/oracle1-box/main/setup.sh | bash
```

### Option 2: Docker Compose

```bash
git clone https://github.com/SuperInstance/oracle1-box.git
cd oracle1-box
docker compose up -d
docker compose logs -f
```

### Verify

```bash
systemctl status oracle1-plato-room   # PLATO server on :8847
systemctl status oracle1-keeper       # Keeper on :8900
systemctl list-timers                 # Pipeline, CFP, briefing timers

curl http://localhost:8847/health     # PLATO health check
```

## API

### Services Exposed

| Service | Port | Endpoint | Purpose |
|---|---|---|---|
| PLATO Room Server | 8847 | `GET /health` | Health check |
| | | `GET /room/{name}` | Read room tiles |
| | | `POST /room/{name}` | Write tile to room |
| Keeper | 8900 | `GET /health` | Health check |
| | | `POST /auth` | Agent authentication |
| CFP Room | 8847 | `GET /room/cfp` | Constraint flow state |

### setup.sh Functions

| Function | Stage | Description |
|---|---|---|
| `install_deps()` | 1 | Apt packages: python3, git, systemd |
| `create_dirs()` | 2 | `/data/plato-training`, `~/oracle1-box/` |
| `clone_repo()` | 3 | Git clone/pull plato-vessel-core |
| `setup_venv()` | 4 | Python venv + pip dependencies |
| `install_systemd_services()` | 5 | Write .service and .timer unit files |
| `enable_and_start()` | 6 | `systemctl enable + restart` for all units |
| `verify_and_summary()` | 7 | Check active services, print URLs |

## Architecture Notes

Oracle1-in-a-Box provisions the **coordination backbone** of the SuperInstance constellation. In the conservation law **γ + η = C**, the PLATO room server is the shared substrate through which γ (generation energy) and η (pulse energy) are exchanged and balanced across agents. Without a shared knowledge store, agents cannot coordinate their γ/η allocation, and the conservation law cannot be enforced.

The provisioning pipeline ensures that any new node joining the fleet can immediately participate in coordination: it has a knowledge store (PLATO), an identity (Keeper), scheduled intelligence (pipeline + briefings), and constraint sharing (CFP). See the [SuperInstance Architecture](https://github.com/SuperInstance/SuperInstance/blob/main/ARCHITECTURE.md).

**Future:** Keel (the renamed Oracle1-in-a-Box) will provision the full ternary stack — room runtime, ternary engine, protocol stack, LLM proxy — parameterized by hardware tier: `keel install --tier=codespace` for cloud, `--tier=jetson` for edge, `--tier=esp32` for bare-metal.

## References

1. systemd.timer(5) — [https://www.freedesktop.org/software/systemd/man/systemd.timer.html](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
2. Docker Compose specification — [https://docs.docker.com/compose/](https://docs.docker.com/compose/)
3. PLATO Room Architecture — SuperInstance internal documentation

## License

MIT
