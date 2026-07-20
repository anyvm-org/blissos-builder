#!/bin/bash
# host-side enablessh hook -- runs after _gen_enablessh_local() has written
# the enablessh.local script. The image already has the build's public key
# baked into root's authorized_keys (see hooks/offline-construct.sh), so we
# connect over the slirp hostfwd port and push enablessh.local just to
# re-affirm permissions and re-append the key (both idempotent).
#
# Guest caveats (Android/toybox/mksh): enablessh.local's `openssl` line and
# its /etc/ssh/sshd_config edits fail there (no openssl binary; /etc is a
# read-only /system/etc symlink) -- harmless, the script is not `set -e` and
# dropbear takes its config from the command line in
# /system/etc/init/dropbear.rc anyway.
#
# When this hook runs, host_waitForLoginTag has already gated on a real ssh
# handshake, so this loop is mostly a belt-and-suspenders guard for the gap
# between the gate ssh and this one (e.g. the BlissOS first-boot self-reboot).

set -u

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=30
  -p "${VM_SSH_PORT}"
)

# build.py writes the serial log under build/ (exported as VM_WORKDIR);
# fall back to the repo root for a standalone hook run.
SERIAL_LOG="${VM_WORKDIR:+$VM_WORKDIR/}${VM_OS_NAME:-blissos}.serial.log"

_n=0
while ! timeout 60 ssh "${SSH_OPTS[@]}" "root@127.0.0.1" exit >/dev/null 2>&1; do
  if [ $((_n % 6)) -eq 0 ] && [ -f "$SERIAL_LOG" ]; then
    echo "--- serial log tail (iter $_n) ---"
    tail -c 8192 "$SERIAL_LOG" \
      | tr -d '\000\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\034\035\036\037' \
      | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' \
      | grep -av '^[[:space:]]*$' \
      | tail -10
    echo "--- end serial tail ---"
  fi
  echo "waiting for dropbear on 127.0.0.1:${VM_SSH_PORT} (iter $_n) ..."
  sleep 10
  _n=$((_n + 1))
  if [ "$_n" -gt 120 ]; then
    echo "dropbear did not come up in time, continuing anyway"
    break
  fi
done

echo "Pushing enablessh.local to root@127.0.0.1:${VM_SSH_PORT}"
timeout 120 ssh "${SSH_OPTS[@]}" "root@127.0.0.1" sh <enablessh.local || true

# give the guest a moment to settle
sleep 5
