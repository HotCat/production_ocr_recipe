#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/run-app.sh APP [arguments]' >&2
  exit 2
fi
application=$1
shift
case "$application" in
  Barcode+Sequence) config_name=sequence ;;
  Barcode+Sequence+Barcode) config_name=doublebarcode ;;
  Barcode+Sequence+Engraving) config_name=sequence2 ;;
  Engraving+Sequence) config_name=sequence3 ;;
  Engraving+Compare) config_name=engraving-compare ;;
  *) echo "Unknown application: $application" >&2; exit 2 ;;
esac
app_dir="$repo_dir/apps/$application"
if [ ! -x "$app_dir/bin/Camera" ]; then
  echo "Build first: scripts/build-app.sh '$application'" >&2
  exit 1
fi
config_dir="$HOME/ocrconfigs/$config_name"
mkdir -p "$config_dir"
for profile in fun my config1 config2 config3; do
  # noclobber also protects against another launcher creating a profile.
  if [ ! -e "$config_dir/$profile.scm" ] && [ -f "$app_dir/src/$profile.scm" ]; then
    (set -C; cat "$app_dir/src/$profile.scm" > "$config_dir/$profile.scm")
  fi
done
export LD_LIBRARY_PATH="$repo_dir/build/native/fpp:$repo_dir/build/native/reconstruct${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$app_dir"
exec ./bin/Camera "$@"
