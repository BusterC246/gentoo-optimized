# gentoo-optimized

Host-agnostic Gentoo Portage configuration, synced between machines with sync.sh.

[![CI](https://github.com/BusterC246/gentoo-optimized/actions/workflows/ci.yml/badge.svg)](https://github.com/BusterC246/gentoo-optimized/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## What's in here

| Repo path | Installs to |
|---|---|
| make.conf | make.conf |
| env/ | env/ |
| package.env/00-optimization | package.env/ |
| package.use/00-user-flags | package.use/ |
| package.accept_keywords/default | package.accept_keywords/ |
| package.mask/00-user | package.mask/ |
| package.unmask | package.unmask |
| repos.conf/eselect-repo.conf | repos.conf/ |

## Installation

Clone the repo and run `sync.sh apply`:

```sh
git clone https://github.com/BusterC246/gentoo-optimized.git ~/.gentoo-optimized
cd ~/.gentoo-optimized
sudo ./sync.sh apply
```

`sync.sh` needs root to write `/etc/portage`. To see what would happen without changing anything:

```sh
PORTAGE_DIR=$(mktemp -d) ./sync.sh --simulate apply
```

To sync only specific targets:

```sh
SYNC_PACKAGES="make.conf env" sudo ./sync.sh apply
```

To skip targets:

```sh
SYNC_SKIP="repos.conf" sudo ./sync.sh apply
```

## Host-agnostic design

This repo is host-agnostic. Nothing hardware-specific is stored:

- `-march=native` is always enabled; `CPU_FLAGS_X86` and `VIDEO_CARDS` are never set here.
- `MAKEOPTS` and `EMERGE_DEFAULT_OPTS` are computed from the running hardware at apply time and overridable via `SYNC_JOBS`, `SYNC_LOAD`, `SYNC_EMERGE_JOBS`, `SYNC_EMERGE_LOAD`.

Repo `make.conf` is a template with `@MAKEOPTS@` and `@EMERGE_DEFAULT_OPTS@` placeholders expanded by `sync.sh apply`. Never use it directly as `/etc/portage/make.conf`.

`CPU_FLAGS_X86` is generated locally via `cpuid2cpuflags` into `package.use/00cpu-flags` (never committed). `VIDEO_CARDS` goes in your local `package.use/50-host-flags`, which `sync.sh` never touches.

## Pulling changes back

Changes made on a machine can be imported back:

```sh
sudo ./sync.sh pull
```

Computed lines are re-templated to placeholders; locally generated hardware files are excluded. Commit and push what you want to share.

## Making it your own

Before using this repo on your machine:

- Set `VIDEO_CARDS` in `package.use/50-host-flags` (local only, never synced)
- Install `app-portage/cpuid2cpuflags` for automatic `CPU_FLAGS_X86`
- Adjust `SYNC_JOBS`/`SYNC_LOAD` if your hardware differs

## License

[GPL-3.0](LICENSE)
