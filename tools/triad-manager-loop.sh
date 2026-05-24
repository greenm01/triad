#!/bin/sh
set -eu

triad_bin="${TRIAD_BIN:-$HOME/.local/bin/triad}"
exec "$triad_bin" supervise
