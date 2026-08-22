How the images are built:

Each image is built automatically in the
[anyvm-org/blissos-builder](https://github.com/anyvm-org/blissos-builder)
repo's GitHub Actions: it downloads the official BlissOS (Android x86)
ISO, constructs a bootable disk image offline from the ISO's system
partition (no interactive installer is run), bakes in an ssh service,
verifies the result by booting it in QEMU, and exports the disk as a
compressed qcow2 image.

Upstream install media: the official BlissOS FOSS ISOs from
https://sourceforge.net/projects/blissos-x86/ (project site:
https://blissos.org/).
