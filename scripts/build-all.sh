#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for application in 'Barcode+Sequence' 'Barcode+Sequence+Barcode' 'Barcode+Sequence+Engraving' 'Engraving+Sequence' 'Engraving+Compare'; do
  "$repo_dir/scripts/build-app.sh" "$application" "$@"
done
