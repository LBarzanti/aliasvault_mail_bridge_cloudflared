#!/usr/bin/env bash
#
# test-setup.sh - automatic tests for the AliasVault + Cloudflare mail bridge.
#
# Usage:
#   sudo ./scripts/test-setup.sh               # tests 1-4 (see below)
#   sudo ./scripts/test-setup.sh --full-path   # + wait for a real email sent from outside
#   sudo ./scripts/test-setup.sh --retry       # + stop the bridge and check the Worker's retry
#   ./scripts/test-setup.sh --help
#
# Run it ON THE SERVER that runs the bridge. It needs root (or a user that can
# read the secret file, use journalctl and stop/start the service). The script
# first looks for WEBHOOK_SECRET in /etc/mail-bridge.env; if that file cannot be
# used, it asks for an alternative secret-file path.
#
# Tests (bottom-up, like the README):
#   1. AliasVault answers on its SMTP port (loopback)
#   2. The bridge accepts a message with the right secret (200) and
#      refuses one with a wrong secret (401)
#   3. Same two checks through the public tunnel hostname
#   4. A message to a NON-existing alias is refused permanently (422)
#   --full-path  5. A real email sent from another account arrives
#   --retry      6. A message received while the bridge is down is delivered later
#
# The script asks interactively for each configuration variable that is not
# already present in the environment. You can also pass values for one run, e.g.:
#   sudo DOMAIN=mydomain.org TEST_ALIAS=test SMTP_ADDR=127.0.0.1:2525 ./scripts/test-setup.sh
#
# Press Enter to accept the suggested reference value shown in brackets.
# For optional PUBLIC_URL, SERVICE and CONTAINER, enter '-' to leave the value
# empty and disable the related check. These variables can also be set in the
# environment (including explicitly setting them to an empty string).
# sudo note: `sudo VAR=value ./script` passes the variable on. `VAR=value sudo ./script` may not.

set -u -o pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
# Values supplied through environment variables take precedence. Any unset
# variable is requested interactively after command-line options are parsed.
# Set PUBLIC_URL, SERVICE or CONTAINER to an empty string to disable the
# related checks; at an interactive prompt, enter '-' for an empty value.
# The webhook secret is read from this file first. If the file is missing,
# unreadable, or does not contain WEBHOOK_SECRET, the script asks for another path.
SECRET_FILE="${SECRET_FILE:-/etc/mail-bridge.env}"

# Optional-test timeouts default to 180 and 720 seconds; override them through
# WAIT_FULL_PATH or WAIT_RETRY when needed.
WAIT_FULL_PATH="${WAIT_FULL_PATH:-180}"
WAIT_RETRY="${WAIT_RETRY:-720}"

# ---------------------------------------------------------------------------
# Implementation (nothing to change below this line)
# ---------------------------------------------------------------------------

MODE_FULL=0
MODE_RETRY=0
for arg in "$@"; do
  case "$arg" in
    --full-path) MODE_FULL=1 ;;
    --retry) MODE_RETRY=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_WARN=$'\e[33m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  C_OK=''; C_BAD=''; C_WARN=''; C_DIM=''; C_OFF=''
fi

PASSED=0; FAILED=0; SKIPPED=0
pass() { PASSED=$((PASSED + 1)); printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
fail() { FAILED=$((FAILED + 1)); printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %s[SKIP]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
section() { printf '\n%s\n' "$*"; }
die() { printf '%sERROR:%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 2; }

prompt_if_unset() {
  local name=$1 prompt=$2 suggestion=$3 optional=${4:-0} value

  # -v checks whether the variable exists, including variables set to an
  # intentional empty value (used by optional settings).
  if [[ ! -v "$name" ]]; then
    [[ -r /dev/tty ]] || die "$name is not set and no interactive terminal is available; export it before running the script"
    if [[ "$optional" -eq 1 ]]; then
      printf '%s [%s] (Enter to accept; enter - for empty): ' "$prompt" "$suggestion" > /dev/tty
    else
      printf '%s [%s]: ' "$prompt" "$suggestion" > /dev/tty
    fi
    IFS= read -r value < /dev/tty || die "could not read $name"

    # An empty answer accepts the reference suggestion. Optional values can
    # explicitly be cleared by entering a single dash.
    if [[ -z "$value" ]]; then
      value=$suggestion
    elif [[ "$optional" -eq 1 && "$value" == "-" ]]; then
      value=""
    fi
    printf -v "$name" '%s' "$value"
  fi
}

# Ask only for variables not supplied in the environment. Values in brackets
# are the original reference-setup values; press Enter to accept them.
prompt_if_unset DOMAIN      "Alias domain (replace the example with your own domain)" "example.com"
prompt_if_unset TEST_ALIAS "Existing AliasVault alias local-part" "test"
prompt_if_unset PUBLIC_URL "Public bridge URL" "https://inbound.example.com/" 1
prompt_if_unset SMTP_ADDR  "AliasVault SMTP address (host:port)" "127.0.0.1:2525"
prompt_if_unset BRIDGE_URL "Local bridge URL" "http://127.0.0.1:8087/"
prompt_if_unset SERVICE    "systemd service name" "mail-bridge" 1
prompt_if_unset CONTAINER  "AliasVault container name" "aliasvault" 1
[[ -n "$DOMAIN" ]] || die "DOMAIN cannot be empty"
[[ "$DOMAIN" != "example.com" ]] || die "DOMAIN is still the reference placeholder 'example.com'; enter your actual alias domain"
[[ -n "$TEST_ALIAS" ]] || die "TEST_ALIAS cannot be empty"
[[ -n "$SMTP_ADDR" ]] || die "SMTP_ADDR cannot be empty"
[[ -n "$BRIDGE_URL" ]] || die "BRIDGE_URL cannot be empty"
[[ "$WAIT_FULL_PATH" =~ ^[1-9][0-9]*$ ]] || die "WAIT_FULL_PATH must be a positive integer"
[[ "$WAIT_RETRY" =~ ^[1-9][0-9]*$ ]] || die "WAIT_RETRY must be a positive integer"

TMPDIR_TEST=$(mktemp -d) || die "cannot create a temporary directory"
RESTART_BRIDGE=0
cleanup() {
  # Never leave the bridge stopped if --retry was interrupted.
  if [[ $RESTART_BRIDGE -eq 1 && -n "$SERVICE" ]]; then
    echo "Restarting $SERVICE ..."
    systemctl start "$SERVICE" || echo "WARNING: could not restart $SERVICE, do it manually" >&2
  fi
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

# ---- pre-flight -------------------------------------------------------------

command -v wget >/dev/null 2>&1 || die "wget is required (install it with your package manager)"

SECRET=""
read_secret_file() {
  local file=$1
  [[ -r "$file" ]] || return 1
  SECRET=$(sed -n 's/^WEBHOOK_SECRET=//p' "$file")
  [[ -n "$SECRET" ]]
}

# Always try the expected file (or an explicitly configured SECRET_FILE) first.
# Ask for an alternative path only when that file cannot be used. WEBHOOK_SECRET
# from the process environment is deliberately not used as a substitute.
if ! read_secret_file "$SECRET_FILE"; then
  if [[ -r /dev/tty ]]; then
    printf 'Cannot read %s or find WEBHOOK_SECRET in it.\n' "$SECRET_FILE" > /dev/tty
    printf 'Alternative secret file path: ' > /dev/tty
    IFS= read -r SECRET_FILE < /dev/tty || die "could not read alternative SECRET_FILE path"
    [[ -n "$SECRET_FILE" ]] || die "SECRET_FILE path cannot be empty"
    read_secret_file "$SECRET_FILE" || die "cannot read WEBHOOK_SECRET from $SECRET_FILE"
  else
    die "cannot read WEBHOOK_SECRET from $SECRET_FILE; set SECRET_FILE to a readable file containing WEBHOOK_SECRET=..."
  fi
fi

HAVE_JOURNAL=0
if [[ -n "$SERVICE" ]] && command -v journalctl >/dev/null 2>&1; then HAVE_JOURNAL=1; fi

ADDR="${TEST_ALIAS}@${DOMAIN}"
RUN_ID="$(date +%H%M%S)-$RANDOM"
SMTP_HOST=${SMTP_ADDR%:*}
SMTP_PORT=${SMTP_ADDR##*:}

echo "AliasVault mail bridge - automatic tests"
echo "  alias under test : $ADDR"
echo "  AliasVault SMTP  : $SMTP_ADDR"
echo "  bridge (local)   : $BRIDGE_URL"
echo "  bridge (public)  : ${PUBLIC_URL:-<skipped>}"
echo "  systemd service  : ${SERVICE:-<not checked>}"
info "Tests 2 and 3 deliver real messages to $ADDR: it must already exist in AliasVault."

# ---- helpers ----------------------------------------------------------------

make_message() { # make_message <to> <subject> -> prints the file path
  local to=$1 subject=$2 f
  f=$(mktemp "$TMPDIR_TEST/msg.XXXXXX")
  {
    printf 'From: bridge-test@example.net\r\n'
    printf 'To: %s\r\n' "$to"
    printf 'Subject: %s\r\n' "$subject"
    printf 'Date: %s\r\n' "$(date -R)"
    printf 'Message-ID: <%s.%s@bridge-test.invalid>\r\n' "$RUN_ID" "$RANDOM"
    printf '\r\n'
    printf 'Automatic test message from test-setup.sh (run %s).\r\n' "$RUN_ID"
  } > "$f"
  printf '%s' "$f"
}

HTTP_STATUS=""
http_post() { # http_post <url> <secret> <rcpt> <file>   -> sets HTTP_STATUS
  local url=$1 secret=$2 rcpt=$3 file=$4 out
  out=$(wget -S -O /dev/null --tries=1 --timeout=60 \
    --header="Content-Type: message/rfc822" \
    --header="x-webhook-secret: ${secret}" \
    --header="x-mail-from: bridge-test@example.net" \
    --header="x-mail-to: ${rcpt}" \
    --post-file="$file" "$url" 2>&1)
  HTTP_STATUS=$(printf '%s\n' "$out" | grep -Eo 'HTTP/[0-9.]+ [0-9]{3}' | tail -n 1 | awk '{print $2}')
  HTTP_STATUS=${HTTP_STATUS:-none}
  if [[ "$HTTP_STATUS" == "none" ]]; then
    HTTP_ERR=$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')
  else
    HTTP_ERR=""
  fi
}

expect_status() { # expect_status <label> <expected> <hint-if-wrong>
  local label=$1 expected=$2 hint=$3
  if [[ "$HTTP_STATUS" == "$expected" ]]; then
    pass "$label -> HTTP $HTTP_STATUS"
  else
    fail "$label -> expected HTTP $expected, got $HTTP_STATUS"
    [[ -n "$HTTP_ERR" ]] && info "wget said: $HTTP_ERR"
    [[ -n "$hint" ]] && info "hint: $hint"
  fi
}

journal_has() { # journal_has <since "YYYY-MM-DD HH:MM:SS"> <pattern>
  journalctl -u "$SERVICE" --since "$1" -o cat --no-pager 2>/dev/null | grep -Fq -- "$2"
}

wait_for_delivery() { # wait_for_delivery <since> <timeout-seconds>
  local since=$1 timeout=$2 waited=0
  while (( waited < timeout )); do
    if journal_has "$since" "-> $ADDR"; then printf '\n'; return 0; fi
    sleep 5; waited=$((waited + 5))
    printf '.'
  done
  printf '\n'
  return 1
}

# ---- test 1: AliasVault SMTP --------------------------------------------------

section "1. AliasVault SMTP on $SMTP_ADDR"

if [[ -n "$SERVICE" ]] && command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet "$SERVICE"; then
    pass "service $SERVICE is active"
  else
    fail "service $SERVICE is not active" ; info "hint: sudo systemctl status $SERVICE ; journalctl -u $SERVICE -e"
  fi
else
  skip "service check (SERVICE empty or systemctl not available)"
fi

if [[ -n "$CONTAINER" ]] && command -v docker >/dev/null 2>&1; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]; then
    pass "container $CONTAINER is running"
  else
    fail "container $CONTAINER is not running (or has another name)"
    info "hint: docker compose ps ; set CONTAINER=<name> if it is called differently"
  fi
else
  skip "container check (CONTAINER empty or docker not available)"
fi

BANNER=$( { exec 3<>"/dev/tcp/${SMTP_HOST}/${SMTP_PORT}" && IFS= read -r -t 5 line <&3 && printf 'QUIT\r\n' >&3 && printf '%s' "$line"; } 2>/dev/null )
if [[ "$BANNER" == 220* ]]; then
  pass "SMTP banner received: ${BANNER%$'\r'}"
else
  fail "no 220 banner from $SMTP_ADDR"
  info "hint: compose must publish \"127.0.0.1:2525:25\" and SUPPORT_EMAIL must be \"true\"; check: ss -ltnp | grep ${SMTP_PORT}"
  info "      different port or address? set SMTP_ADDR=host:port"
fi

# ---- test 2: bridge, local --------------------------------------------------

section "2. Bridge, local endpoint ($BRIDGE_URL)"
SUBJECT_LOCAL="bridge-test local $RUN_ID"
MSG=$(make_message "$ADDR" "$SUBJECT_LOCAL")

http_post "$BRIDGE_URL" "$SECRET" "$ADDR" "$MSG"
expect_status "right secret, message to $ADDR" 200 \
  "401: the secret in $SECRET_FILE is not the one the running bridge loaded; 502: AliasVault not answering or temporary SMTP error; 422: alias '$TEST_ALIAS' does not exist in AliasVault or DOMAIN is not in PRIVATE_EMAIL_DOMAINS; none: nothing listens at BRIDGE_URL (check LISTEN in the unit, and BRIDGE_URL)"
LOCAL_OK=$([[ "$HTTP_STATUS" == "200" ]] && echo 1 || echo 0)

http_post "$BRIDGE_URL" "wrong-secret-$RUN_ID" "$ADDR" "$MSG"
expect_status "wrong secret" 401 "the bridge must refuse requests without the right secret"

# ---- test 3: bridge, public ---------------------------------------------------

section "3. Bridge, public endpoint through the tunnel"
if [[ -z "$PUBLIC_URL" || "$PUBLIC_URL" == *"inbound.example.com"* ]]; then
  skip "PUBLIC_URL is empty or still the reference placeholder"
else
  info "$PUBLIC_URL"
  SUBJECT_PUBLIC="bridge-test public $RUN_ID"
  MSG_PUB=$(make_message "$ADDR" "$SUBJECT_PUBLIC")
  http_post "$PUBLIC_URL" "$SECRET" "$ADDR" "$MSG_PUB"
  expect_status "right secret, message to $ADDR" 200 \
    "none/502/530: hostname not added to the tunnel, wrong port/service in the tunnel, cloudflared down, or LISTEN not reachable from cloudflared (cloudflared in Docker needs the LAN IP)"
  http_post "$PUBLIC_URL" "wrong-secret-$RUN_ID" "$ADDR" "$MSG_PUB"
  expect_status "wrong secret" 401 "a different status means the request did not reach the bridge"
fi

# ---- test 4: unknown alias ------------------------------------------------------

section "4. Unknown alias is refused permanently"
UNKNOWN="nonexistent-$RUN_ID@${DOMAIN}"
MSG_UNK=$(make_message "$UNKNOWN" "bridge-test unknown $RUN_ID")
http_post "$BRIDGE_URL" "$SECRET" "$UNKNOWN" "$MSG_UNK"
expect_status "message to $UNKNOWN" 422 \
  "200: AliasVault accepted an unknown address (check how it handles unknown aliases); 502: AliasVault unreachable or temporary error"

# ---- test 5: full path (optional) ---------------------------------------------

if [[ $MODE_FULL -eq 1 ]]; then
  section "5. Full path: a real email from outside"
  if [[ $HAVE_JOURNAL -eq 0 ]]; then
    skip "needs SERVICE and journalctl to watch the bridge log; check the AliasVault app by hand"
  else
    SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "  Send an email to $ADDR from ANOTHER mail account (not from this server) now."
    printf '  Waiting up to %ss ' "$WAIT_FULL_PATH"
    if wait_for_delivery "$SINCE" "$WAIT_FULL_PATH"; then
      pass "the bridge delivered a message for $ADDR (Cloudflare -> Worker -> tunnel -> bridge -> AliasVault)"
      info "Now check that it shows up in the AliasVault app."
    else
      fail "no delivery seen for $ADDR within ${WAIT_FULL_PATH}s"
      info "hint: Email Routing enabled? catch-all rule active and pointing at the Worker? INBOUND_URL and WEBHOOK_SECRET set in the Worker? See Worker logs in the Cloudflare dashboard."
    fi
  fi
fi

# ---- test 6: retry (optional) ---------------------------------------------------

if [[ $MODE_RETRY -eq 1 ]]; then
  section "6. Retry: message received while the bridge is down"
  if [[ $HAVE_JOURNAL -eq 0 ]]; then
    skip "needs SERVICE (systemd) and journalctl"
  elif [[ $LOCAL_OK -ne 1 ]]; then
    skip "the local bridge test failed: fix that first"
  else
    echo "  This stops $SERVICE, asks you to send a message, restarts it and waits for the retry."
    printf '  Continue? [y/N] '
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      skip "retry test cancelled"
    else
      RESTART_BRIDGE=1
      systemctl stop "$SERVICE" || die "cannot stop $SERVICE"
      info "$SERVICE stopped."
      echo "  Send an email to $ADDR from ANOTHER mail account now."
      echo "  The sender must NOT receive a bounce. Press Enter once you have sent it."
      read -r _
      sleep 10   # give the Worker time to make its first (failing) attempt
      SINCE=$(date '+%Y-%m-%d %H:%M:%S')
      systemctl start "$SERVICE" || die "cannot restart $SERVICE"
      RESTART_BRIDGE=0
      info "$SERVICE started again. The first retry happens after about 3 minutes."
      printf '  Waiting up to %ss ' "$WAIT_RETRY"
      if wait_for_delivery "$SINCE" "$WAIT_RETRY"; then
        pass "the queued message was delivered by a retry"
        info "Now check it in the AliasVault app, and that no 'incoming/' key is left in KV."
      else
        fail "no retry delivery within ${WAIT_RETRY}s"
        info "hint: check the Queues consumer and the Worker logs; was a message actually sent while the bridge was down?"
      fi
    fi
  fi
fi

# ---- summary ------------------------------------------------------------------

section "Summary: $PASSED passed, $FAILED failed, $SKIPPED skipped"
if [[ $FAILED -eq 0 ]]; then
  echo "Messages sent by this run have the subjects 'bridge-test local/public $RUN_ID'."
  echo "Check them in the AliasVault app (alias $ADDR): HTTP 200 proves AliasVault accepted them over SMTP."
  echo "Not covered by this script: the dead-letter queue test (needs a temporary redeploy of the Worker, see README)."
  exit 0
fi
exit 1
