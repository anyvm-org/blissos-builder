

[![Build](https://github.com/anyvm-org/blissos-builder/actions/workflows/build.yml/badge.svg)](https://github.com/anyvm-org/blissos-builder/actions/workflows/build.yml)

Latest: v2.0.3


The image builder for `blissos`


All the supported releases are here:



| Release (BlissOS) | Android | x86_64 (amd64) |
|---------|---------|---------|
| 16 | 13 | ✅ (scp,tar) |
| 15 | 12L | ✅ (scp,tar) |
| 14 | 11 | ✅ (scp,tar) |

<!-- release-label: Release (BlissOS) -->
<!-- arch-label: x86_64 = x86_64 (amd64) -->
<!-- extra-column: Android -->
<!-- extra-value: 16 13 -->
<!-- extra-value: 15 12L -->
<!-- extra-value: 14 11 -->

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




How to build:

1. Use the [manual.yml](.github/workflows/manual.yml) to build manually.
   
    Run the workflow manually, you will get a view-only webconsole from the output of the workflow, just open the link in your web browser.
   
    You will also get an interactive VNC connection port from the output, you can connect to the vm by any vnc client.

2. Run the builder locally on your Ubuntu machine.

    Just clone the repo. and run:
    ```bash
    python3 build.py conf/blissos-16.conf
    ```
   
