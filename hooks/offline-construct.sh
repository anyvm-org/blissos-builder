#!/bin/bash
# hooks/offline-construct.sh -- OFFLINE image construction for BlissOS
# (Android-x86). Run by hooks/host_installOpts.py AFTER the ISO-booted VM has
# been destroyed; the conf's VM_* vars are in the environment.
#
# Builds the installed disk deterministically on the host from the ISO
# contents, replicating what the installer's scripts/1-install produces for a
# BIOS install, and bakes a root dropbear sshd in. When build.py then boots the
# disk, the normal ssh flow works (host reaches the guest's :22 through the
# slirp hostfwd port on 127.0.0.1:$VM_SSH_PORT).
#
# Disk layout we create (matches the Android-x86 installer):
#   /dev/<part>1 (ext4, bootable):
#     /$ASRC/{kernel, initrd.img, system.img, data/}    ($ASRC = install dir)
#     /boot/grub/{grub.cfg, i386-pc/...}                (BIOS GRUB)
# Boot: grub loads /$ASRC/kernel with `SRC=/$ASRC`; the initrd then loop-mounts
#   /mnt/$ASRC/system.img and bind-mounts /mnt/$ASRC/data as /data.
#
# NOTE: we do NOT bake a Termux userland. BlissOS already ships Termux as a
# real pre-installed app (/data/app/.../com.termux-*); Android reaps any orphan
# files we drop under /data/data/com.termux at boot, and the real app installs
# its own bootstrap on first launch from the GUI.

set -e

osname="${VM_OS_NAME:-blissos}"
_dir="$(pwd)"
# build.py routes the working image + iso under build/ (exported as
# VM_WORKDIR); keep them absolute. Falls back to the repo root when unset.
_wd="${VM_WORKDIR:+$VM_WORKDIR/}"
_qcow="$_dir/${_wd}$osname.qcow2"
_iso="$_dir/${_wd}$osname.iso"
ASRC="blissos-${VM_RELEASE}"        # install dir / kdir; name is free but must be self-consistent
DROPBEAR_VER="2022.83"

NBD=/dev/nbd0
M_ISO=/mnt/anyvm_iso
M_TGT=/mnt/anyvm_tgt
M_SYS=/mnt/anyvm_sys
M_EFS=/mnt/anyvm_efs

_cleanup() {
  sudo umount "$M_EFS" 2>/dev/null || true
  sudo umount "$M_SYS" 2>/dev/null || true
  sudo umount "$M_TGT" 2>/dev/null || true
  sudo umount "$M_ISO" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$NBD" 2>/dev/null || true
}
trap _cleanup EXIT

###############################################################################
# 0. host build key (build.py regenerates the same key later if absent)
###############################################################################
if [ ! -e "$HOME/.ssh/id_rsa" ]; then ssh-keygen -f "$HOME/.ssh/id_rsa" -q -N ""; fi
HOST_PUB="$(cat "$HOME/.ssh/id_rsa.pub")"

###############################################################################
# 1. host tools (zstd/qemu-utils already come from build.py setup())
###############################################################################
sudo apt-get update
sudo apt-get install -y musl-tools wget bzip2 grub-pc-bin grub2-common \
                        e2fsprogs parted squashfs-tools erofs-utils

###############################################################################
# 2. cross-build a *fully static* dropbear (musl) + pre-generate keys (host-side)
#    musl-gcc defaults to PIE/dynamic, so force -static -no-pie and assert it.
###############################################################################
echo "=== blissos: building static dropbear $DROPBEAR_VER (musl) ==="
_work="$(mktemp -d)"
(
  cd "$_work"
  wget -q "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2"
  tar xjf "dropbear-${DROPBEAR_VER}.tar.bz2"
  cd "dropbear-${DROPBEAR_VER}"
  ./configure --disable-zlib --disable-pam CC=musl-gcc \
              CFLAGS="-Os -no-pie" LDFLAGS="-static -no-pie" >/dev/null
  make -j"$(nproc)" STATIC=1 LDFLAGS="-static -no-pie" \
       PROGRAMS="dropbear dropbearkey scp" >/dev/null
)
_db="$_work/dropbear-${DROPBEAR_VER}/dropbear"
_dbkey="$_work/dropbear-${DROPBEAR_VER}/dropbearkey"
_scp="$_work/dropbear-${DROPBEAR_VER}/scp"
file "$_db"
file "$_db" | grep -q "statically linked" || { echo "ERROR: dropbear is not static"; exit 1; }
# scp is baked into the guest as the RECEIVER side of the legacy scp protocol
# (the host runs `scp -O`, which executes `scp -t <dir>` on the guest via the
# login shell). Android/toybox ships no scp and dropbear has no sftp server,
# so without this binary no host->guest file copy works at all.
file "$_scp" | grep -q "statically linked" || { echo "ERROR: scp is not static"; exit 1; }
"$_dbkey" -t rsa     -f "$_work/dropbear_rsa_host_key"     >/dev/null 2>&1
"$_dbkey" -t ed25519 -f "$_work/dropbear_ed25519_host_key" >/dev/null 2>&1
ssh-keygen -t rsa -f "$_work/guest_id_rsa" -q -N ""        # the guest's own ~/.ssh key

###############################################################################
# 3. mount the ISO (read-only)
###############################################################################
sudo mkdir -p "$M_ISO" "$M_TGT" "$M_SYS" "$M_EFS"
mountpoint -q "$M_ISO" || sudo mount -o loop,ro "$_iso" "$M_ISO"
[ -e "$M_ISO/system.sfs" ] || [ -e "$M_ISO/system.efs" ] || [ -e "$M_ISO/system.img" ] || \
  { echo "ERROR: ISO has no system.sfs/system.efs/system.img"; exit 1; }

###############################################################################
# 4. partition + format the target qcow2 (one bootable ext4 primary)
#    (the blank 200G qcow2 was created by build.py createVM)
###############################################################################
echo "=== blissos: partitioning $osname.qcow2 ==="
sudo modprobe nbd max_part=16
sudo qemu-nbd --disconnect "$NBD" 2>/dev/null || true
sudo qemu-nbd --connect="$NBD" "$_qcow"
sudo parted -s "$NBD" mklabel msdos
sudo parted -s "$NBD" mkpart primary ext4 1MiB 100%
sudo parted -s "$NBD" set 1 boot on
sudo partprobe "$NBD"; sleep 2
sudo mkfs.ext4 -F -L BlissOS "${NBD}p1"
sudo mount "${NBD}p1" "$M_TGT"

###############################################################################
# 5. copy kernel/initrd and extract system.img out of the zstd squashfs.
#    (Host kernels often lack zstd squashfs (e.g. WSL), so use userspace
#    unsquashfs instead of mounting system.sfs.)
###############################################################################
echo "=== blissos: populating /$ASRC ==="
sudo mkdir -p "$M_TGT/$ASRC/data/dropbear/.ssh"
sudo cp "$M_ISO/kernel"     "$M_TGT/$ASRC/kernel"
sudo cp "$M_ISO/initrd.img" "$M_TGT/$ASRC/initrd.img"

# Materialize $ASRC/system.img from whatever wrapper the ISO ships:
#   * BlissOS 14/15 FOSS: system.sfs  = zstd SQUASHFS containing system.img
#   * BlissOS 16   FOSS: system.efs  = EROFS containing system.img
#   * some builds ship a plain system.img directly
# The initrd's init probes system.sfs, then system.efs, then falls back to
# loop-mounting a bare $SRC/system.img -- so placing the inner ext4 system.img
# alone on the target disk boots identically for every variant.
# Use userspace unsquashfs for squashfs (host kernels often lack zstd-squashfs,
# e.g. WSL). For erofs prefer a kernel mount (no double copy; Ubuntu runners
# ship the erofs module) and fall back to userspace fsck.erofs --extract.
_extract_erofs_systemimg() {
  _efs="$1"
  sudo modprobe erofs 2>/dev/null || true
  if sudo mount -o loop,ro -t erofs "$_efs" "$M_EFS" 2>/dev/null; then
    echo "erofs kernel mount OK; copying inner system.img..."
    sudo cp "$M_EFS/system.img" "$M_TGT/$ASRC/system.img"
    sudo umount "$M_EFS"
  else
    echo "no kernel erofs support; extracting with fsck.erofs (userspace)..."
    sudo mkdir -p "$M_TGT/$ASRC/efsx"
    sudo fsck.erofs "--extract=$M_TGT/$ASRC/efsx" "$_efs"
    sudo mv "$M_TGT/$ASRC/efsx/system.img" "$M_TGT/$ASRC/system.img"
    sudo rm -rf "$M_TGT/$ASRC/efsx" 2>/dev/null || true
  fi
}

if [ -e "$M_ISO/system.img" ]; then
  echo "ISO ships a plain system.img; copying..."
  sudo cp "$M_ISO/system.img" "$M_TGT/$ASRC/system.img"
elif [ -e "$M_ISO/system.efs" ]; then
  echo "system.efs type: $(file -b "$M_ISO/system.efs" 2>/dev/null || true)"
  _extract_erofs_systemimg "$M_ISO/system.efs"
else
  _sfs_type="$(file -b "$M_ISO/system.sfs" 2>/dev/null || true)"
  echo "system.sfs type: $_sfs_type"
  case "$_sfs_type" in
    *quashfs*)
      echo "extracting system.img from system.sfs (squashfs)..."
      sudo unsquashfs -f -d "$M_TGT/$ASRC" "$M_ISO/system.sfs" system.img
      ;;
    *EROFS*|*erofs*)
      _extract_erofs_systemimg "$M_ISO/system.sfs"
      ;;
    *)
      echo "ERROR: unrecognized system.sfs format: $_sfs_type"; exit 1
      ;;
  esac
fi
[ -e "$M_TGT/$ASRC/system.img" ] || { echo "ERROR: failed to extract system.img"; exit 1; }
file "$M_TGT/$ASRC/system.img" || true

# The bake below loop-mounts system.img READ-WRITE, so it must be ext4 (erofs
# is read-only by design). Fail loudly here instead of mysteriously at mount.
_simg_type="$(file -b "$M_TGT/$ASRC/system.img" 2>/dev/null || true)"
case "$_simg_type" in
  *ext4*|*ext2*|*ext3*) : ;;
  *) echo "ERROR: system.img is not ext4 ($_simg_type); the rw bake cannot proceed"; exit 1 ;;
esac

# Grow system.img so there is room to add the dropbear files.
sudo truncate -s +128M "$M_TGT/$ASRC/system.img"
sudo e2fsck -fy "$M_TGT/$ASRC/system.img" || true
sudo resize2fs "$M_TGT/$ASRC/system.img"

###############################################################################
# 6. bake dropbear + init services + passwd into system.img
###############################################################################
echo "=== blissos: baking dropbear into system.img ==="
sudo mount -o loop,rw "$M_TGT/$ASRC/system.img" "$M_SYS"
if   [ -d "$M_SYS/system/bin" ]; then R="$M_SYS/system"
elif [ -d "$M_SYS/bin" ];        then R="$M_SYS"
else R="$(dirname "$(sudo find "$M_SYS" -maxdepth 3 -type d -name bin | head -1)")"; fi
echo "system root inside image: $R"

sudo install -m 0755 "$_db" "$R/bin/dropbear"
sudo install -m 0755 "$_scp" "$R/bin/scp"

# /etc is a symlink to /system/etc on Android-x86; musl dropbear reads /etc/passwd.
# Root HOME is on the WRITABLE /data (system.img is read-only at runtime, but
# build.py writes ~/.ssh/config in the guest), so HOME points at /data/dropbear;
# login shell is Android's mksh.
printf 'root:x:0:0:root:/data/dropbear:/system/bin/sh\n' | sudo tee "$R/etc/passwd" >/dev/null
# dropbear validates the login shell via getusershell()/etc/shells; Android ships
# no /etc/shells, so /system/bin/sh would count as an "invalid shell" and dropbear
# rejects the user BEFORE the pubkey check ("User 'root' has invalid shell").
# Listing the shell here is what makes root pubkey login actually work.
printf '/system/bin/sh\n/bin/sh\n' | sudo tee "$R/etc/shells" >/dev/null

sudo mkdir -p "$R/etc/init"
sudo tee "$R/etc/init/dropbear.rc" >/dev/null <<'RC'
service dropbear /system/bin/dropbear -F -E -s -p 22 -r /data/dropbear/dropbear_rsa_host_key -r /data/dropbear/dropbear_ed25519_host_key
    class main
    user root
    group root shell inet net_admin
    oneshot

on post-fs-data
    start dropbear

on property:sys.boot_completed=1
    start dropbear
RC

# Keep the GUI visible over VNC: Android blanks the display after the screen-off
# timeout (this is what makes the VNC console go black after ~1 min idle and
# looks like a crash). Disable the timeout + stay-on once system_server is up.
# Runs as root (settings/svc need a system caller; SELinux is permissive here).
sudo tee "$R/etc/init/anyvm-stayawake.rc" >/dev/null <<'RC'
on property:sys.boot_completed=1
    exec_background - root root -- /system/bin/sh -c "settings put system screen_off_timeout 2147483647; settings put secure sleep_timeout 2147483647; svc power stayon true"
RC

# enable adbd-over-tcp at boot as a convenience / debug channel
_bp="$(sudo find "$M_SYS" -maxdepth 3 -name build.prop | head -1)"
if [ -n "$_bp" ]; then
  printf '\nservice.adb.tcp.port=5555\npersist.adb.tcp.port=5555\nro.adb.secure=0\n' | sudo tee -a "$_bp" >/dev/null
fi
# sync ONLY this ext4 (system.img loop), not a global `sync`: a bare sync() also
# flushes every other mount (on WSL the /mnt/* drvfs 9p mounts) and can wedge
# for minutes in request_wait_answer. `sync -f <path>` = syncfs() of just that
# fs. umount below flushes it again anyway.
sync -f "$M_SYS" 2>/dev/null || sync
sudo umount "$M_SYS"

###############################################################################
# 7. dropbear host keys + root authorized_keys + guest key into /data
#    (writable at runtime: init bind-mounts /$ASRC/data as /data)
###############################################################################
sudo cp "$_work/dropbear_rsa_host_key"     "$M_TGT/$ASRC/data/dropbear/dropbear_rsa_host_key"
sudo cp "$_work/dropbear_ed25519_host_key" "$M_TGT/$ASRC/data/dropbear/dropbear_ed25519_host_key"
printf '%s\n' "$HOST_PUB"             | sudo tee "$M_TGT/$ASRC/data/dropbear/.ssh/authorized_keys" >/dev/null
sudo cp "$_work/guest_id_rsa"     "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa"
sudo cp "$_work/guest_id_rsa.pub" "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa.pub"
sudo chmod 700 "$M_TGT/$ASRC/data/dropbear/.ssh"
sudo chmod 600 "$M_TGT/$ASRC/data/dropbear/.ssh/authorized_keys" "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa"

###############################################################################
# 8. install GRUB (BIOS) and write a minimal grub.cfg with our cmdline
###############################################################################
echo "=== blissos: installing GRUB (i386-pc) ==="
sudo grub-install --target=i386-pc --boot-directory="$M_TGT/boot" \
  --modules="part_msdos ext2 normal linux search configfile echo" "$NBD"

# GUI note: do NOT pass `nomodeset` -- it disables KMS so the bochs-drm (std
# VGA, see VM_VGA in the conf) framebuffer never comes up and the VNC console
# stays black. With KMS on + `HWACCEL=0` (software GLES) BlissOS renders its
# full desktop to VNC at 1280x800 (verified by screenshot + dumpsys:
# surfaceflinger / systemui / launcher3 running, mWakefulness=Awake). `quiet`
# is also dropped so early boot text is visible. Headless root-ssh is
# unaffected (the GUI is additive).
sudo tee "$M_TGT/boot/grub/grub.cfg" >/dev/null <<CFG
set timeout=2
set default=0
menuentry "BlissOS ${VM_RELEASE}" {
    search --no-floppy --set=root -f /$ASRC/kernel
    linux /$ASRC/kernel root=/dev/ram0 SRC=/$ASRC androidboot.selinux=permissive HWACCEL=0
    initrd /$ASRC/initrd.img
}
CFG

echo "----- grub.cfg -----"; sudo cat "$M_TGT/boot/grub/grub.cfg"
echo "----- target tree -----"; sudo ls -lah "$M_TGT/$ASRC"

###############################################################################
# 9. unmount everything (trap also covers failures)
###############################################################################
# targeted syncfs (see note above) -- never a bare global `sync`
sync -f "$M_TGT" 2>/dev/null || sync
sudo umount "$M_TGT"
sudo umount "$M_ISO"
sudo qemu-nbd --disconnect "$NBD"
trap - EXIT
rm -rf "$_work" 2>/dev/null || true
sudo chmod 0666 "$_qcow" 2>/dev/null || true
echo "=== blissos: offline disk construction finished ==="
