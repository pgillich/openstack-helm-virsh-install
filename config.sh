ARCHURI="https://cloud-images.ubuntu.com/xenial/current"
ARCHIMAGE="xenial-server-cloudimg-amd64-disk1.img"
IMAGE="xenserv.img"
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null -o LogLevel=error)
PUBKEY=$(<${HOME}/.ssh/id_rsa.pub)
DOMAIN_TYPE='kvm'
DOMAINS=('k8s-m1' 'k8s-w1' 'k8s-w2' 'k8s-w3')
declare -A IMGSIZ=( ['k8s-m1']='32G' ['k8s-w1']='20G' ['k8s-w2']='20G' ['k8s-w3']='20G' )
declare -A MEMSIZ=( ['k8s-m1']='3145728' ['k8s-w1']='3145728' ['k8s-w2']='3145728' ['k8s-w3']='3145728' )
declare -A VCPUS=( ['k8s-m1']='2' ['k8s-w1']='2' ['k8s-w2']='2' ['k8s-w3']='2' )
ULIMIT=4096
DELAY=10
declare -A IP4DOMAINS=( ['k8s-m1']='172.16.1.1' ['k8s-w1']='172.16.4.1' ['k8s-w2']='172.16.5.1' ['k8s-w3']='172.16.6.1' )

declare -A REPOS=( ['openstack-helm']='f8adab245b3ee9c9e3767f6ff6127879a2bdfd3f' ['openstack-helm-infra']='abb5e0f713aa07b8c90cc5e593135ca338c5ff6f')
JUMPSTART_USER=$USER
NET_DEFAULT_INTERFACE=ens4
