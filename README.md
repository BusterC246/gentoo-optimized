# gentoo-optimized

Host-agnostic Gentoo Portage configuration, synced between machines with sync.sh.

[![CI](https://github.com/BusterC246/gentoo-optimized/actions/workflows/ci.yml/badge.svg)](https://github.com/BusterC246/gentoo-optimized/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## What's in here

Host-agnostic /etc/portage files tracked in this repo. Each entry maps 1:1 onto /etc/portage:

| Repo path | Installs to | Purpose |
|---|---|---|
| make.conf | make.conf | Global Portage settings (a template — see below) |
| env/ | env/ | Per-package build environments (compiler-clang, compiler-gcc, default, full, lto, notmpfs) |
| package.env/00-optimization | package.env/ | package.env as a directory (*/* lto + per-package defaults) |
| package.use/00-user-flags | package.use/00-user-flags | Hand-set per-package USE flags — the only package.use file synced |
| package.accept_keywords/default | package.accept_keywords/ | Accepted keywords |
| package.mask/00-user | package.mask/00-user | Masked packages |
| package.unmask | package.unmask | Unmasked packages |
| repos.conf/eselect-repo.conf | repos.conf/eselect-repo.conf | Configured ebuild repositories |

Per the Gentoo wiki, /etc/portage is the primary Portage configuration directory and make.conf is its main file; settings that apply to every package belong here, while per-package refinements belong in package.use/ and package.env/. References:
- https://wiki.gentoo.org/wiki//etc/portage
- https://wiki.gentoo.org/wiki//etc/portage/make.conf
- https://wiki.gentoo.org/wiki/CPU_FLAGS_*
- https://wiki.gentoo.org/wiki/MAKEOPTS
- https://wiki.gentoo.org/wiki//etc/portage/package.env

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

This repo is intentionally host-agnostic so it can be shared between machines and with other users. Nothing hardware-specific is stored:

- `-march=native` is always enabled (in `COMMON_FLAGS`), but `CPU_FLAGS_X86` and `VIDEO_CARDS` are never set here — they differ per CPU/GPU.
- `MAKEOPTS` and `EMERGE_DEFAULT_OPTS` are not stored as fixed values. `sync.sh` derives them from the running hardware (see below) and writes them into `/etc/portage/make.conf` at apply time.

Repo `/etc/portage/make.conf` is a template: it contains `@MAKEOPTS@` and `@EMERGE_DEFAULT_OPTS@` placeholders that `sync.sh apply` expands before Portage ever reads the file. Never use the repo file directly as `/etc/portage/make.conf` — always run `sync.sh apply`.

## Hardware-derived values

On every `apply`, `sync.sh` computes build parallelism from the machine it runs on, reproducing the current tuning:

- `MAKEOPTS="-j$(nproc) -l0.8*$(nproc)"` — for example `-j16 -l12.8` on a 16-thread host
- `EMERGE_DEFAULT_OPTS="-j$((nproc/4)) -l0.8*$(nproc) --autounmask-write --keep-going"`

Override with `SYNC_JOBS`, `SYNC_LOAD`, `SYNC_EMERGE_JOBS`, `SYNC_EMERGE_LOAD`.

Per-machine hardware files are generated locally and never committed:

- `CPU_FLAGS_X86` is written to `/etc/portage/package.use/00cpu-flags` via `cpuid2cpuflags` — per the Gentoo wiki, `CPU_FLAGS_*` belongs in `package.use`, not `make.conf`, and is discovered per machine.
- `VIDEO_CARDS` cannot be probed reliably; set it per machine in your local `package.use/50-host-flags` (e.g. `amdgpu radeonsi`, `nvidia`, `intel`). `sync.sh apply` never touches that file, so it survives every sync.

## Pulling changes back

Changes made on a machine (`emerge --autounmask-write` appending to `package.use`, `crossdev` regenerating env files, `eselect-repo` changing `repos.conf`) can be imported back into the repo:

```sh
sudo ./sync.sh pull
```

Computed lines (`MAKEOPTS`, `EMERGE_DEFAULT_OPTS`) are re-templated to placeholders, and locally generated hardware files are excluded. Commit and push what you want to share.

## Git hooks

`.githooks/pre-commit` runs ShellCheck on `sync.sh` before each commit, and `.githooks/pre-push` blocks any push if ShellCheck fails. Configure them locally:

```sh
git config core.hooksPath .githooks
```

## CI

GitHub Actions runs ShellCheck on `sync.sh` and a template render / pull round-trip smoke test on every push and pull request. All free.

## Making it your own

Before using this repo on your machine, set per-machine values:

- `VIDEO_CARDS` in `package.use/50-host-flags` (wiki: VIDEO_CARDS) — this file is local only and never touched by `sync.sh`, so it survives `apply`
- `CPU_FLAGS_X86` is generated automatically if `app-portage/cpuid2cpuflags` is installed
- Adjust `SYNC_JOBS`/`SYNC_LOAD` if your hardware differs

## License

[GPL-3.0](LICENSE)
