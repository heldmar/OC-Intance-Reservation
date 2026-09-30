#!/usr/bin/env bash
# oc-reserve.sh — keep trying to launch an Oracle Cloud instance until capacity appears.
# Generic: everything comes from a config file (see config.example.env).
#
# Usage: oc-reserve.sh [--config FILE] [--dry-run] [--status]
#   --dry-run  do every step except the actual launch (auth, image, network, limits)
#   --status   print state and exit
set -uo pipefail

CONFIG="${OC_RESERVE_CONFIG:-/etc/oc-reserve/config.env}"
DRY_RUN=0; STATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --status) STATUS=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[ -r "$CONFIG" ] || { echo "cannot read config: $CONFIG" >&2; exit 64; }
# shellcheck disable=SC1090
. "$CONFIG"

: "${OCI_CONFIG_FILE:?}" "${COMPARTMENT_ID:?}" "${REGIONS:?}" "${SHAPES:?}"
INSTANCE_NAME="${INSTANCE_NAME:-oc-instance}"
IMAGE_OS="${IMAGE_OS:-Canonical Ubuntu}"
IMAGE_OS_VERSION="${IMAGE_OS_VERSION:-24.04}"
BOOT_GB="${BOOT_GB:-50}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:?}"
SUBNET_NAME="${SUBNET_NAME:-}"          # reuse a public subnet by this name; empty = create one
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"            # optional
ENFORCE_FREE_TIER="${ENFORCE_FREE_TIER:-true}"
STOP_AFTER_SUCCESS="${STOP_AFTER_SUCCESS:-true}"
TIMER_UNIT="${TIMER_UNIT:-}"            # systemd timer to disable on success, if any
STATE_DIR="${STATE_DIR:-/var/lib/oc-reserve}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state"; LOG="$STATE_DIR/run.log"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export OCI_CLI_CONFIG_FILE="$OCI_CONFIG_FILE"

ts() { date '+%F %T'; }
log() { echo "$(ts) $*" | tee -a "$LOG" >&2; }
notify() { # title, body, priority
  [ -n "$NTFY_TOPIC" ] || return 0
  curl -fsS -m 15 -H "Title: $1" -H "Priority: ${3:-default}" -d "$2" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}
if [ "$STATUS" = 1 ]; then cat "$STATE_FILE" 2>/dev/null || echo "no state yet"; tail -5 "$LOG" 2>/dev/null; exit 0; fi
if grep -q '^done' "$STATE_FILE" 2>/dev/null; then log "already succeeded; nothing to do"; exit 0; fi

# single-run lock (mkdir is atomic; flock is not on macOS)
LOCK="$STATE_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- notifications: (1) first start, (2) daily summary 08:00 Pacific until success, (3) success ---
if [ "$DRY_RUN" = 0 ]; then
  if [ ! -f "$STATE_DIR/started" ]; then
    date -u +%FT%TZ > "$STATE_DIR/started"; echo 0 > "$STATE_DIR/attempts"
    notify "OC reserve started" "Watching for $INSTANCE_NAME ($SHAPES) in $REGIONS every ${INTERVAL_MINUTES:-?} min."
  fi
  la_date=$(TZ=America/Los_Angeles date +%F); la_hour=$(TZ=America/Los_Angeles date +%-H)
  if [ "$la_hour" -ge 8 ] && [ "$(cat "$STATE_DIR/last_daily" 2>/dev/null)" != "$la_date" ]; then
    echo "$la_date" > "$STATE_DIR/last_daily"
    notify "OC reserve daily" "$(cat "$STATE_DIR/attempts") tries so far since $(cut -dT -f1 "$STATE_DIR/started"); no instance yet."
  fi
fi

o() { oci "$@"; }
TENANCY=$(awk -F= '/^tenancy=/{print $2; exit}' "$OCI_CONFIG_FILE")
HOME_REGION=$(o iam region-subscription list --tenancy-id "$TENANCY" --query 'data[?"is-home-region"]|[0]."region-name"' --raw-output 2>/dev/null)
[ -n "$HOME_REGION" ] || { log "auth or API failure reading home region"; log "hint: check API key in $CONFIG"; exit 1; }

FREE_SHAPES_RE='^(VM\.Standard\.A1\.Flex|VM\.Standard\.E2\.1\.Micro)$'

classify() { # stderr text -> capacity|throttle|limit|auth|other
  if   grep -qiE 'out of (host )?capacity' <<<"$1"; then echo capacity
  elif grep -qiE 'TooManyRequests|"status": *429' <<<"$1"; then echo throttle
  elif grep -qiE 'LimitExceeded|QuotaExceeded' <<<"$1"; then echo limit
  elif grep -qiE 'NotAuthenticated|NotAuthorized|"status": *40[13]' <<<"$1"; then echo auth
  else echo other; fi
}

existing_instance() { # region -> id of live instance with our name, if any
  o compute instance list -c "$COMPARTMENT_ID" --region "$1" --display-name "$INSTANCE_NAME" --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`]|[0].id' --raw-output 2>/dev/null
}

ensure_subnet() { # region -> subnet id (reuse or create)
  local r="$1" sn vcn
  if [ -n "$SUBNET_NAME" ]; then
    sn=$(o network subnet list -c "$COMPARTMENT_ID" --region "$r" --all \
      --query "data[?\"display-name\"=='$SUBNET_NAME' && \"lifecycle-state\"=='AVAILABLE' && !\"prohibit-public-ip-on-vnic\"]|[0].id" --raw-output 2>/dev/null)
    [ -n "$sn" ] && { echo "$sn"; return 0; }
  fi
  [ "$DRY_RUN" = 1 ] && { echo "DRYRUN-WOULD-CREATE-NETWORK"; return 0; }
  log "[$r] creating VCN/subnet"
  vcn=$(o network vcn create -c "$COMPARTMENT_ID" --region "$r" --cidr-block 10.0.0.0/16 --display-name "${INSTANCE_NAME}-vcn" --query 'data.id' --raw-output) || return 1
  local igw rt sl
  igw=$(o network internet-gateway create -c "$COMPARTMENT_ID" --region "$r" --vcn-id "$vcn" --is-enabled true --query 'data.id' --raw-output) || return 1
  rt=$(o network route-table list -c "$COMPARTMENT_ID" --region "$r" --vcn-id "$vcn" --query 'data[0].id' --raw-output)
  o network route-table update --rt-id "$rt" --region "$r" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" >/dev/null || return 1
  sl=$(o network security-list list -c "$COMPARTMENT_ID" --region "$r" --vcn-id "$vcn" --query 'data[0].id' --raw-output)
  o network security-list update --security-list-id "$sl" --region "$r" --force \
    --ingress-security-rules '[{"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},{"protocol":"1","source":"0.0.0.0/0"}]' >/dev/null || return 1
  o network subnet create -c "$COMPARTMENT_ID" --region "$r" --vcn-id "$vcn" --cidr-block 10.0.0.0/24 \
    --display-name "${SUBNET_NAME:-${INSTANCE_NAME}-subnet}" --query 'data.id' --raw-output
}

try_launch() { # region ad shape ocpus mem subnet image -> 0 ok / 1 capacity-like / 2 fatal / 3 throttle
  local r="$1" ad="$2" shape="$3" ocpus="$4" mem="$5" sn="$6" img="$7" out rc cls
  if [ "$DRY_RUN" = 1 ]; then log "[$r][$ad] DRY-RUN would launch $shape ${ocpus:+$ocpus OCPU / $mem GB }image=${img:0:30}… subnet=${sn:0:30}…"; return 1; fi
  echo $(( $(cat "$STATE_DIR/attempts" 2>/dev/null || echo 0) + 1 )) > "$STATE_DIR/attempts"
  local args=(compute instance launch --region "$r" -c "$COMPARTMENT_ID" --availability-domain "$ad"
    --shape "$shape" --image-id "$img" --subnet-id "$sn" --assign-public-ip true
    --display-name "$INSTANCE_NAME" --boot-volume-size-in-gbs "$BOOT_GB"
    --ssh-authorized-keys-file "$SSH_PUBKEY_FILE")
  [ -n "$ocpus" ] && args+=(--shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$mem}")
  out=$(o --no-retry --connection-timeout 10 --read-timeout 60 "${args[@]}" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    local id; id=$(jq -r '.data.id' <<<"$out" 2>/dev/null)
    echo "done $(ts) region=$r ad=$ad shape=$shape id=$id" > "$STATE_FILE"
    log "SUCCESS [$r][$ad] $shape id=$id"
    notify "OC instance CREATED" "$INSTANCE_NAME ($shape) created in $r after $(cat "$STATE_DIR/attempts" 2>/dev/null || echo 0) tries. Public IP appears in the console in ~1 min." urgent
    return 0
  fi
  cls=$(classify "$out"); log "[$r][$ad] $shape -> $cls"
  case "$cls" in
    capacity) return 1 ;;
    throttle) return 3 ;;
    limit) log "quota/limit refusal: $(head -c 300 <<<"$out" | tr '\n' ' ')"; return 1 ;;
    auth) return 2 ;;
    *) log "$(head -c 400 <<<"$out" | tr '\n' ' ')"; return 1 ;;
  esac
}

finish_success() {
  [ "$STOP_AFTER_SUCCESS" = true ] && [ -n "$TIMER_UNIT" ] && {
    systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || sudo -n systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1  \
      || log "could not disable $TIMER_UNIT; disable it manually"
  }
}

IFS=',' read -ra REGION_LIST <<<"$REGIONS"
IFS=',' read -ra SHAPE_LIST <<<"$SHAPES"     # each: shape:ocpus:memGB  (ocpus/mem empty for fixed shapes)
[ "$DRY_RUN" = 1 ] && log "DRY-RUN; home region=$HOME_REGION"

for r in "${REGION_LIST[@]}"; do
  r="${r// /}"
  if [ "$ENFORCE_FREE_TIER" = true ] && [ "$r" != "$HOME_REGION" ]; then
    log "[$r] skipped: Always Free compute must be created in the home region ($HOME_REGION); set ENFORCE_FREE_TIER=false to allow (may incur cost)"; continue
  fi
  ex=$(existing_instance "$r")
  if [ -n "$ex" ]; then
    log "[$r] instance '$INSTANCE_NAME' already exists ($ex) — marking done"
    echo "done $(ts) region=$r existing id=$ex" > "$STATE_FILE"; notify "OC instance CREATED" "$INSTANCE_NAME already exists in $r; nothing more to do." urgent; finish_success; exit 0
  fi
  sn=$(ensure_subnet "$r") || { log "[$r] network setup failed"; continue; }
  ads=$(o iam availability-domain list -c "$TENANCY" --region "$r" --query 'data[].name' 2>/dev/null | jq -r '.[]')
  for spec in "${SHAPE_LIST[@]}"; do
    IFS=':' read -r shape ocpus mem <<<"$spec"
    if [ "$ENFORCE_FREE_TIER" = true ]; then
      [[ "$shape" =~ $FREE_SHAPES_RE ]] || { log "skip $shape: not an Always Free shape"; continue; }
      if [ "$shape" = VM.Standard.A1.Flex ] && awk -v o="${ocpus:-0}" -v m="${mem:-0}" 'BEGIN{exit !(o>2||m>12)}'; then
        log "skip $spec: Always Free A1 is 2 OCPU / 12 GB total"; continue; fi
      [ "$BOOT_GB" -le 200 ] || { log "BOOT_GB > 200 free allowance"; exit 64; }
    fi
    img=$(o compute image list -c "$COMPARTMENT_ID" --region "$r" --shape "$shape" --operating-system "$IMAGE_OS" \
      --operating-system-version "$IMAGE_OS_VERSION" --sort-by TIMECREATED --sort-order DESC --limit 1 \
      --query 'data[0].id' --raw-output 2>/dev/null)
    [ -n "$img" ] || { log "[$r] no image '$IMAGE_OS $IMAGE_OS_VERSION' for $shape"; continue; }
    for ad in $ads; do
      try_launch "$r" "$ad" "$shape" "$ocpus" "$mem" "$sn" "$img"; rc=$?
      case $rc in
        0) finish_success; exit 0 ;;
        2) exit 1 ;;
        3) log "throttled; backing off until next run"; exit 0 ;;
      esac
    done
  done
done
log "run complete: no capacity this round"
exit 0
