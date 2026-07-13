#!/bin/sh
# Compile the PRODUCTION glide sources + this harness into a Mac CLI and run it.
# Zero-drift: the exact GlidePath/LangData/Trie/SpatialModel the keyboard ships.
set -e
cd "$(dirname "$0")"
swiftc -O \
  ../../keyboard/Engine/SpatialModel.swift \
  ../../keyboard/Engine/Trie.swift \
  ../../keyboard/Engine/LangData.swift \
  ../../keyboard/Engine/GlidePath.swift \
  main.swift -o /tmp/glide_eval
/tmp/glide_eval "$@"
