#!/bin/sh
# Prints: <gpu util %> <cpu temp C>
gpu=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
temp=$(sensors 2>/dev/null | awk '/Tctl/ {gsub(/[^0-9.]/, "", $2); print int($2); exit}')
echo "${gpu:-0} ${temp:-0}"
