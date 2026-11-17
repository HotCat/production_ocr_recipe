#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/build-app.sh APP [stack build options]' >&2
  exit 2
fi
application=$1
shift
case "$application" in
  Barcode+Sequence|Barcode+Sequence+Barcode|Barcode+Sequence+Engraving|Engraving+Sequence|Engraving+Compare) ;;
  *) echo "Unknown application: $application" >&2; exit 2 ;;
esac
cd "$repo_dir/apps/$application"
if [ -f stack.local.yaml ]; then
  stack --extra-lib-dirs "$repo_dir/build/native/fpp" --extra-lib-dirs "$repo_dir/build/native/reconstruct" --stack-yaml stack.local.yaml build Camera --copy-bins --local-bin-path bin "$@"
else
  stack --extra-lib-dirs "$repo_dir/build/native/fpp" --extra-lib-dirs "$repo_dir/build/native/reconstruct" build Camera --copy-bins --local-bin-path bin "$@"
fi
