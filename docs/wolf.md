# Wolf (Games On Whales)

Wolf is a [Games On Whales](https://github.com/games-on-whales/wolf) container that provides a Steam-compatible gaming environment in a container. It runs on the Strix Halo host for game streaming.

## Overview

| Property | Value |
| --- | --- |
| Image | `ghcr.io/games-on-whales/wolf:stable` |
| Network | `host` (all ports bound directly to host) |
| Service file | `wolf/wolf.container` (systemd podman unit) |
| Install location | `/etc/containers/systemd/wolf.container` (symlinked from repo) |

## Required Ports

Wolf exposes the following ports (all bound directly to host via `Network=host`):

| Port | Protocol | Purpose |
| --- | --- | --- |
| `47984` | TCP | Game streaming |
| `47989` | TCP | Game streaming |
| `48010` | TCP | Game streaming |
| `47999` | UDP | Game streaming |
| `48100` | UDP | Game streaming |
| `48200` | UDP | Game streaming |

### Firewall Configuration

These ports must be open in firewalld:

```bash
sudo firewall-cmd --add-port=47984/tcp --add-port=47989/tcp \
  --add-port=48010/tcp --add-port=47999/udp \
  --add-port=48100/udp --add-port=48200/udp --permanent
sudo firewall-cmd --reload
```

## Installation

### 1. Deploy the container unit

```bash
sudo cp wolf/wolf.container /etc/containers/systemd/wolf.container
sudo systemctl daemon-reload
```

### 2. Create the games volume mount

Wolf expects Steam game libraries at `/mnt/games` (mapped into the container):

```bash
sudo mkdir -p /mnt/games
# Symlink your actual Steam library if it lives elsewhere:
sudo ln -s /path/to/steamapps /mnt/games
```

### 3. Start the service

```bash
sudo systemctl enable --now wolf
sudo systemctl status wolf
```

### 4. Verify

```bash
sudo podman ps | grep wolf
sudo podman logs wolf --tail 20
```

## Devices & Permissions

Wolf requires access to:

- `/dev/dri` — GPU (RADV/Vulkan rendering)
- `/dev/uinput` — Input device passthrough
- `/dev/uhid` — HID device passthrough
- `/dev/` (full) — Device cgroup rule `c 13:* rmw` for char devices

The systemd unit handles all of these via `AddDevice` directives and `PodmanArgs`.

## Configuration

Optional config file: `/etc/wolf/wolf.conf` (mounted read-write into the container).

## Maintenance

- **Auto-update**: `AutoUpdate=registry` in the unit pulls the latest image on restart.
- **Logs**: `sudo podman logs wolf`
- **Stop**: `sudo systemctl stop wolf`
- **Remove stale PulseAudio container**: handled automatically by `ExecStartPre`
