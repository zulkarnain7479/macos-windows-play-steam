#!/bin/bash
# Двойной щелчок в Finder: ставит всё нужное, чтобы играть в Windows-игры из Steam на Mac.
cd "$(dirname "$0")" || exit 1
exec bash ./steam-mac.sh install
