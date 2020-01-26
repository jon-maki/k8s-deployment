#!/bin/sh

cleanup() {
    rm images.txt images.tar
    exit
}
trap cleanup INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "$0" )" >/dev/null 2>&1 && pwd )"
BINS_DIR="$SCRIPT_DIR/bin"

# Generate images.txt
{
    "$BINS_DIR"/rke config -s | awk '!/Generating images list/'

    "$BINS_DIR"/kustomize build "$SCRIPT_DIR/deploy/kustomize/metallb/base" |
      awk '/image:/{gsub(/\s+image: /, "", $0); print }'

    "$BINS_DIR"/kustomize build "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/base" |
      awk '/image:/{gsub(/\s+image: /, "", $0); print }'

    "$BINS_DIR"/kustomize build "$SCRIPT_DIR/deploy/kustomize/traefik/base" |
      awk '/image:/{gsub(/\s+image: /, "", $0); print }'
} | sort -u >> images.txt

# Generate images.tar
xargs -n1 -P16 docker pull < images.txt
xargs docker save -o images.tar < images.txt

# Generate the release archive
archive_name=k8s-deployment-$(date +%d%b%Y | awk '{ print toupper($0) }')
{
    git ls-files | 
      awk '!/.gitignore/' |
      xargs printf "%s " images.txt images.tar |
      xargs tar cf - --transform "s/^/$archive_name\//" 
} | pigz >> "$archive_name.tgz
