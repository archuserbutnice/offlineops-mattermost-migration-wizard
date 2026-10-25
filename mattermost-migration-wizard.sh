#!/usr/bin/env bash
# Mattermost Entry -> Team Edition migration wizard (Ubuntu/systemd)
# Run:  sudo bash mattermost-migration-wizard.sh [--checksum <sha256|sha512>]
# Test: bash mattermost-migration-wizard.sh --self-test
#
# Safety:
# - Detects the installed version and targets that exact version (no silent upgrade).
# - Optional minimal application-state backup; it can be skipped.
# - Verifies the downloaded archive against an official checksum (or one you pass
#   with --checksum). It refuses to continue without a checksum.
# - Preserves config/data/logs/plugins/client/plugins while replacing application files.
# - Old application files are MOVED aside (not deleted) so a failed start can be rolled back.
# - Does not apt-remove/purge the commercial package automatically.
# - Does not back up the database. Back up the DB separately before production use.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SERVICE="mattermost"
readonly RELEASE_BASE="https://releases.mattermost.com"
readonly ARCHIVE_PAGE="https://docs.mattermost.com/product-overview/version-archive"
readonly USER_AGENT="Mattermost-Edition-Migration-Wizard/1.1"
readonly TOTAL_STEPS=8
readonly ESC=$'\033'

BANNER_ACTIVE=0

# Pinned OfflineOps banner: keeps the supplied ASCII logo at the top of an interactive terminal.
# Progress and prompts are shown below it. Non-interactive output uses a simple fallback.
show_banner() {
  local cols lines width row logo_width=0
  local -a logo
  logo=(
' #######  ########  ########  ##       #### ##    ## ########  #######  ########   ###### '
'##     ## ##        ##        ##        ##  ###   ## ##       ##     ## ##     ## ##    ##'
'##     ## ##        ##        ##        ##  ####  ## ##       ##     ## ##     ## ##      '
'##     ## ######    ######    ##        ##  ## ## ## ######   ##     ## ########   ###### '
'##     ## ##        ##        ##        ##  ##  #### ##       ##     ## ##              ##'
'##     ## ##        ##        ##        ##  ##   ### ##       ##     ## ##        ##    ##'
' #######  ##        ##        ######## #### ##    ## ########  #######  ##         ###### '
  )
  local subtitle=' by kooroshahmadi | https://offlineops.ir | TG @basihaat | IG @kooroshahmadi581'

  if [[ ! -t 1 || ! -t 0 ]]; then
    printf '\033[38;5;214m[ OfflineOps ] https://offlineops.ir | TG @basihaat | IG @kooroshahmadi581\033[0m\n'
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n\n'
    return 0
  fi

  cols="$(tput cols 2>/dev/null || printf '80')"
  lines="$(tput lines 2>/dev/null || printf '24')"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24

  for row in "${logo[@]}"; do
    if (( ${#row} > logo_width )); then logo_width=${#row}; fi
  done

  if (( cols > logo_width && lines >= 14 )); then
    width=$logo_width
    if (( ${#subtitle} > width )); then width=${#subtitle}; fi
    printf '\033[2J\033[H'
    for row in "${logo[@]}"; do printf '\033[38;5;214m%s\033[0m\n' "$row"; done
    printf '\033[38;5;221m%s\033[0m\n' "$subtitle"
    printf '\033[38;5;94m%s\033[0m\n' "$(printf '%*s' "$width" '' | tr ' ' '=')"
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n'
    printf '\033[2mPinned OfflineOps header · output continues below\033[0m\n'
    # Rows 1-11 stay reserved for the banner; regular output scrolls below it.
    printf '\033[12;%sr\033[12;1H' "$lines"
    BANNER_ACTIVE=1
  else
    printf '\033[38;5;214m[ OfflineOps ] https://offlineops.ir | TG @basihaat | IG @kooroshahmadi581\033[0m\n'
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n\n'
  fi
}

restore_terminal() {
  if (( BANNER_ACTIVE )); then
    printf '%s[r%s[?25h' "$ESC" "$ESC"
    BANNER_ACTIVE=0
  fi
  return 0
}

WORK_DIR=""
INSTALL_DIR=""
VERSION=""
ARCH=""
BACKUP_FILE=""
OLD_DIR=""
SERVICE_USER=""
USER_CHECKSUM=""
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
MIGRATION_STARTED=0

cleanup() {
  restore_terminal
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  return 0
}
trap cleanup EXIT
trap 'restore_terminal; exit 130' INT
trap 'restore_terminal; exit 143' TERM

die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '\n%s\n' "$*"; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash mattermost-migration-wizard.sh [--checksum <hex>]
  bash mattermost-migration-wizard.sh --self-test
  bash mattermost-migration-wizard.sh --banner-test

Options:
  --checksum <hex>  SHA-256 (64 hex) or SHA-512 (128 hex) of the Team Edition
                    archive. Use this if the wizard cannot find an official
                    checksum automatically.
  --self-test       Run local sanity checks only (no migration).
  --banner-test     Show the banner only.
  -h, --help        Show this help.
USAGE
}

ask_yes_no() {
  local prompt="$1" default="${2:-no}" answer="" suffix
  if [[ "$default" == "yes" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    answer=""
    read -r -p "$prompt $suffix " answer || true
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      [[ "$default" == "yes" ]] && return 0
      return 1
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) printf 'Please answer y or n.\n' ;;
    esac
  done
}

step() {
  local n="$1" title="$2" pct filled bar
  pct=$(( (n - 1) * 100 / TOTAL_STEPS ))
  filled=$(( pct * 30 / 100 ))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '=')"
  bar+="$(printf '%*s' "$((30 - filled))" '' | tr ' ' '-')"
  printf '\n[%s] %3d%% STEP %d/%d: %s\n' "$bar" "$pct" "$n" "$TOTAL_STEPS" "$title"
}

require_commands() {
  local cmd
  for cmd in curl tar sha256sum sha512sum systemctl awk grep sed find head tr du stat \
             chown cp mv mkdir mktemp date id uname timeout; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is missing."
  done
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
  [[ -d /run/systemd/system ]] || die "systemd is not running; this wizard requires a systemd-based Ubuntu/Debian server."
}

detect_service_user() {
  SERVICE_USER="$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)"
  [[ -n "$SERVICE_USER" ]] || SERVICE_USER="mattermost"
}

find_install_dir() {
  local exec_start candidate dir
  exec_start="$(systemctl show "$SERVICE" -p ExecStart --value 2>/dev/null || true)"
  candidate="$(printf '%s' "$exec_start" | grep -oE '/[^ ;]+/bin/mattermost' | head -n1 || true)"
  candidate="${candidate%/bin/mattermost}"

  if [[ -n "$candidate" && -x "$candidate/bin/mattermost" && -f "$candidate/config/config.json" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  for dir in /opt/mattermost /srv/mattermost /usr/local/mattermost; do
    if [[ -x "$dir/bin/mattermost" && -f "$dir/config/config.json" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

# Extract x.y.z from the "Version:" line of `mattermost version` output.
parse_version() {
  local text="$1" found
  found="$(printf '%s\n' "$text" |
    sed -n 's/^[[:space:]]*[Vv]ersion:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
    head -n1 || true)"
  printf '%s' "$found"
}

# Run `mattermost version` as the service account first (running it as root can leave
# root-owned files in logs/ that later stop the service from starting), then as root.
run_mattermost_version() {
  local out=""
  if id "$SERVICE_USER" >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    out="$(cd "$INSTALL_DIR" && timeout 60 runuser -u "$SERVICE_USER" -- "$INSTALL_DIR/bin/mattermost" version 2>&1 || true)"
  fi
  if [[ -z "$(parse_version "$out")" ]]; then
    out="$(cd "$INSTALL_DIR" && timeout 60 "$INSTALL_DIR/bin/mattermost" version 2>&1 || true)"
  fi
  printf '%s\n' "$out"
}

detect_version() {
  local output candidate file
  output="$(run_mattermost_version)"
  candidate="$(parse_version "$output")"

  if [[ -z "$candidate" ]]; then
    for file in "$INSTALL_DIR/VERSION" "$INSTALL_DIR/version.txt"; do
      if [[ -f "$file" ]]; then
        candidate="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$file" | head -n1 || true)"
        [[ -n "$candidate" ]] && break
      fi
    done
  fi

  [[ -n "$candidate" ]] || die "Could not reliably detect installed Mattermost version. No changes have been made."
  VERSION="$candidate"
  printf '%s\n' "$output" | head -n3 || true
  if printf '%s\n' "$output" | grep -Eqi '^[[:space:]]*EnterpriseReady:[[:space:]]*false'; then
    warn "This binary reports EnterpriseReady: false - it may already be Team Edition."
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

archive_exists() {
  curl --fail --location --silent --head --retry 2 --connect-timeout 20 \
    --user-agent "$USER_AGENT" "$1" >/dev/null 2>&1
}

download_progress() {
  local url="$1" dest="$2"
  # curl provides a real transfer progress bar.
  curl --fail --location --show-error --progress-bar \
    --retry 2 --connect-timeout 20 --max-time 3600 \
    --user-agent "$USER_AGENT" "$url" --output "$dest"
  printf '\n'
}

# Last-resort: scrape the docs version-archive page for a SHA-256 near the file name.
scrape_archive_checksum() {
  local filename="$1" page
  page="$WORK_DIR/version-archive.html"
  command -v python3 >/dev/null 2>&1 || return 1
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 20 \
    --user-agent "$USER_AGENT" "$ARCHIVE_PAGE" --output "$page" 2>/dev/null || return 1
  python3 - "$page" "$filename" <<'PYCODE'
import html, re, sys
from pathlib import Path

page = html.unescape(Path(sys.argv[1]).read_text(errors="replace"))
filename = sys.argv[2]
pos = page.find(filename)
if pos < 0:
    raise SystemExit(1)
region = page[max(0, pos - 5000):pos + 10000]
for pattern in (r"(?is)SHA[- ]?256.{0,500}?([0-9a-f]{64})",
                r"(?is)([0-9a-f]{64}).{0,500}?SHA[- ]?256"):
    match = re.search(pattern, region)
    if match:
        print(match.group(1).lower())
        raise SystemExit(0)
raise SystemExit(1)
PYCODE
}

# Prints a lowercase hex checksum (64 = sha256, 128 = sha512) or returns 1.
get_official_checksum() {
  local url="$1" filename="$2" suffix body hash

  if [[ -n "$USER_CHECKSUM" ]]; then
    printf '%s' "$USER_CHECKSUM"
    return 0
  fi

  # 1) Checksum files published next to the archive.
  for suffix in .sha512sum .sha256sum .sha256 .sha512; do
    body="$(curl --fail --location --silent --retry 2 --connect-timeout 20 \
      --user-agent "$USER_AGENT" "${url}${suffix}" 2>/dev/null || true)"
    hash="$(printf '%s\n' "$body" | grep -Eo '[0-9a-fA-F]{128}|[0-9a-fA-F]{64}' | head -n1 || true)"
    if [[ -n "$hash" ]]; then
      printf '%s' "${hash,,}"
      return 0
    fi
  done

  # 2) Docs version-archive page.
  hash="$(scrape_archive_checksum "$filename" 2>/dev/null || true)"
  if [[ "$hash" =~ ^[a-f0-9]{64}$ ]]; then
    printf '%s' "$hash"
    return 0
  fi
  return 1
}

verify_checksum() {
  local file="$1" expected="$2" actual
  case "${#expected}" in
    64)  actual="$(sha256sum "$file" | awk '{print $1}')" ;;
    128) actual="$(sha512sum "$file" | awk '{print $1}')" ;;
    *)   die "Unsupported checksum length ${#expected}." ;;
  esac
  [[ "$actual" == "$expected" ]] ||
    die "Checksum mismatch (expected $expected, got $actual). No application files have been changed."
}

check_archive_paths() {
  local listing="$1" path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ "$path" != /* ]] || return 1
    case "/$path/" in */../*) return 1 ;; esac
    [[ "${path%%/*}" == "mattermost" ]] || return 1
  done <<< "$listing"
  return 0
}

is_preserved() {
  case "$1" in
    config|data|logs|plugins) return 0 ;;
    *) return 1 ;;
  esac
}

make_backup() {
  local default_path rel rc=0
  local -a paths=()
  default_path="/var/backups/mattermost-before-team-${VERSION}-$(date +%Y%m%d-%H%M%S).tar.gz"
  read -r -p "Backup path [$default_path]: " BACKUP_FILE || true
  BACKUP_FILE="${BACKUP_FILE:-$default_path}"
  mkdir -p -- "$(dirname -- "$BACKUP_FILE")"

  for rel in config/config.json data logs plugins client/plugins; do
    [[ -e "$INSTALL_DIR/$rel" ]] && paths+=("$rel")
  done
  ((${#paths[@]} > 0)) || die "No recognized persistent paths found; stopping before migration."

  # tar exits 1 when a file changes while being read (normal for live logs); only >=2 is fatal.
  tar -czf "$BACKUP_FILE" -C "$INSTALL_DIR" "${paths[@]}" || rc=$?
  if (( rc == 1 )); then
    warn "Some files changed while being archived (normal for a running server's logs)."
  elif (( rc != 0 )); then
    die "Backup failed (tar exit $rc). Migration stopped before changing application files."
  fi

  chmod 600 "$BACKUP_FILE"
  printf 'Backup created: %s (%s)\n' "$BACKUP_FILE" "$(du -h "$BACKUP_FILE" | awk '{print $1}')"
  warn "Database contents are NOT included in this backup."
}

# Move the old application files aside, then copy in the new ones.
# NOTE: this is called inside `if !`, where `set -e` is disabled, so every
# critical command has an explicit `|| return 1`.
replace_application_files() {
  local source="$1" child name
  OLD_DIR="$(dirname -- "$INSTALL_DIR")/.mattermost-app-old-$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "$OLD_DIR" || return 1

  while IFS= read -r -d '' child; do
    name="${child##*/}"
    is_preserved "$name" && continue
    mv -- "$child" "$OLD_DIR/" || return 1
  done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print0)

  while IFS= read -r -d '' child; do
    name="${child##*/}"
    is_preserved "$name" && continue
    cp -a -- "$child" "$INSTALL_DIR/" || return 1
  done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)

  # Keep client/plugins (webapp plugin bundles) from the old install.
  if [[ -d "$OLD_DIR/client/plugins" ]]; then
    mkdir -p -- "$INSTALL_DIR/client" || return 1
    rm -rf -- "$INSTALL_DIR/client/plugins" || return 1
    cp -a -- "$OLD_DIR/client/plugins" "$INSTALL_DIR/client/plugins" || return 1
  fi
  return 0
}

rollback_application_files() {
  local child name
  [[ -n "$OLD_DIR" && -d "$OLD_DIR" ]] || return 1

  while IFS= read -r -d '' child; do
    name="${child##*/}"
    is_preserved "$name" && continue
    rm -rf -- "$child" || return 1
  done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print0)

  while IFS= read -r -d '' child; do
    mv -- "$child" "$INSTALL_DIR/" || return 1
  done < <(find "$OLD_DIR" -mindepth 1 -maxdepth 1 -print0)

  rmdir -- "$OLD_DIR" 2>/dev/null || true
  OLD_DIR=""
  return 0
}

restore_app_ownership() {
  local group
  # Use the service's real account (from the unit file); do not create/change accounts.
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    warn "Service account '$SERVICE_USER' not found. Verify ownership of $INSTALL_DIR manually."
    return 0
  fi
  group="$(id -gn "$SERVICE_USER")"
  # Everything except data/ (untouched by this wizard, can be very large).
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name data \
    -exec chown -R -- "$SERVICE_USER:$group" {} + ||
    warn "Could not change ownership of some files under $INSTALL_DIR; verify manually."
}

wait_for_service() {
  local i state=""
  for ((i = 0; i < 15; i++)); do
    state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    [[ "$state" == activating ]] || break
    sleep 2
  done
  [[ "$state" == active ]] || return 1
  sleep 5
  [[ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" == active ]]
}

offer_rollback() {
  [[ -n "$OLD_DIR" && -d "$OLD_DIR" ]] || return 0
  if ask_yes_no "Roll back to the previous application files (kept in $OLD_DIR)?" yes; then
    systemctl stop "$SERVICE" 2>/dev/null || true
    if rollback_application_files; then
      restore_app_ownership
      if systemctl start "$SERVICE"; then
        echo "Rolled back; the previous application files are running again."
      else
        warn "Rolled back files, but the service still failed to start. Check: journalctl -u $SERVICE -n 100 --no-pager"
      fi
    else
      warn "Automatic rollback failed. Old files remain in $OLD_DIR."
    fi
  else
    echo "Rollback skipped. Previous files remain in $OLD_DIR."
  fi
}

self_test() {
  local safe unsafe
  safe=$'mattermost/\nmattermost/bin/mattermost\nmattermost/config/config.json\n'
  unsafe=$'mattermost/\nmattermost/../../etc/passwd\n'
  check_archive_paths "$safe" || { echo 'FAIL: safe archive rejected'; return 1; }
  if check_archive_paths "$unsafe"; then echo 'FAIL: path traversal accepted'; return 1; fi
  if check_archive_paths $'/etc/passwd\n'; then echo 'FAIL: absolute path accepted'; return 1; fi
  if check_archive_paths $'other/bin/x\n'; then echo 'FAIL: foreign top-level dir accepted'; return 1; fi
  echo 'PASS: archive path validation (safe paths accepted; traversal/absolute/foreign rejected).'

  [[ "$(parse_version $'time=127.0.0.1\nVersion: 9.5.1\nBuildNumber: 9.5.1')" == "9.5.1" ]] ||
    { echo 'FAIL: version parsing'; return 1; }
  [[ -z "$(parse_version $'nothing useful here 1.2.3')" ]] ||
    { echo 'FAIL: version parser matched a non-Version line'; return 1; }
  echo 'PASS: version parsing.'

  is_preserved config && is_preserved data && is_preserved logs && is_preserved plugins ||
    { echo 'FAIL: preserved list'; return 1; }
  if is_preserved bin; then echo 'FAIL: bin must not be preserved'; return 1; fi
  echo 'PASS: preserved-path list.'

  echo 'PASS: banner and wizard functions loaded.'
  echo 'NOTE: this does not perform a real Mattermost migration.'
}

parse_args() {
  local re='^([0-9a-f]{64}|[0-9a-f]{128})$'
  MODE="run"
  while (($# > 0)); do
    case "$1" in
      --self-test)   MODE="self-test" ;;
      --banner-test) MODE="banner-test" ;;
      --checksum)
        shift
        (($# > 0)) || die "--checksum needs a value."
        USER_CHECKSUM="${1,,}"
        [[ "$USER_CHECKSUM" =~ $re ]] || die "--checksum must be 64 (SHA-256) or 128 (SHA-512) hex characters."
        ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  MODE="run"
  parse_args "$@"

  case "$MODE" in
    self-test) self_test; return ;;
    banner-test)
      show_banner
      printf 'Banner test content appears below the pinned header.\n'
      sleep 1
      return
      ;;
  esac

  require_commands
  show_banner

  ask_yes_no "This wizard will modify the Mattermost installation. Continue?" no || {
    echo "Cancelled. No changes made."; exit 0;
  }

  local state enabled filename url checksum archive extract listing

  step 1 "Detecting installation"
  detect_service_user
  INSTALL_DIR="$(find_install_dir)" || die "Could not locate Mattermost installation with config/config.json and bin/mattermost."
  detect_version
  detect_arch

  state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  [[ "$state" == active ]] && SERVICE_WAS_ACTIVE=1
  [[ "$enabled" == enabled ]] && SERVICE_WAS_ENABLED=1
  printf 'Install path : %s\nVersion      : %s\nArchitecture : linux-%s\nService      : %s (user: %s)\n' \
    "$INSTALL_DIR" "$VERSION" "$ARCH" "${state:-unknown}" "$SERVICE_USER"

  step 2 "Resolving matching Team Edition release"
  filename="mattermost-team-${VERSION}-linux-${ARCH}.tar.gz"
  url="${RELEASE_BASE}/${VERSION}/${filename}"
  printf 'Target archive: %s\n' "$url"
  archive_exists "$url" ||
    die "No Team Edition archive found at $url. Check the version and your network. No changes have been made."

  WORK_DIR="$(mktemp -d -p /var/tmp mattermost-migration.XXXXXXXX)"
  checksum="$(get_official_checksum "$url" "$filename")" ||
    die "Could not find an official checksum for $filename. Refusing an unverified download. If you have the official SHA-256/SHA-512, re-run with: --checksum <hex>"
  printf 'Expected checksum (%d-bit): %s\n' "$(( ${#checksum} * 4 ))" "$checksum"

  step 3 "Checking installation and confirmation"
  [[ -f "$INSTALL_DIR/config/config.json" ]] || die "Missing config/config.json."
  ask_yes_no "Use detected installation directory $INSTALL_DIR?" yes || {
    echo "Cancelled. No changes made."; exit 0;
  }
  ask_yes_no "Proceed with exact version $VERSION?" no || {
    echo "Cancelled. No changes made."; exit 0;
  }

  step 4 "Optional minimal backup"
  if ask_yes_no "Create optional backup of config, data, logs, and plugins? (database excluded)" yes; then
    make_backup
  else
    echo "Backup skipped by user."
    warn "Skipping backup means this wizard cannot restore overwritten application files automatically."
    ask_yes_no "Confirm you want to continue without this backup?" no || {
      echo "Cancelled before changes."; exit 0;
    }
  fi

  step 5 "Downloading exact-version Team Edition archive"
  archive="$WORK_DIR/$filename"
  download_progress "$url" "$archive"
  verify_checksum "$archive" "$checksum"
  echo "Checksum verified."

  step 6 "Validating and extracting archive"
  listing="$WORK_DIR/archive-list.txt"
  tar -tzf "$archive" > "$listing" || die "Downloaded archive is not a valid gzip tar archive."
  check_archive_paths "$(<"$listing")" ||
    die "Archive contains unsafe paths (absolute, '..', or outside mattermost/). Refusing to extract."
  grep -Eq '^mattermost/bin/mattermost$' "$listing" || die "Archive is missing mattermost/bin/mattermost."
  extract="$WORK_DIR/extracted"
  mkdir -p "$extract"
  tar --no-same-owner -xzf "$archive" -C "$extract" || die "Could not extract archive."
  [[ -x "$extract/mattermost/bin/mattermost" ]] || die "Extracted archive is missing the expected executable."

  ask_yes_no "Ready to stop Mattermost and replace application files?" no || {
    echo "Cancelled before service stop."; exit 0;
  }

  step 7 "Replacing application files"
  MIGRATION_STARTED=1
  if (( SERVICE_WAS_ACTIVE )); then
    systemctl stop "$SERVICE" || die "Could not stop Mattermost."
  fi

  # Preserve service unit and service account. Avoid package removal/purge here.
  if ! replace_application_files "$extract/mattermost"; then
    warn "Application file replacement failed. Rolling back."
    rollback_application_files || warn "Automatic rollback failed. Old files remain in ${OLD_DIR:-<none>}."
    if (( SERVICE_WAS_ACTIVE )); then systemctl start "$SERVICE" || true; fi
    die "Replacement failed. Inspect $INSTALL_DIR and the optional backup before retrying."
  fi

  restore_app_ownership
  mkdir -p "$INSTALL_DIR/client/plugins"
  restore_app_ownership

  step 8 "Starting and verifying Mattermost"
  systemctl daemon-reload || true
  if (( SERVICE_WAS_ENABLED )); then systemctl enable "$SERVICE" >/dev/null 2>&1 || true; fi

  if ! systemctl start "$SERVICE"; then
    systemctl --no-pager --full status "$SERVICE" || true
    offer_rollback
    die "Mattermost failed to start. Check: journalctl -u $SERVICE -n 100 --no-pager"
  fi

  if ! wait_for_service; then
    systemctl --no-pager --full status "$SERVICE" || true
    offer_rollback
    die "Service did not become (or stay) active. Check: journalctl -u $SERVICE -n 100 --no-pager"
  fi

  printf '\nMigration file replacement completed.\n'
  printf 'Previous version: %s\nTarget edition: Team Edition %s\nService status: active\n' "$VERSION" "$VERSION"
  if [[ -n "$BACKUP_FILE" ]]; then printf 'Backup: %s\n' "$BACKUP_FILE"; fi
  if [[ -n "$OLD_DIR" ]]; then
    printf 'Previous application files kept in: %s\n' "$OLD_DIR"
    printf '  (delete them once you have verified everything works)\n'
  fi
  printf '\nVerification checklist:\n'
  printf ' 1. Confirm login and team/channel access in the web UI.\n'
  printf ' 2. Test sending messages, file uploads, plugins, and integrations.\n'
  printf ' 3. Inspect logs: sudo journalctl -u %s -n 100 --no-pager\n' "$SERVICE"
  printf ' 4. Confirm the installed package and future upgrade method before removing anything.\n'
  printf ' 5. The database was not backed up by this script.\n'
  printf '\nTemporary files will be removed automatically.\n'
}

# Only run when executed directly (lets tests `source` this file to call functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
