#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLOUD" == 'maas' ]] ; then
    "$my_dir/create_workers_openlab.sh"
else
    "$my_dir/create_workers_slave.sh"
fi
