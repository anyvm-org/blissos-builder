#!/bin/bash
# host-side waitForLoginTag override (called from start_and_wait after
# startVM + openConsole, before the default waitForText fires).
#
# Android suppresses kernel printk once init takes over, so the serial console
# goes quiet and there is no "login:" tag to wait for; the VNC screen is a
# graphical boot animation that OCR cannot anchor on either. Since
# hooks/offline-construct.sh already baked a root dropbear (with the build
# key in authorized_keys) into the image, we poll the slirp hostfwd port on
# 127.0.0.1:$VM_SSH_PORT until the guest sshd actually answers.
#
# IMPORTANT: do NOT probe with a bare TCP connect (e.g. `echo > /dev/tcp/...`).
# slirp's `hostfwd` makes QEMU listen on the HOST port the moment it starts,
# completing the host-side 3-way handshake well before the guest kernel has
# even POSTed. A bare TCP probe therefore returns "open" immediately and we
# fall through to the real ssh phase against a guest that's nowhere near up.
# Probe with `ssh ... exit` so the test only succeeds when the GUEST dropbear
# actually answers.
#
# Note: BlissOS does a self-reboot during its very first boot; a probe window
# where the connection drops right after first contact is normal -- just keep
# polling.

set -u

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o BatchMode=yes
  -p "${VM_SSH_PORT}"
)

SERIAL_LOG="${VM_OS_NAME:-blissos}.serial.log"

_n=0
# 240 iters * (timeout 30 + sleep 10) = generous ceiling; under KVM the first
# boot (incl. the BlissOS self-reboot) answers within a few minutes. Under TCG
# (no /dev/kvm) Android is much slower -- the big ceiling covers that too.
while [ "$_n" -lt 240 ]; do
  if timeout 30 ssh "${SSH_OPTS[@]}" "root@127.0.0.1" exit >/dev/null 2>&1; then
    echo "dropbear is answering ssh on 127.0.0.1:${VM_SSH_PORT}"
    break
  fi
  # Every 6 iterations (~1 minute), dump the last lines of the guest serial
  # log. Android's console is mostly quiet after early boot, but the early
  # lines still show whether the kernel came up at all.
  if [ $((_n % 6)) -eq 0 ] && [ -f "$SERIAL_LOG" ]; then
    echo "--- serial log tail (iter $_n) ---"
    tail -c 8192 "$SERIAL_LOG" \
      | tr -d '\000\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\034\035\036\037' \
      | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' \
      | grep -av '^[[:space:]]*$' \
      | tail -10
    echo "--- end serial tail ---"
  fi
  echo "waiting for guest dropbear on 127.0.0.1:${VM_SSH_PORT} (iter $_n) ..."
  sleep 10
  _n=$((_n + 1))
done

sleep 5
