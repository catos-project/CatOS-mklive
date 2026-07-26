#!/bin/sh
# The actual mkiso.sh invocation for test builds. Edit this file if the
# build command needs to change — not the workflow YAML — so it's one
# obvious place to check/update.
set -eu

sudo SPLASH_IMAGE="$SPLASH_IMAGE" ./mkiso.sh -b xfce -- \
    -T "CatOS (TEST BUILD)" \
    -I ./branding \
    -x /tmp/testing-watermark-postsetup.sh \
    -o catos-test.iso
