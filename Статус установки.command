#!/bin/bash
# Двойной щелчок в Finder: показывает, как идёт установка Steam и Machine Party. Ничего не меняет.
cd "$(dirname "$0")" || exit 1
exec bash ./steam-mac.sh watch 4108000
