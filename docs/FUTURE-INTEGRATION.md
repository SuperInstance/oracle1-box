# Future Integration: oracle1-box

## Current State
Oracle1-in-a-Box has been renamed to Keel — a general-purpose agent coordination backbone. One-command fleet provisioner for PLATO + Keeper + data pipeline. `curl | bash` install.

## Integration Opportunities

### With fleet provisioning
Keel becomes the one-command installer for the entire room-as-codespace architecture. Install PLATO, Oracle1, construct-core, ternary-cell, ternary-protocol, and ternary-registry in one command. Configure for your hardware tier: Codespace, Jetson, or ESP32. The fleet is reproducible.

### With room-as-codespace
When a new Codespace spins up, it could run Keel's setup to configure the room's environment: install the right crates, clone the right repos, configure the LLM proxy, and register with Oracle1. Keel is the room's bootstrapper.

### With construct-coordination
Keel provisions construct-coordination's shared surface: create the notes/ directory, configure the instance name, and establish the I2I connection. New fleet members are one Keel install away from full coordination.

## Dormant Ideas Now Unlockable
Keel was a one-trick provisioner. Now it provisions an entire architecture: room runtime, ternary engine, protocol stack, LLM proxy, fleet coordination. One command, full fleet.

## Potential in Mature Systems
`keel install --tier=codespace` gives you a fully operational room. `keel install --tier=jetson` gives you an edge room. `keel install --tier=esp32` gives you a bare-metal room. One tool, three targets, full fleet.

## Cross-Pollination Ideas
- **oracle1-vessel**: Keel is Oracle1's provisioning tool
- **git-agent-codespace**: Keel configures the Codespace template
- **pincherOS**: Keel installs the bare-metal runtime on edge hardware

## Dependencies for Next Steps
- Extend setup to include ternary stack installation
- Hardware tier parameterization
- Room registration with Oracle1
