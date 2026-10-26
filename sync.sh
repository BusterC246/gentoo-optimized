#!/bin/sh
# sync.sh — host-agnostic Gentoo Portage configuration sync.
#
# Copies host-agnostic Portage configuration from this repository into
# /etc/portage, expanding hardware-derived placeholders at sync time, and can
# pull /etc/portage back into the repository.
#
# Usage:
#   ./sync.sh [--simulate] [--verbose] [apply|pull|check] [target...]
#   SYNC_PACKAGES="make.conf env" ./sync.sh
#   SYNC_SKIP="repos.conf profile" ./sync.sh
#
# Commands:
#   apply   Copy repo config into $PORTAGE_DIR (/etc/portage), expanding the
#           MAKEOPTS/EMERGE_DEFAULT_OPTS placeholders in make.conf and
#           generating per-machine hardware files locally (CPU_FLAGS_X86 via
#           cpuid2cpuflags). Locally generated files are never committed.
#   pull    Import $PORTAGE_DIR back into the repo, re-templating computed
#           lines back to placeholders and dropping host-specific lines.
#   check   Validate without changing anything (diffs, placeholder coverage,
#           package.env -> env file references).
#
# Options:
#   --simulate   Dry-run: show what would happen without changing anything
#   --verbose    Show detailed copy/sed operations
#
# Environment:
#   PORTAGE_DIR    Portage config directory (default: /etc/portage).
#                  Set to a scratch dir to test without root.
#   SYNC_PACKAGES  Space-separated list of targets to sync (default: all).
#   SYNC_SKIP      Space-separated list of targets to skip.
#   SYNC_JOBS      Override computed MAKEOPTS job count.
#   SYNC_LOAD      Override computed MAKEOPTS load average.
#   SYNC_EMERGE_JOBS   Override computed EMERGE_DEFAULT_OPTS job count.
#   SYNC_EMERGE_LOAD   Override computed EMERGE_DEFAULT_OPTS load average.
#
# Gentoo wiki references:
#   https://wiki.gentoo.org/wiki//etc/portage
#   https://wiki.gentoo.org/wiki//etc/portage/make.conf  (make.conf may be a
#                                                       directory; files summed)
#   https://wiki.gentoo.org/wiki/CPU_FLAGS_*             (cpuid2cpuflags,
#                                                        belongs in package.use)
#   https://wiki.gentoo.org/wiki/MAKEOPTS
#   https://wiki.gentoo.org/wiki//etc/portage/package.env
#   https://wiki.gentoo.org/wiki/Etckeeper                (local /etc history,
#                                                        complementary to this repo)

set -u

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PORTAGE_DIR="${PORTAGE_DIR:-/etc/portage}"
SIMULATE=0
VERBOSE=0
COMMAND=""
TARGETS=""

# Hardware-derived values, filled by derive_hardware_values.
MAKEOPTS_VALUE=""
EMERGE_DEFAULT_OPTS_VALUE=""

# Defaults are overridable via environment (same philosophy as dotfiles/sync.sh).
SYNC_JOBS="${SYNC_JOBS:-}"
SYNC_LOAD="${SYNC_LOAD:-}"
SYNC_EMERGE_JOBS="${SYNC_EMERGE_JOBS:-}"
SYNC_EMERGE_LOAD="${SYNC_EMERGE_LOAD:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --simulate) SIMULATE=1 ;;
    --verbose)  VERBOSE=1 ;;
    apply|pull|check) COMMAND="$1" ;;
    --) shift; break ;;
    -*) echo "sync: unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$TARGETS" ]; then TARGETS="$1"; else TARGETS="$TARGETS $1"; fi ;;
  esac
  shift
done

for arg in "$@"; do
  if [ -z "$TARGETS" ]; then TARGETS="$arg"; else TARGETS="$TARGETS $arg"; fi
done

log() { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf 'sync: %s\n' "$*"; }
say() { [ "$SIMULATE" -eq 1 ] && printf '[simulate] '; printf '%s\n' "$*"; }

# --- target discovery -------------------------------------------------------

# Everything at repo top level that mirrors /etc/portage, minus the files that
# are not Portage configuration.
default_targets() {
  find "$REPO_DIR" -maxdepth 1 -mindepth 1 \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort \
    | grep -v -e '^\.git$' -e '^\.slim$' -e '^\.gitignore$' -e '^\.githooks$' -e '^\.github$' -e '^LICENSE$' -e '^README.md$' -e '^sync.sh$'
}

resolve_targets() {
  if [ -n "${SYNC_PACKAGES:-}" ]; then
    TARGETS="$SYNC_PACKAGES"
  elif [ -z "$TARGETS" ]; then
    TARGETS=$(default_targets)
  fi
  if [ -n "${SYNC_SKIP:-}" ]; then
    for skip in $SYNC_SKIP; do
      TARGETS=$(echo "$TARGETS" | grep -v -e "^${skip}$")
    done
  fi
}

# --- hardware derivation ----------------------------------------------------

# Reproduce the current tuning formula (see MAKEOPTS wiki page):
#   MAKEOPTS jobs = nproc, load = 0.8 * nproc
#   EMERGE jobs   = nproc / 4 (min 1), load = 0.8 * nproc
derive_hardware_values() {
  if [ -n "$SYNC_JOBS" ]; then
    jobs="$SYNC_JOBS"
  elif command -v nproc >/dev/null 2>&1; then
    jobs=$(nproc)
  elif command -v getconf >/dev/null 2>&1; then
    jobs=$(getconf _NPROCESSORS_ONLN)
  else
    jobs=1
  fi
  case $jobs in
    ''|*[!0-9]*) jobs=1 ;;
  esac
  [ "$jobs" -lt 1 ] && jobs=1

  if [ -n "$SYNC_LOAD" ]; then
    load="$SYNC_LOAD"
  else
    load=$(awk -v j="$jobs" 'BEGIN { printf "%.1f", j * 0.8 }')
  fi

  if [ -n "$SYNC_EMERGE_JOBS" ]; then
    emerge_jobs="$SYNC_EMERGE_JOBS"
  else
    emerge_jobs=$(( jobs / 4 ))
    [ "$emerge_jobs" -lt 1 ] && emerge_jobs=1
  fi

  if [ -n "$SYNC_EMERGE_LOAD" ]; then
    emerge_load="$SYNC_EMERGE_LOAD"
  else
    emerge_load=$(awk -v j="$jobs" 'BEGIN { printf "%.1f", j * 0.8 }')
  fi

  case $load in ''|*[!0-9.]*) load=12.8 ;; esac
  case $emerge_load in ''|*[!0-9.]*) emerge_load=12.8 ;; esac

  MAKEOPTS_VALUE="-j${jobs} -l${load}"
  EMERGE_DEFAULT_OPTS_VALUE="-j${emerge_jobs} -l${emerge_load} --autounmask-write --keep-going"
}

# --- per-machine hardware files (generated locally, never committed) --------

# CPU_FLAGS_X86 belongs in /etc/portage/package.use (wiki: CPU_FLAGS_*), and is
# discovered per machine with cpuid2cpuflags rather than copied between hosts.
generate_cpu_flags() {
  if [ ! -d "$PORTAGE_DIR/package.use" ]; then
    mkdir -p "$PORTAGE_DIR/package.use" 2>/dev/null || true
  fi
  if command -v cpuid2cpuflags >/dev/null 2>&1; then
    flags=$(cpuid2cpuflags | sed -n 's/^CPU_FLAGS_X86: //p')
    if [ -n "$flags" ]; then
      say "writing $PORTAGE_DIR/package.use/00cpu-flags (local, hardware-derived)"
      if [ "$SIMULATE" -eq 0 ]; then
        printf '*/\* CPU_FLAGS_X86: %s\n' "$flags" > "$PORTAGE_DIR/package.use/00cpu-flags"
      fi
    else
      say "cpuid2cpuflags returned no flags; skipping 00cpu-flags"
    fi
  else
    say "app-portage/cpuid2cpuflags not installed; skipping CPU_FLAGS_X86 generation"
  fi
}

# VIDEO_CARDS cannot be probed reliably; warn if nowhere configured.
warn_video_cards() {
  if [ -f "$PORTAGE_DIR/make.conf" ] && grep -q '^VIDEO_CARDS=' "$PORTAGE_DIR/make.conf" 2>/dev/null; then
    return
  fi
  if [ -d "$PORTAGE_DIR/package.use" ] && grep -rl 'VIDEO_CARDS' "$PORTAGE_DIR/package.use" 2>/dev/null | grep -q .; then
    return
  fi
  say "WARNING: VIDEO_CARDS is unset on this machine (set per the make.conf wiki page, per machine)"
}

# --- apply: repo -> system --------------------------------------------------

copy_file() {
  # $1 = source path (repo), $2 = destination path (system)
  say "install $1 -> $2"
  if [ "$SIMULATE" -eq 0 ]; then
    if [ "$VERBOSE" -eq 1 ]; then cp -v "$1" "$2"; else cp "$1" "$2"; fi
  fi
}

copy_dir() {
  # $1 = source dir (repo), $2 = destination dir (system)
  say "install -r $1/ -> $2/"
  if [ "$SIMULATE" -eq 0 ]; then
    # package.env may exist as a legacy file on the target (pre-directory).
    # Back it up before replacing with the directory form.
    if [ -e "$2" ] && [ ! -d "$2" ]; then
      say "backing up legacy file $2 -> $2.bak"
      mv "$2" "$2.bak"
    fi
    mkdir -p "$2"
    if [ "$VERBOSE" -eq 1 ]; then cp -rv "$1/." "$2/"; else cp -r "$1/." "$2/"; fi
  fi
}

expand_placeholders() {
  # $1 = source, $2 = destination; replace @MAKEOPTS@ and @EMERGE_DEFAULT_OPTS@
  say "install (template expanded) $1 -> $2"
  if [ "$SIMULATE" -eq 0 ]; then
    sed \
      -e "s|@MAKEOPTS@|$MAKEOPTS_VALUE|g" \
      -e "s|@EMERGE_DEFAULT_OPTS@|$EMERGE_DEFAULT_OPTS_VALUE|g" \
      "$1" > "$2"
  fi
}

cmd_apply() {
  derive_hardware_values
  [ "$SIMULATE" -eq 0 ] && [ ! -w "$PORTAGE_DIR" ] && [ "$(id -u)" -ne 0 ] && {
    echo "sync: needs root to write $PORTAGE_DIR (run: sudo ./sync.sh apply, or set PORTAGE_DIR)" >&2
    exit 1
  }

  for target in $TARGETS; do
    src="$REPO_DIR/$target"
    dst="$PORTAGE_DIR/$target"
    [ -e "$src" ] || { say "skip $target (not in repo)"; continue; }

    case $target in
      make.conf)
        if [ -d "$dst" ]; then
          echo "sync: $dst is a directory; copy model expects a single file" >&2
          exit 1
        fi
        expand_placeholders "$src" "$dst"
        ;;
      *)
        if [ -d "$src" ]; then copy_dir "$src" "$dst"; else copy_file "$src" "$dst"; fi
        ;;
    esac
  done

  generate_cpu_flags
  warn_video_cards
  say "apply done. Review with: emerge --info | grep -E '^(MAKEOPTS|EMERGE_DEFAULT_OPTS|CFLAGS|CPU_FLAGS)'"
}

# --- pull: system -> repo ---------------------------------------------------

re_template_line() {
  # $1 = file; normalize computed host-specific lines back to placeholders.
  sed \
    -e 's|^MAKEOPTS=.*|MAKEOPTS="@MAKEOPTS@"|' \
    -e 's|^EMERGE_DEFAULT_OPTS=.*|EMERGE_DEFAULT_OPTS="@EMERGE_DEFAULT_OPTS@"|' \
    -e '/^CPU_FLAGS_X86=/d' \
    -e '/^VIDEO_CARDS=/d' \
    "$1"
}

cmd_pull() {
  [ "$SIMULATE" -eq 0 ] && [ ! -w "$REPO_DIR" ] && {
    echo "sync: cannot write $REPO_DIR" >&2
    exit 1
  }

  for target in $TARGETS; do
    src="$PORTAGE_DIR/$target"
    dst="$REPO_DIR/$target"
    [ -e "$src" ] || { say "skip $target (not on system)"; continue; }

    case $target in
      make.conf)
        say "capture (template) $src -> $dst"
        if [ "$SIMULATE" -eq 0 ]; then
          re_template_line "$src" > "$dst"
        fi
        ;;
      *)
        if [ -d "$src" ]; then
          say "capture -r $src/ -> $dst/"
          if [ "$SIMULATE" -eq 0 ]; then
            mkdir -p "$dst"
            # Locally generated / host-specific files must never enter the repo:
            # 00cpu-flags (generated by sync.sh), 50-host-flags (host-specific),
            # 99-system-flags (applied via dispatch-conf, managed locally).
            find "$src" -type f | while read -r file; do
              case $(basename "$file") in 00cpu-flags|50-host-flags|99-system-flags) continue ;; esac
              rel=${file#"$src"/}
              mkdir -p "$dst/${rel%/*}"
              if [ "$VERBOSE" -eq 1 ]; then cp -v "$file" "$dst/$rel"; else cp "$file" "$dst/$rel"; fi
            done
          fi
        else
          say "capture $src -> $dst"
          if [ "$SIMULATE" -eq 0 ]; then cp "$src" "$dst"; fi
        fi
        ;;
    esac
  done

  say "pull done. Commit the changes you want to keep."
}

# --- check: validate without changes ----------------------------------------

cmd_check() {
  problems=0

  [ -d "$REPO_DIR" ] || { echo "sync: repo dir $REPO_DIR not found" >&2; exit 1; }
  [ -d "$PORTAGE_DIR" ] || { echo "sync: $PORTAGE_DIR not found" >&2; exit 1; }

  # This copy model expects /etc/portage/make.conf to be a single file.
  if [ -d "$PORTAGE_DIR/make.conf" ]; then
    say "make.conf is a directory on the system; copy model expects a single file"
    problems=$((problems + 1))
  fi

  log "checking $PORTAGE_DIR against $REPO_DIR"
  for target in $TARGETS; do
    src="$REPO_DIR/$target"
    dst="$PORTAGE_DIR/$target"
    [ -e "$src" ] || { say "missing on system: $target"; problems=$((problems + 1)); continue; }
    [ -e "$dst" ] || { say "missing on system: $target"; problems=$((problems + 1)); continue; }

    if [ -d "$src" ]; then
      diff -rq "$src" "$dst" 2>/dev/null | while read -r line; do say "$line"; done
    else
      if [ "$target" = "make.conf" ]; then
        # Compare with placeholders expanded.
        tmp=$(mktemp) || exit 1
        derive_hardware_values
        sed -e "s|@MAKEOPTS@|$MAKEOPTS_VALUE|g" -e "s|@EMERGE_DEFAULT_OPTS@|$EMERGE_DEFAULT_OPTS_VALUE|g" "$src" > "$tmp"
        if diff -q "$tmp" "$dst" >/dev/null 2>&1; then
          vlog "make.conf matches template (placeholders expanded)"
        else
          say "make.conf differs from template"
          diff "$tmp" "$dst" | sed -n '1,20p'
        fi
        rm -f "$tmp"
      elif diff -q "$src" "$dst" >/dev/null 2>&1; then
        vlog "$target matches repo"
      else
        say "$target differs from repo"
        diff "$src" "$dst" | sed -n '1,20p'
      fi
    fi
  done

  # package.env -> /etc/portage/env references must resolve (wiki caveat).
  if [ -d "$PORTAGE_DIR/package.env" ]; then
    for envfile in "$PORTAGE_DIR/package.env"/*; do
      [ -f "$envfile" ] || continue
      while read -r atom file; do
        case $file in ''|\#*) continue ;; esac
        if [ ! -f "$PORTAGE_DIR/env/$file" ]; then
          say "package.env references missing env file: $file (for $atom)"
          problems=$((problems + 1))
        fi
      done < "$envfile"
    done
  fi

  command -v cpuid2cpuflags >/dev/null 2>&1 || {
    say "app-portage/cpuid2cpuflags not installed; CPU_FLAGS_X86 will not be generated"
  }
  warn_video_cards

  if [ "$problems" -eq 0 ]; then
    log "check: all targets consistent"
  else
    log "check: $problems issue(s) found"
  fi
  return "$problems"
}

# --- main -------------------------------------------------------------------

resolve_targets

case $COMMAND in
  apply)  cmd_apply  ;;
  pull)   cmd_pull   ;;
  check)  cmd_check  ;;
  *)      echo "usage: $0 [--simulate] [--verbose] [apply|pull|check] [target...]" >&2; exit 1 ;;
esac
