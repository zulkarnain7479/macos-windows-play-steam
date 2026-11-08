#!/bin/bash
# Двойной щелчок в Finder: запускает Machine Party через Highball.
cd "$(dirname "$0")" || exit 1
exec bash ./steam-mac.sh play 4108000
