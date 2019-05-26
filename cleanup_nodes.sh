#!/bin/bash -x

ROOT_DIR=$(dirname $(readlink -f "$0"))
cd $ROOT_DIR
source config.sh

for domain in ${DOMAINS[@]} ; do
    virsh destroy $domain
    virsh undefine $domain --remove-all-storage --delete-snapshots
done
rm -f bus.xml k8s-* seed-k8s-* pool/seed-k8s-* pool/*.qcow2 pool/xenserv.img

virsh net-destroy bus
virsh net-undefine bus