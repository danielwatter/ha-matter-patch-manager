#!/bin/sh
pgrep -f '^python3 /config/core_patches/status_bridge.py$' >/dev/null && exit 0
nohup python3 /config/core_patches/status_bridge.py \
  >> /config/core_patches/bridge.log 2>&1 </dev/null &
