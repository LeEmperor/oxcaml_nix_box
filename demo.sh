#!/usr/bin/env bash
# =============================================================================
# demo.sh -- run this OxCaml app on any machine, without building OxCaml
# =============================================================================
#
# PURPOSE
# -------
# This repo is an OxCaml application: a trading-rule DSL with a terminal UI
# (bonsai_term) and a web UI (bonsai_web). A trader writes a rule; the app
# compiles it into objects that the Hardcaml side turns into the trading-logic
# portion of the FPGA pipeline. It builds against the `5.2.0+ox` opam switch.
#
# Building that switch from scratch takes hours and ~17 GB. A hackathon judge,
# a teammate, or a quant who just wants to try the tool will not do that. This
# script gives them ONE command that runs the app anyway:
#
#     git clone <repo> && cd <repo> && ./demo.sh
#
# HOW: THREE WAYS TO GET A RUNNABLE BINARY (picked automatically)
# --------------------------------------------------------------
#   native  This machine has the OxCaml opam switch (a dev machine). Build from
#           source with dune and run the result. No downloads.
#
#   binary  Linux x86_64 with a new enough glibc. Download prebuilt executables
#           from this repo's GitHub Release, check their sha256, run them
#           directly. No OCaml, opam or dune needed.
#
#   docker  Anything else that has Docker (macOS, Windows, older Linux).
#           Download the SAME Linux binaries and run them inside a stock
#           `debian:trixie-slim` container. No custom image is built or
#           published: the container only supplies a Linux userland and a new
#           enough glibc. On Apple Silicon it runs under x86 emulation, which
#           is slower but fine for this.
#
# Override the choice with DEMO_MODE=native|binary|docker.
#
# The web UI compiles to JavaScript, so it does not care about platform at all:
# `./demo.sh web` just serves static files on localhost (python3, or a python
# container if python3 is missing) and the browser does the rest.
#
# WHY BINARIES LIVE IN GITHUB RELEASES, NOT IN GIT
# ------------------------------------------------
# Executables are never committed. `./demo.sh release` builds them into dist/
# (gitignored), and `./demo.sh publish` attaches them to a GitHub Release, which
# stores files next to a tag but outside the git history. Consumers download them
# by RELEASE_TAG. The release repo must be PUBLIC for people without access to
# download anonymously. If the source repo is private, publish the release on a
# public repo and point GITHUB_REPO at that one.
#
# WHY THERE IS A GLIBC FLOOR
# --------------------------
# OCaml native executables link every OCaml library statically. They depend
# dynamically only on libc, libm and libgmp. But the C stubs inside the opam
# switch's libraries were compiled against the build machine's glibc headers.
# On Ubuntu 24.04 that pins symbols like fmod@GLIBC_2.38 and __isoc23_strtol,
# so the binaries refuse to start on glibc < 2.38 (e.g. Ubuntu 22.04). This
# happens at the dynamic-linker level, and rebuilding only this repo cannot fix
# it: the switch itself would have to be built on an older distro.
# `release` measures the real floor with objdump and records it in MANIFEST.
# Consumers read it before choosing `binary` vs `docker`. Verified 2026-10-02:
# a binary built on Ubuntu 24.04 ran on Ubuntu 24.04 and Debian 13 with
# byte-identical output, and failed on Ubuntu 22.04.
#
# WHERE THIS STOPS: HARDWARE
# --------------------------
# This script covers the software side only: the rule editor UIs and any CLI
# executables (e.g. a rule compiler that emits RTL). Vivado synthesis and
# programming the Arty are NOT here. They need a licensed tool, minutes to
# hours of runtime and a physical board, so a live demo should use a bitstream
# built ahead of time.
#
# SUBCOMMANDS
# -----------
#   ./demo.sh                     run DEFAULT_ACTION (see CONFIG)
#   ./demo.sh run [NAME] [ARGS]   run executable NAME (default: first in EXES)
#   ./demo.sh NAME [ARGS]         shorthand for `run NAME ARGS`
#   ./demo.sh web                 serve the web UI on http://127.0.0.1:$WEB_PORT
#   ./demo.sh doctor              explain what this machine can do and which mode wins
#   ./demo.sh fetch               download + verify everything now (do this BEFORE
#                                 the venue Wi-Fi; later runs work offline)
#   ./demo.sh release             [maintainer] build dist/$RELEASE_TAG/ from source
#   ./demo.sh publish             [maintainer] upload dist/$RELEASE_TAG/ via `gh`
#   ./demo.sh clean               delete .demo-cache/ and dist/
#
# Paths given as ARGS are resolved relative to the directory you run demo.sh
# from. That is true in docker mode too, because that directory is mounted at
# the container's working directory.
#
# FILES
# -----
#   .demo-cache/<tag>/   downloaded assets, unpacked bin/ and web/   (gitignored)
#   dist/<tag>/          release assets built by `release`          (gitignored)
#   _build/demo-web/     staged web UI in native mode (dune's _build is gitignored)
#
# RELEASE ASSET CONTRACT (`release` writes these; `fetch` reads them)
# ----------------------------------------------------------------
#   <name>-linux-x86_64.gz   one per EXES entry; stripped, gzipped executable
#   web.tar.gz               WEB_FILES, flattened into one directory
#   MANIFEST                 key=value lines: commit, glibc_floor, toolchain, ...
#   SHA256SUMS               `sha256sum` output covering all of the above
# If you rename assets or MANIFEST keys, change both sides together. The
# checksums catch truncated downloads and stale caches. They do NOT defend
# against a tampered release: SHA256SUMS comes from the same release over HTTPS.
#
# NOTES FOR AGENTS / MAINTAINERS EDITING THIS FILE
# -----------------------------------------------
# * Normally only the CONFIG block changes per app. EXES and WEB_FILES are dune
#   target paths, relative to the repo root (where this script lives).
# * Must stay compatible with bash 3.2: macOS ships it as /bin/bash, and judges
#   on Macs will run this with it. That means no associative arrays, no mapfile,
#   no ${x,,}. Under `set -u`, expand possibly-empty arrays as
#   ${arr[@]+"${arr[@]}"} (bash < 4.4 treats "${arr[@]}" of an empty array as
#   unbound).
# * Use only tools present on stock macOS and Linux in consumer paths: curl,
#   gzip, tar, sha256sum OR shasum. `release` may assume a Linux dev box
#   (binutils objdump/strip, GNU tools).
# * All log output goes to stderr, so functions can return values on stdout.
# * If the web UI needs a native backend (e.g. to compile rules server-side),
#   add the backend as an EXES entry and start it in cmd_web before serving.
#   In docker mode, publish its port with `-p` the way serve_static_docker does.
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG -- the part that changes per app
# ----------------------------------------------------------------------------

APP_NAME="trading-rule-dsl"            # TODO: shown in messages and release titles
GITHUB_REPO="LeEmperor/CHANGEME"       # TODO: owner/name of the repo hosting the Release
RELEASE_TAG="demo-v0"                  # TODO: bump on every release+publish

OPAM_SWITCH="${OPAM_SWITCH:-5.2.0+ox}" # switch that native mode / release build in

# Executables, as "NAME:DUNE_TARGET". NAME is what users type
# (`./demo.sh run NAME`) and names the release asset. The first entry is the
# default for a bare `run`.
EXES=(
  "tui:terminal/main.exe"              # TODO: the bonsai_term rule editor
  "rulec:bin/rulec.exe"                # TODO: rule -> hardware-object compiler CLI
)

# Web UI files, as dune targets. They are copied FLAT into one directory and
# served from there, so index.html must reference the JS by basename. Leave the
# array empty if there is no web UI.
WEB_FILES=(
  "web/main.bc.js"                     # TODO: js_of_ocaml output of the bonsai_web app
  "web/index.html"                     # TODO
)
WEB_PORT="${WEB_PORT:-8080}"

DEFAULT_ACTION="run"                   # what a bare ./demo.sh does: run | web | doctor

DOCKER_IMAGE="debian:trixie-slim"      # glibc 2.41 and libgmp10 out of the box
DOCKER_WEB_IMAGE="python:3-alpine"     # only used when the host has no python3

# Escape hatches, mainly for testing:
#   DEMO_MODE=native|binary|docker   skip auto-detection
#   DEMO_ASSET_BASE_URL=<url>        fetch assets from here instead of GitHub
#                                    (any curl URL, including file:///abs/dir)
#   DEMO_CONF=<file>                 sourced after this block to override CONFIG

if [ -n "${DEMO_CONF:-}" ]; then
  # shellcheck source=/dev/null
  . "$DEMO_CONF"
fi

# ----------------------------------------------------------------------------
# Derived paths. Everything is anchored at the directory containing this
# script, so it can be run from anywhere.
# ----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$ROOT/.demo-cache/$RELEASE_TAG"
DIST_DIR="$ROOT/dist/$RELEASE_TAG"
WEB_ASSET="web.tar.gz"

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

log()  { printf '[demo] %s\n' "$*" >&2; }
die()  { printf '[demo] error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  # Print the SUBCOMMANDS section of the header as help text.
  sed -n '/^# SUBCOMMANDS/,/^# FILES/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
}

# sha256 of a file, on Linux (sha256sum) or macOS (shasum).
sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# version_ge A B: true if dotted version A >= B. Pure bash, because macOS
# `sort` has no -V.
version_ge() {
  local a="$1" b="$2" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    x="${x:-0}"; y="${y:-0}"
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
    if [ "$a" = "${a#*.}" ]; then a=""; else a="${a#*.}"; fi
    if [ "$b" = "${b#*.}" ]; then b=""; else b="${b#*.}"; fi
  done
  return 0
}

is_linux_x86_64() { [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; }

# glibc version, e.g. "2.39". Empty on macOS and on musl (Alpine).
glibc_version() { getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true; }

docker_available() { have docker && docker info >/dev/null 2>&1; }

git_head() { git -C "$ROOT" rev-parse HEAD 2>/dev/null || true; }

# ----------------------------------------------------------------------------
# EXES lookup ("NAME:TARGET" pairs; bash 3.2 has no associative arrays)
# ----------------------------------------------------------------------------

exe_names() {
  local e
  for e in ${EXES[@]+"${EXES[@]}"}; do printf '%s\n' "${e%%:*}"; done
}

# No `| head` / `| grep -q` on these: under pipefail an early-closing reader
# can SIGPIPE the writer and turn a match into a failure.
default_exe() {
  if [ ${#EXES[@]} -gt 0 ]; then printf '%s\n' "${EXES[0]%%:*}"; fi
}

is_exe_name() {
  local e
  for e in ${EXES[@]+"${EXES[@]}"}; do
    if [ "${e%%:*}" = "$1" ]; then return 0; fi
  done
  return 1
}

exe_target() {
  local e
  for e in ${EXES[@]+"${EXES[@]}"}; do
    if [ "${e%%:*}" = "$1" ]; then printf '%s\n' "${e#*:}"; return 0; fi
  done
  die "unknown executable '$1' (known: $(exe_names | tr '\n' ' '))"
}

exe_asset() { printf '%s-linux-x86_64.gz\n' "$1"; }

# ----------------------------------------------------------------------------
# native mode: build with dune inside the OxCaml switch
# ----------------------------------------------------------------------------

native_available() {
  have opam && [ -f "$ROOT/dune-project" ] &&
    opam switch list --short 2>/dev/null | grep -qx -- "$OPAM_SWITCH"
}

in_switch() { opam exec --switch="$OPAM_SWITCH" -- "$@"; }

# native_build TARGET... -- build dune targets from the repo root.
native_build() {
  log "building with dune in switch $OPAM_SWITCH: $*"
  (cd "$ROOT" && in_switch dune build "$@")
}

# ----------------------------------------------------------------------------
# Release assets: download, verify, unpack (binary and docker modes)
# ----------------------------------------------------------------------------

# download ASSET DEST -- fetch one release asset. Order of preference:
#   1. DEMO_ASSET_BASE_URL (testing / mirrors)
#   2. `gh` if logged in (the only way that works for private repos)
#   3. anonymous curl from github.com (public repos)
download() {
  local asset="$1" dest="$2"
  rm -f "$dest"
  have curl || have gh || die "need curl to download release assets"
  if [ -n "${DEMO_ASSET_BASE_URL:-}" ]; then
    curl -fsSL "$DEMO_ASSET_BASE_URL/$asset" -o "$dest"
  elif have gh && gh auth status >/dev/null 2>&1; then
    gh release download "$RELEASE_TAG" -R "$GITHUB_REPO" -p "$asset" -O "$dest" --clobber
  else
    curl -fsSL "https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/$asset" -o "$dest"
  fi
}

# SHA256SUMS is re-downloaded once per invocation. If a tag is re-published
# with new binaries, stale cached assets then fail verification and get
# re-fetched. If the download fails (offline) and a cached copy exists, use it,
# which is what makes `fetch` then offline runs work.
# The SUMS_FRESH flag does not survive a $(...) subshell, so call refresh_sums
# once at top level (pick_mode and cmd_fetch do) before any
# `x="$(prepare_binary ...)"`; otherwise every subshell hits the network again.
SUMS_FRESH=0
refresh_sums() {
  [ "$SUMS_FRESH" = 1 ] && return 0
  local why
  mkdir -p "$CACHE_DIR"
  # Checked here, not only in download(): download's stderr is silenced below,
  # which would swallow its die message.
  if ! have curl && ! have gh; then
    why="curl is not installed"
  elif download SHA256SUMS "$CACHE_DIR/SHA256SUMS.part" 2>/dev/null; then
    mv "$CACHE_DIR/SHA256SUMS.part" "$CACHE_DIR/SHA256SUMS"
    SUMS_FRESH=1
    return 0
  else
    why="download failed: no network, tag not published, or private repo without \`gh auth login\`"
  fi
  rm -f "$CACHE_DIR/SHA256SUMS.part"
  [ -f "$CACHE_DIR/SHA256SUMS" ] ||
    die "cannot get release '$RELEASE_TAG' from $GITHUB_REPO ($why)"
  log "could not refresh SHA256SUMS ($why); using cached copy"
  SUMS_FRESH=1
}

expected_sum() { awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$CACHE_DIR/SHA256SUMS"; }

# fetch_asset ASSET -- make sure ASSET is in the cache and matches SHA256SUMS.
fetch_asset() {
  local asset="$1" dest="$CACHE_DIR/$1" want
  refresh_sums
  want="$(expected_sum "$asset")"
  [ -n "$want" ] || die "release $RELEASE_TAG has no '$asset' (see $CACHE_DIR/SHA256SUMS)"
  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$want" ]; then return 0; fi
  log "downloading $asset ($RELEASE_TAG)"
  download "$asset" "$dest.part" || die "download of $asset failed"
  [ "$(sha256_of "$dest.part")" = "$want" ] ||
    { rm -f "$dest.part"; die "$asset: sha256 mismatch (corrupt download or changed release)"; }
  mv "$dest.part" "$dest"
}

# manifest_get KEY -- value of KEY in the release MANIFEST (empty if absent).
manifest_get() {
  fetch_asset MANIFEST
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$CACHE_DIR/MANIFEST"
}

# Tell the user when the binaries were not built from the commit they are
# looking at, so nobody demos stale behaviour by surprise.
note_commit_drift() {
  local built head
  built="$(manifest_get commit)"; head="$(git_head)"
  if [ -n "$head" ] && [ -n "$built" ] && [ "$head" != "$built" ]; then
    log "note: release $RELEASE_TAG was built from ${built:0:12}; this checkout is at ${head:0:12}"
  fi
}

# prepare_binary NAME -- print the path of the unpacked, verified executable.
prepare_binary() {
  local name="$1" gz bin
  gz="$(exe_asset "$name")"
  fetch_asset "$gz"
  bin="$CACHE_DIR/bin/$name"
  # Unpack again whenever the .gz is newer, e.g. after a re-download.
  if [ ! -x "$bin" ] || [ "$CACHE_DIR/$gz" -nt "$bin" ]; then
    mkdir -p "$CACHE_DIR/bin"
    gzip -dc "$CACHE_DIR/$gz" > "$bin.part"
    chmod +x "$bin.part"
    mv "$bin.part" "$bin"
  fi
  printf '%s\n' "$bin"
}

# prepare_web -- print the directory holding the unpacked web UI.
prepare_web() {
  fetch_asset "$WEB_ASSET"
  local dir="$CACHE_DIR/web" stamp="$CACHE_DIR/.web-unpacked"
  # A stamp file, not the dir's mtime: tar restores the archived mtime of `.`.
  if [ ! -f "$stamp" ] || [ "$CACHE_DIR/$WEB_ASSET" -nt "$stamp" ]; then
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xzf "$CACHE_DIR/$WEB_ASSET" -C "$dir"
    touch "$stamp"
  fi
  printf '%s\n' "$dir"
}

# missing_libs BIN -- print shared libraries the host lacks (empty if none).
missing_libs() { ldd "$1" 2>/dev/null | awk '/not found/ { print $1 }' || true; }

# ----------------------------------------------------------------------------
# Mode selection. Sets MODE and MODE_WHY. Order: native > binary > docker.
# ----------------------------------------------------------------------------

MODE=""
MODE_WHY=""
pick_mode() {
  local glibc floor not_binary=""

  if [ -n "${DEMO_MODE:-}" ]; then
    case "$DEMO_MODE" in
      native) MODE=native; MODE_WHY="forced by DEMO_MODE"; return 0 ;;
      binary|docker) refresh_sums; MODE="$DEMO_MODE"; MODE_WHY="forced by DEMO_MODE"; return 0 ;;
      *) die "DEMO_MODE must be native, binary or docker (got '$DEMO_MODE')" ;;
    esac
  fi

  if native_available; then
    MODE=native; MODE_WHY="opam switch $OPAM_SWITCH is installed; building from source"
    return 0
  fi

  # Every remaining mode uses the release assets.
  refresh_sums

  if is_linux_x86_64; then
    glibc="$(glibc_version)"
    if [ -z "$glibc" ]; then
      not_binary="no glibc (musl?)"
    else
      floor="$(manifest_get glibc_floor)"
      if version_ge "$glibc" "${floor:-0}"; then
        MODE=binary; MODE_WHY="Linux x86_64, glibc $glibc >= release floor ${floor:-?}"
        return 0
      fi
      not_binary="glibc $glibc is older than the release floor $floor"
    fi
  else
    not_binary="$(uname -s)/$(uname -m) cannot run Linux x86_64 binaries natively"
  fi

  if docker_available; then
    MODE=docker; MODE_WHY="$not_binary; running the Linux binaries in $DOCKER_IMAGE"
    return 0
  fi

  die "no way to run $APP_NAME here: no OxCaml switch, $not_binary, and Docker is not available. Install Docker (or Docker Desktop) and re-run."
}

# ----------------------------------------------------------------------------
# docker mode helpers
# ----------------------------------------------------------------------------

# docker_run_bin NAME ARGS... -- run a cached Linux binary in DOCKER_IMAGE.
# The cwd is mounted at /work so relative paths in ARGS and output files behave
# as they would natively. --user keeps output files owned by the caller on Linux.
docker_run_bin() {
  local name="$1"; shift
  local tty=()
  if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
  exec docker run --rm ${tty[@]+"${tty[@]}"} \
    --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TERM="${TERM:-xterm-256color}" \
    -v "$CACHE_DIR/bin:/demo/bin:ro" \
    -v "$PWD:/work" -w /work \
    "$DOCKER_IMAGE" "/demo/bin/$name" "$@"
}

# On a fresh Mac, /usr/bin/python3 is a stub that pops an "install Command
# Line Tools" dialog instead of running. Treat it as missing unless the
# tools are actually installed (xcode-select -p succeeds).
python3_usable() {
  have python3 || return 1
  [ "$(uname -s)" != Darwin ] || xcode-select -p >/dev/null 2>&1
}

serve_static() {
  local dir="$1"
  log "web UI: http://127.0.0.1:$WEB_PORT/   (Ctrl-C to stop)"
  if python3_usable; then
    exec python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 --directory "$dir"
  elif docker_available; then
    serve_static_docker "$dir"
  else
    die "need python3 or Docker to serve the web UI (or open $dir/index.html in a browser)"
  fi
}

serve_static_docker() {
  exec docker run --rm -it \
    -p "127.0.0.1:$WEB_PORT:$WEB_PORT" \
    -v "$1:/site:ro" \
    "$DOCKER_WEB_IMAGE" python -m http.server "$WEB_PORT" --directory /site
}

# ----------------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------------

cmd_run() {
  local name target bin missing
  name="$(default_exe)"
  [ -n "$name" ] || die "EXES is empty; nothing to run"
  if [ $# -gt 0 ] && is_exe_name "$1"; then name="$1"; shift; fi

  pick_mode
  log "mode: $MODE ($MODE_WHY)"

  case "$MODE" in
    native)
      target="$(exe_target "$name")"
      native_build "$target"
      exec "$ROOT/_build/default/$target" "$@"
      ;;
    binary)
      note_commit_drift
      bin="$(prepare_binary "$name")"
      missing="$(missing_libs "$bin")"
      if [ -n "$missing" ]; then
        # shellcheck disable=SC2086  # deliberate split: one lib per line -> one line
        log "missing shared libraries: $(printf '%s ' $missing)"
        if docker_available; then
          log "falling back to docker mode"
          docker_run_bin "$name" "$@"
        fi
        die "install them (Debian/Ubuntu: libgmp.so.10 is in package libgmp10) or install Docker"
      fi
      exec "$bin" "$@"
      ;;
    docker)
      note_commit_drift
      prepare_binary "$name" >/dev/null
      docker_run_bin "$name" "$@"
      ;;
  esac
}

cmd_web() {
  local stage f
  [ ${#WEB_FILES[@]} -gt 0 ] || die "WEB_FILES is empty; this app has no web UI configured"
  pick_mode
  log "mode: $MODE ($MODE_WHY)"

  if [ "$MODE" = native ]; then
    native_build ${WEB_FILES[@]+"${WEB_FILES[@]}"}
    stage="$ROOT/_build/demo-web"
    rm -rf "$stage"; mkdir -p "$stage"
    for f in ${WEB_FILES[@]+"${WEB_FILES[@]}"}; do cp "$ROOT/_build/default/$f" "$stage/"; done
  else
    # JavaScript is platform-independent, so binary and docker modes both
    # just use the released bundle.
    note_commit_drift
    stage="$(prepare_web)"
  fi
  serve_static "$stage"
}

cmd_fetch() {
  local name
  refresh_sums
  for name in $(exe_names); do prepare_binary "$name" >/dev/null; done
  if [ ${#WEB_FILES[@]} -gt 0 ]; then prepare_web >/dev/null; fi
  note_commit_drift
  log "all release assets for $RELEASE_TAG are cached in $CACHE_DIR (offline runs will work)"
}

cmd_doctor() {
  local glibc
  glibc="$(glibc_version)"
  {
    echo "app            $APP_NAME   release $GITHUB_REPO@$RELEASE_TAG"
    echo "platform       $(uname -s)/$(uname -m)   glibc ${glibc:-none}   bash $BASH_VERSION"
    if have opam; then
      if native_available; then echo "opam           switch $OPAM_SWITCH present"
      else echo "opam           installed, but no switch $OPAM_SWITCH (or no dune-project)"; fi
    else
      echo "opam           not installed"
    fi
    if docker_available; then echo "docker         available"
    elif have docker; then echo "docker         installed, daemon not reachable"
    else echo "docker         not installed"; fi
    echo "python3        $(python3_usable && echo yes || echo no)"
    echo "gh             $(have gh && (gh auth status >/dev/null 2>&1 && echo logged in || echo not logged in) || echo not installed)"
    echo "cache          $( [ -d "$CACHE_DIR" ] && ls "$CACHE_DIR" | tr '\n' ' ' || echo empty)"
    echo "head           $(git_head)"
  } >&2
  # pick_mode may die (e.g. offline, no docker). Run it in a subshell so
  # doctor always finishes, and show its error message as the verdict.
  if (pick_mode && echo "mode           $MODE -- $MODE_WHY" >&2); then :; fi
}

cmd_release() {
  local name target targets=() tmp floor f_floor stage f dirty=no head
  native_available || die "release needs the $OPAM_SWITCH switch (native mode)"
  is_linux_x86_64 || die "release must be built on Linux x86_64 (the asset names say so)"
  { have objdump && have strip; } || die "release needs binutils (objdump, strip)"

  head="$(git_head)"
  [ -n "$head" ] || die "release must run inside a git checkout (MANIFEST records the commit)"
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    dirty=yes
    log "WARNING: working tree has uncommitted changes; MANIFEST will say dirty=yes"
  fi

  for name in $(exe_names); do targets+=("$(exe_target "$name")"); done
  native_build ${targets[@]+"${targets[@]}"} ${WEB_FILES[@]+"${WEB_FILES[@]}"}

  rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
  tmp="$(mktemp -d)"
  floor="0"
  for name in $(exe_names); do
    target="$(exe_target "$name")"
    # Strip debug info: ~25% smaller, and it drops the build machine's
    # ~/.opam paths. (Those are never read at runtime, but no need to ship them.)
    strip -o "$tmp/$name" "$ROOT/_build/default/$target"
    # Highest GLIBC_x.y symbol version this binary needs = its glibc floor.
    f_floor="$(objdump -T "$tmp/$name" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' | sed 's/GLIBC_//' | sort -Vu | tail -n1 || true)"
    if version_ge "${f_floor:-0}" "$floor"; then floor="${f_floor:-0}"; fi
    gzip -9 -c "$tmp/$name" > "$DIST_DIR/$(exe_asset "$name")"
    log "packed $name <- $target (needs glibc >= ${f_floor:-?})"
  done

  if [ ${#WEB_FILES[@]} -gt 0 ]; then
    stage="$tmp/web"; mkdir -p "$stage"
    for f in ${WEB_FILES[@]+"${WEB_FILES[@]}"}; do cp "$ROOT/_build/default/$f" "$stage/"; done
    tar -czf "$DIST_DIR/$WEB_ASSET" -C "$stage" .
    log "packed $WEB_ASSET <- ${WEB_FILES[*]}"
  fi
  rm -rf "$tmp"

  # MANIFEST: provenance plus the facts consumers act on (glibc_floor).
  # built_at makes this file differ between builds; that's expected, since it
  # is run metadata, not a build output.
  {
    echo "app=$APP_NAME"
    echo "tag=$RELEASE_TAG"
    echo "commit=$head"
    echo "dirty=$dirty"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "built_on=$( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
    echo "glibc_floor=$floor"
    echo "opam_switch=$OPAM_SWITCH"
    echo "ocaml=$(in_switch ocamlopt -version)"
    echo "dune=$(in_switch dune --version)"
    echo "exes=$(exe_names | tr '\n' ' ' | sed 's/ $//')"
  } > "$DIST_DIR/MANIFEST"

  (cd "$DIST_DIR" && sha256sum MANIFEST -- *.gz > SHA256SUMS)

  log "release assets in $DIST_DIR:"
  ls -lh "$DIST_DIR" >&2
  log "next: push commit ${head:0:12}, then ./demo.sh publish"
}

cmd_publish() {
  local head
  have gh || die "publish needs the GitHub CLI (gh)"
  gh auth status >/dev/null 2>&1 || die "run \`gh auth login\` first"
  [ -f "$DIST_DIR/SHA256SUMS" ] || die "nothing to publish; run ./demo.sh release first"
  head="$(grep '^commit=' "$DIST_DIR/MANIFEST" | cut -d= -f2)"
  # The tag is created at the commit the binaries came from, so that commit
  # must already exist on GitHub.
  [ -n "$(git -C "$ROOT" branch -r --contains "$head" 2>/dev/null)" ] ||
    die "commit ${head:0:12} is not on any remote branch; push it first"

  if gh release view "$RELEASE_TAG" -R "$GITHUB_REPO" >/dev/null 2>&1; then
    log "release $RELEASE_TAG exists; replacing its assets"
    gh release upload "$RELEASE_TAG" -R "$GITHUB_REPO" --clobber "$DIST_DIR"/*
  else
    gh release create "$RELEASE_TAG" -R "$GITHUB_REPO" \
      --target "$head" --prerelease \
      --title "$APP_NAME demo ($RELEASE_TAG)" \
      --notes-file "$DIST_DIR/MANIFEST" \
      "$DIST_DIR"/*
  fi
  log "published. Consumers get it with: ./demo.sh fetch"
}

cmd_clean() {
  log "removing $ROOT/.demo-cache and $ROOT/dist"
  rm -rf "$ROOT/.demo-cache" "$ROOT/dist"
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------

main() {
  if [ $# -eq 0 ]; then set -- "$DEFAULT_ACTION"; fi
  local cmd="$1"; shift
  case "$cmd" in
    run)            cmd_run "$@" ;;
    web)            cmd_web ;;
    doctor)         cmd_doctor ;;
    fetch)          cmd_fetch ;;
    release)        cmd_release ;;
    publish)        cmd_publish ;;
    clean)          cmd_clean ;;
    -h|--help|help) usage ;;
    *)
      # `./demo.sh rulec foo.rule` == `./demo.sh run rulec foo.rule`
      if is_exe_name "$cmd"; then cmd_run "$cmd" "$@"
      else usage; exit 2
      fi
      ;;
  esac
}

main "$@"
