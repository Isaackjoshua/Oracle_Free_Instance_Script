#!/usr/bin/env bash
# Keeps asking Oracle for a free server until one is available, then stops.
# Usage: retry.sh [project-name]   (default: finplan)
# The server gets that name; each project has its own log and result file.
#
#   Start:   systemctl --user enable --now oracle-retry@<project>
#   Watch:   tail -f <this folder>/retry-<project>.log
#   Stop:    systemctl --user stop oracle-retry@<project>
set -u

export PATH="$HOME/.local/bin:$PATH" SUPPRESS_LABEL_WARNING=True
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:-finplan}"
if [[ ! "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo "bad project name: $NAME" >&2; exit 2; fi
if [ "$NAME" = finplan ]; then LOG="$DIR/retry.log"; else LOG="$DIR/retry-$NAME.log"; fi
RESULT="$DIR/instance-$NAME.json"

# Account-specific settings (TENANCY, AD, SUBNET, IMAGE_ARM, IMAGE_X86, SSH_KEY).
# Copy config.example.env to config.env and fill it in.
if [ ! -f "$DIR/config.env" ]; then echo "missing $DIR/config.env (see config.example.env)" >&2; exit 2; fi
# shellcheck source=/dev/null
. "$DIR/config.env"

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# Sends one "create server" request. Prints the raw answer from Oracle.
# --no-retry: Oracle's tool would otherwise retry silently for minutes; pacing is our job.
launch() {
  local shape=$1 image=$2
  shift 2
  oci compute instance launch --no-retry --connection-timeout 20 --read-timeout 60 \
    -c "$TENANCY" --availability-domain "$AD" --display-name "$NAME" \
    --shape "$shape" "$@" --image-id "$image" --subnet-id "$SUBNET" \
    --assign-public-ip true --ssh-authorized-keys-file "$SSH_KEY" 2>&1
}

# Turns Oracle's answer into one word:
#   created   a server now exists
#   capacity  no free machine right now (the normal case)
#   throttled Oracle says we are asking too often
#   limit     the account already holds its free allowance of this shape
#   network   could not reach Oracle (offline, laptop just woke up, timeout)
#   fatal     anything else: bad key, bad settings, something a retry cannot fix
classify() {
  local out=$1
  if grep -q '"lifecycle-state"' <<<"$out"; then echo created
  elif grep -qi 'out of host capacity\|out of capacity' <<<"$out"; then echo capacity
  elif grep -q '"status": 429\|TooManyRequests' <<<"$out"; then echo throttled
  elif grep -q 'LimitExceeded' <<<"$out"; then echo limit
  elif grep -qi 'timed out\|timeout\|connection\|RequestException\|"status": 50[234]' <<<"$out"; then echo network
  else echo fatal
  fi
}

# Decides what to do after a round in which no server was created.
#   $1  the worst outcome seen this round: capacity | throttled | network | limit | fatal
#   $2  how many rounds in a row have ended with that same outcome (1, 2, 3, ...)
# Print the number of seconds to wait before the next round, or the word "stop" to give up.
decide_wait() {
  local outcome=$1 streak=$2
  local wait
  case $outcome in
    # Normal case: ask again in 3 to 4 minutes. The random part keeps us off the same
    # second as other people's scripts.
    capacity) echo $((180 + RANDOM % 60)) ;;
    # Told to slow down: 10 minutes, then 20, 30... up to an hour.
    throttled)
      wait=$((streak * 600))
      echo $((wait > 3600 ? 3600 : wait))
      ;;
    # Probably Wi-Fi or a laptop that just woke up: short wait, never give up.
    network) echo 60 ;;
    # The account already has its free allowance: more requests cannot succeed.
    limit) echo stop ;;
    # Unknown problem: allow two repeats in case it was a one-off, then stop.
    fatal) if [ "$streak" -ge 3 ]; then echo stop; else echo 300; fi ;;
    *) echo stop ;;
  esac
}

rank() { case $1 in fatal) echo 5 ;; limit) echo 4 ;; throttled) echo 3 ;; network) echo 2 ;; *) echo 1 ;; esac; }

# This service starts again at every login. Once a server exists, do nothing.
if [ -s "$RESULT" ]; then
  log "a server was already created ($RESULT); nothing to do"
  exit 0
fi

# Which machines to ask for, in order. Each entry: "<shape> <image> [extra oci flags]".
# Free allowance: 2x E2.1.Micro in total (finplan already uses one),
# and A1.Flex up to 4 OCPU / 24 GB in total across all ARM servers.
ATTEMPTS=(
  "VM.Standard.A1.Flex $IMAGE_ARM --shape-config {\"ocpus\":2,\"memoryInGBs\":12}"
  "VM.Standard.E2.1.Micro $IMAGE_X86"
)

last="" streak=0
log "started ($NAME)"
while true; do
  worst=capacity
  for attempt in "${ATTEMPTS[@]}"; do
    # shellcheck disable=SC2086
    out=$(launch $attempt)
    outcome=$(classify "$out")
    shape=${attempt%% *}
    if [ "$outcome" = created ]; then
      echo "$out" >"$RESULT"
      log "CREATED $shape - details in $RESULT"
      notify-send -u critical "$NAME: Oracle server created" "$shape is starting up." 2>/dev/null || true
      exit 0
    fi
    log "$shape: $outcome"
    # Keep the server's own words only when the outcome is unexpected (never contains secrets).
    [ "$outcome" = fatal ] && log "  $(grep -m1 '"message"' <<<"$out" || head -c 300 <<<"$out")"
    [ "$(rank "$outcome")" -gt "$(rank "$worst")" ] && worst=$outcome
    sleep 5
  done

  if [ "$worst" = "$last" ]; then streak=$((streak + 1)); else streak=1; fi
  last=$worst
  wait=$(decide_wait "$worst" "$streak")
  if [ "$wait" = stop ]; then
    log "stopping after: $worst"
    notify-send -u critical "$NAME: Oracle retry stopped" "Reason: $worst. See $LOG" 2>/dev/null || true
    exit 1
  fi
  log "waiting ${wait}s"
  sleep "$wait"
done
