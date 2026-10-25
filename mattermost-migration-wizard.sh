#!/usr/bin/env bash
# Mattermost Entry -> Team Edition migration wizard (Ubuntu/systemd)
# Run: sudo bash mattermost_migration_wizard.sh
#
# Safety:
# - Detects the installed version and targets that exact version (no silent upgrade).
# - Optional minimal application-state backup; it can be skipped.
# - Verifies the downloaded archive with an official SHA-256 checksum when available.
# - Preserves config/data/logs/plugins/client/plugins while replacing application files.
# - Does not apt-remove/purge the commercial package automatically.
# - Does not back up the database. Back up the DB separately before production use.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SERVICE="mattermost"
readonly RELEASE_BASE="https://releases.mattermost.com"
readonly ARCHIVE_PAGE="https://docs.mattermost.com/product-overview/version-archive"
readonly USER_AGENT="Mattermost-Edition-Migration-Wizard/1.0"
readonly TOTAL_STEPS=8
readonly ESC=$'\033'
BANNER_ACTIVE=0


# Pinned OfflineOps banner: keeps the supplied ASCII logo at the top of an interactive terminal.
# Progress and prompts are shown below it. Non-interactive output uses a simple fallback.
show_banner() {
  local cols lines width row
  local -a logo
  logo=(
' #######  ######## ######## ##       #### ##    ## ########  #######  ########   ###### '
'##     ## ##       ##       ##        ##  ###   ## ##       ##     ## ##     ## ##    ##'
'##     ## ##       ##       ##        ##  ####  ## ##       ##     ## ##     ## ##      '
'##     ## ######   ######   ##        ##  ## ## ## ######   ##     ## ########   ###### '
'##     ## ##       ##       ##        ##  ##  #### ##       ##     ## ##              ##'
'##     ## ##       ##       ##        ##  ##   ### ##       ##     ## ##        ##    ##'
' #######  ##       ##       ######## #### ##    ## ########  #######  ##         ###### '
  )
  local subtitle='  by kooroshahmadi  |  https://offlineops.ir  |  TG @basihaat  |  IG @kooroshahmadi581'
  if [[ ! -t 1 || ! -t 0 ]]; then
    printf '\033[38;5;214m[ OfflineOps ]  https://offlineops.ir | TG @basihaat | IG @kooroshahmadi581\033[0m\n'
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n\n'
    return
  fi
  cols="$(tput cols 2>/dev/null || printf '80')"
  lines="$(tput lines 2>/dev/null || printf '24')"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  local logo_width=0
  for row in "${logo[@]}"; do ((${#row} > logo_width)) && logo_width=${#row}; done
  if (( cols > logo_width && lines >= 14 )); then
    width=$logo_width
    ((${#subtitle} > width)) && width=${#subtitle}
    printf '\033[2J\033[H'
    for row in "${logo[@]}"; do printf '\033[38;5;214m%s\033[0m\n' "$row"; done
    printf '\033[38;5;221m%s\033[0m\n' "$subtitle"
    printf '\033[38;5;94m%*s\033[0m\n' "$width" '' | tr ' ' '='
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n'
    printf '\033[2mPinned OfflineOps header · output continues below\033[0m\n'
    # Rows 1-11 stay reserved for the banner; regular output scrolls below it.
    printf '\033[12;%sr\033[12;1H' "$lines"
    BANNER_ACTIVE=1
  else
    printf '\033[38;5;214m[ OfflineOps ]  https://offlineops.ir | TG @basihaat | IG @kooroshahmadi581\033[0m\n'
    printf '\033[1;36mMattermost Entry -> Team Edition Migration Wizard\033[0m\n\n'
  fi
}
restore_terminal() {
  if (( BANNER_ACTIVE )); then printf '%s[r\033[?25h' "$ESC"; BANNER_ACTIVE=0; fi
}

WORK_DIR=""
INSTALL_DIR=""
VERSION=""
ARCH=""
BACKUP_FILE=""
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
MIGRATION_STARTED=0

cleanup() {
  restore_terminal
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'restore_terminal; exit 130' INT
trap 'restore_terminal; exit 143' TERM

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '\n%s\n' "$*"; }

ask_yes_no() {
  local prompt="$1" default="${2:-no}" answer suffix
  [[ "$default" == "yes" ]] && suffix="[Y/n]" || suffix="[y/N]"
  while true; do
    read -r -p "$prompt $suffix " answer || true
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Please answer y or n.\n' ;;
    esac
  done
}

step() {
  local n="$1" title="$2" pct=$(( (n - 1) * 100 / TOTAL_STEPS ))
  local filled=$(( pct * 30 / 100 )) bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '=')"
  bar+=$(printf '%*s' "$((30-filled))" '' | tr ' ' '-')
  printf '\n[%s] %3d%%  STEP %d/%d: %s\n' "$bar" "$pct" "$n" "$TOTAL_STEPS" "$title"
}

require_commands() {
  local cmd
  for cmd in curl tar sha256sum systemctl awk grep sed find install python3 tput tr du; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is missing."
  done
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
  [[ -d /run/systemd/system ]] || die "systemd is not running; this wizard requires a systemd-based Ubuntu/Debian server."
}

find_install_dir() {
  local exec_start candidate
  exec_start="$(systemctl show "$SERVICE" -p ExecStart --value 2>/dev/null || true)"
  candidate="$(printf '%s' "$exec_start" | grep -oE '/[^ ;]+/mattermost(/bin/mattermost)?' | head -n1 || true)"
  if [[ "$candidate" == */bin/mattermost ]]; then
    candidate="${candidate%/bin/mattermost}"
  fi
  if [[ -n "$candidate" && -x "$candidate/bin/mattermost" && -f "$candidate/config/config.json" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  local dir
  for dir in /opt/mattermost /srv/mattermost /usr/local/mattermost; do
    if [[ -x "$dir/bin/mattermost" && -f "$dir/config/config.json" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

detect_version() {
  local output candidate
  output="$("$INSTALL_DIR/bin/mattermost" version 2>&1 || true)"
  candidate="$(printf '%s\n' "$output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
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
  printf '%s\n' "$output" | head -n3
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

download_progress() {
  local url="$1" dest="$2"
  # curl provides a real transfer progress bar.
  curl --fail --location --show-error --progress-bar \
    --retry 2 --connect-timeout 20 --max-time 900 \
    --user-agent "$USER_AGENT" "$url" --output "$dest"
  printf '\n'
}

get_official_checksum() {
  local filename="$1" page checksum
  page="$WORK_DIR/version-archive.html"
  curl --fail --location --silent --show-error --retry 2 \
    --user-agent "$USER_AGENT" "$ARCHIVE_PAGE" --output "$page" ||
    die "Could not read the official Mattermost version archive to verify the download."
  checksum="$(python3 - "$page" "$filename" <<'PYCODE'
import html, re, sys
from pathlib import Path
page = html.unescape(Path(sys.argv[1]).read_text(errors='replace'))
filename = sys.argv[2]
pos = page.find(filename)
if pos < 0:
    raise SystemExit(1)
region = page[max(0, pos-5000):pos+10000]
for pattern in (r'(?is)SHA[- ]?256.{0,500}?([0-9a-f]{64})',
                r'(?is)([0-9a-f]{64}).{0,500}?SHA[- ]?256'):
    match = re.search(pattern, region)
    if match:
        print(match.group(1).lower())
        raise SystemExit(0)
raise SystemExit(1)
PYCODE
  )" || true
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] ||
    die "Could not find an official SHA-256 checksum for $filename. Refusing an unverified download."
  printf '%s' "$checksum"
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

make_backup() {
  local default_path
  default_path="/var/backups/mattermost-before-team-${VERSION}-$(date +%Y%m%d-%H%M%S).tar.gz"
  read -r -p "Backup path [$default_path]: " BACKUP_FILE || true
  BACKUP_FILE="${BACKUP_FILE:-$default_path}"
  mkdir -p -- "$(dirname -- "$BACKUP_FILE")"

  local paths=()
  local rel
  for rel in config/config.json data logs plugins client/plugins; do
    [[ -e "$INSTALL_DIR/$rel" ]] && paths+=("$rel")
  done
  ((${#paths[@]} > 0)) || die "No recognized persistent paths found; stopping before migration."
  tar -czf "$BACKUP_FILE" -C "$INSTALL_DIR" "${paths[@]}" ||
    die "Backup failed. Migration stopped before changing application files."
  chmod 600 "$BACKUP_FILE"
  printf 'Backup created: %s (%s)\n' "$BACKUP_FILE" "$(du -h "$BACKUP_FILE" | awk '{print $1}')"
  warn "Database contents are NOT included in this backup."
}

replace_application_files() {
  local source="$1" child name saved_client_plugins=""
  # Keep client/plugins, but refresh the rest of client from the matching Team Edition archive.
  if [[ -d "$INSTALL_DIR/client/plugins" ]]; then
    saved_client_plugins="$WORK_DIR/client-plugins-preserved"
    mkdir -p "$saved_client_plugins"
    cp -a "$INSTALL_DIR/client/plugins" "$saved_client_plugins/plugins"
  fi
  local -a preserved=(config data logs plugins)
  shopt -s dotglob nullglob
  for child in "$INSTALL_DIR"/*; do
    name="${child##*/}"
    if printf '%s\n' "${preserved[@]}" | grep -Fxq "$name"; then continue; fi
    rm -rf -- "$child"
  done
  for child in "$source"/*; do
    name="${child##*/}"
    if printf '%s\n' "${preserved[@]}" | grep -Fxq "$name"; then continue; fi
    cp -a -- "$child" "$INSTALL_DIR/"
  done
  if [[ -n "$saved_client_plugins" ]]; then
    mkdir -p "$INSTALL_DIR/client"
    rm -rf -- "$INSTALL_DIR/client/plugins"
    cp -a "$saved_client_plugins/plugins" "$INSTALL_DIR/client/plugins"
  fi
  shopt -u dotglob nullglob
}

restore_app_ownership() {
  local owner_group uid gid rel
  owner_group="$(stat -c '%U:%G' "$INSTALL_DIR")"
  # Use the existing service account if it exists; do not create/change accounts automatically.
  if id mattermost >/dev/null 2>&1; then
    chown -R mattermost:mattermost "$INSTALL_DIR/bin" "$INSTALL_DIR/fonts" \
      "$INSTALL_DIR/i18n" "$INSTALL_DIR/templates" "$INSTALL_DIR/web" \
      "$INSTALL_DIR/prepackaged_plugins" "$INSTALL_DIR/enterprise" 2>/dev/null || true
    chown -R mattermost:mattermost "$INSTALL_DIR/bin" 2>/dev/null || true
  else
    warn "No 'mattermost' account found. Existing install root owner is $owner_group; verify ownership manually."
  fi
  # Restore directory ownership on persistent data as the installation may rely on it.
  for rel in config data logs plugins client/plugins; do
    [[ -e "$INSTALL_DIR/$rel" ]] || continue
    if id mattermost >/dev/null 2>&1; then
      chown -R mattermost:mattermost "$INSTALL_DIR/$rel" 2>/dev/null || true
    fi
  done
}

self_test() {
  local safe unsafe
  safe=$'mattermost/\nmattermost/bin/mattermost\nmattermost/config/config.json\n'
  unsafe=$'mattermost/\nmattermost/../../etc/passwd\n'
  check_archive_paths "$safe" || { echo 'FAIL: safe archive rejected'; return 1; }
  if check_archive_paths "$unsafe"; then echo 'FAIL: path traversal accepted'; return 1; fi
  echo 'PASS: archive path validation (safe paths accepted; traversal rejected).'
  echo 'PASS: banner and wizard functions loaded.'
  echo 'NOTE: this does not perform a real Mattermost migration.'
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then self_test; return; fi
  if [[ "${1:-}" == "--banner-test" ]]; then
    show_banner
    printf 'Banner test content appears below the pinned header.\n'
    sleep 1
    return
  fi
  require_commands
  show_banner
  ask_yes_no "This wizard will modify the Mattermost installation. Continue?" no || {
    echo "Cancelled. No changes made."; exit 0;
  }

  step 1 "Detecting installation"
  INSTALL_DIR="$(find_install_dir)" || die "Could not locate Mattermost installation with config/config.json and bin/mattermost."
  detect_version
  detect_arch
  local state enabled filename url checksum archive extract listing
  state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  [[ "$state" == active ]] && SERVICE_WAS_ACTIVE=1
  [[ "$enabled" == enabled ]] && SERVICE_WAS_ENABLED=1
  printf 'Install path : %s\nVersion      : %s\nArchitecture : linux-%s\nService      : %s\n' "$INSTALL_DIR" "$VERSION" "$ARCH" "${state:-unknown}"

  step 2 "Resolving matching Team Edition release"
  filename="mattermost-team-${VERSION}-linux-${ARCH}.tar.gz"
  url="${RELEASE_BASE}/${VERSION}/${filename}"
  printf 'Target archive: %s\n' "$url"
  WORK_DIR="$(mktemp -d -t mattermost-migration.XXXXXXXX)"
  checksum="$(get_official_checksum "$filename")"
  printf 'Official SHA-256: %s\n' "$checksum"

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
  local actual
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$checksum" ]] || die "SHA-256 mismatch (expected $checksum, got $actual). No application files have been changed."
  echo "SHA-256 verified."

  step 6 "Validating and extracting archive"
  listing="$WORK_DIR/archive-list.txt"
  tar -tzf "$archive" > "$listing" || die "Downloaded archive is not a valid gzip tar archive."
  check_archive_paths "$(cat "$listing")"
  grep -Eq '^mattermost/bin/mattermost$' "$listing" || die "Archive is missing mattermost/bin/mattermost."
  extract="$WORK_DIR/extracted"
  mkdir -p "$extract"
  tar --no-same-owner -xzf "$archive" -C "$extract" ||
    die "Could not extract archive."
  [[ -x "$extract/mattermost/bin/mattermost" ]] || die "Extracted archive is missing the expected executable."

  ask_yes_no "Ready to stop Mattermost and replace application files?" no || {
    echo "Cancelled before service stop."; exit 0;
  }

  step 7 "Replacing application files"
  MIGRATION_STARTED=1
  if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
    systemctl stop "$SERVICE" || die "Could not stop Mattermost."
  fi

  # Preserve service unit and service account. Avoid package removal/purge here.
  if ! replace_application_files "$extract/mattermost"; then
    warn "Application file replacement failed. Attempting to restart the service."
    [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]] && systemctl start "$SERVICE" || true
    die "Replacement failed. Inspect $INSTALL_DIR and the optional backup before retrying."
  fi
  restore_app_ownership
  [[ -d "$INSTALL_DIR/client/plugins" ]] || mkdir -p "$INSTALL_DIR/client/plugins"

  step 8 "Starting and verifying Mattermost"
  systemctl daemon-reload || true
  if [[ "$SERVICE_WAS_ENABLED" -eq 1 ]]; then systemctl enable "$SERVICE" >/dev/null 2>&1 || true; fi
  systemctl start "$SERVICE" || {
    systemctl --no-pager --full status "$SERVICE" || true
    die "Mattermost failed to start. Check: journalctl -u mattermost -n 100 --no-pager"
  }

  local new_state
  sleep 3
  new_state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  if [[ "$new_state" != active ]]; then
    systemctl --no-pager --full status "$SERVICE" || true
    die "Service did not become active. Check: journalctl -u mattermost -n 100 --no-pager"
  fi

  printf '\nMigration file replacement completed.\n'
  printf 'Previous version: %s\nTarget edition: Team Edition %s\nService status: %s\n' "$VERSION" "$VERSION" "$new_state"
  [[ -n "$BACKUP_FILE" ]] && printf 'Backup: %s\n' "$BACKUP_FILE"
  printf '\nVerification checklist:\n'
  printf '  1. Confirm login and team/channel access in the web UI.\n'
  printf '  2. Test sending messages, file uploads, plugins, and integrations.\n'
  printf '  3. Inspect logs: sudo journalctl -u mattermost -n 100 --no-pager\n'
  printf '  4. Confirm the installed package and future upgrade method before removing anything.\n'
  printf '  5. The database was not backed up by this script.\n'
  printf '\nTemporary files will be removed automatically.\n'
}

main "$@"
