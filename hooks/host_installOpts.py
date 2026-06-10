# OFFLINE image construction driver for BlissOS (Android-x86).
#
# Host-side hook: run by base-builder/build.py via exec() in this module's
# globals, so destroyVM / closeConsole / log / env are available as bare names.
#
# The BlissOS graphical installer is too fragile to drive over VNC+OCR (the
# syslinux/vesamenu key injection and the eth0/GUI timing are unreliable). So
# instead of touching the ISO-booted VM at all, we kill it and build the
# installed disk deterministically on the host from the ISO contents, then bake
# a root dropbear sshd in -- see hooks/offline-construct.sh for the details.
# When build.py then boots the disk (start_and_wait), the stock ssh flow works
# through the slirp hostfwd port.

log("=== blissos: discarding the ISO-booted VM; building the disk offline ===")
destroyVM()
closeConsole()

_r = subprocess.run(["bash", "hooks/offline-construct.sh"], env=os.environ.copy())
if _r.returncode != 0:
    log("blissos: offline construction FAILED (rc=%d); aborting build" % _r.returncode)
    sys.exit(1)
log("=== blissos: offline image construction done; build.py will boot it ===")
