#!/bin/bash -x

DO_ALL=0

ROOT_DIR=$(dirname $(readlink -f "$0"))
cd $ROOT_DIR
source config.sh

if [ "1" -ne "$(sudo sysctl -n net.ipv4.ip_forward)" ]; then
    echo "/etc/sysctl.conf:net.ipv4.ip_forward=1 must be set and reboot"
    exit 1
fi

mkdir -p pool
POOL=$ROOT_DIR/pool

sudo sysctl vm.swappiness=10

echo -e "\n###\n# mknet\n###\n"

function mknet() {
    cat <<- EOC > "bus.xml"
	<network>
	  <name>bus</name>
	  <forward mode='nat'>
	    <nat>
	      <port start='1024' end='65535'/>
	    </nat>
	  </forward>
	  <bridge name='bus' stp='on' delay='0'/>
	  <ip address='172.16.0.1' netmask='255.255.0.0'>
	    <dhcp>
	      <range start='172.16.0.1' end='172.16.255.254'/>
	      <host name='k8s-m1' ip="${IP4DOMAINS[k8s-m1]}"/>
	      <host name='k8s-w1' ip="${IP4DOMAINS[k8s-w1]}"/>
	      <host name='k8s-w2' ip="${IP4DOMAINS[k8s-w2]}"/>
	      <host name='k8s-w3' ip="${IP4DOMAINS[k8s-w3]}"/>
	    </dhcp>
	  </ip>
	</network>
	EOC
    virsh net-define bus.xml
    virsh net-start bus
}
if [ $DO_ALL -eq 1 ]; then
    mknet
fi    
virsh net-info bus

echo -e "\n###\n# mkseed\n###\n"

function mkseed () {
    local seed="seed-${1}"
    cat <<- EOC > ${seed}
	#cloud-config
	hostname: $1
	password: ubuntu
	chpasswd: { expire: False }
	ssh_pwauth: True
	ssh_authorized_keys:
	    - ${PUBKEY}
	EOC
    cloud-localds "${POOL}/${seed}.iso" ${seed}
    echo -e "$1: cloudinit: ${seed}.iso"
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        mkseed $domain
    done
fi

echo -e "\n###\n# mkimage\n###\n"

function mkimage () {
    cp "${POOL}/${ARCHIMAGE}" "${POOL}/${IMAGE}"
    qemu-img convert -O qcow2 "${POOL}/${IMAGE}"  "${POOL}/${1}.qcow2"
    qemu-img resize "${POOL}/${1}.qcow2" ${IMGSIZ[${1}]}
    qemu-img info "${POOL}/${1}.qcow2"
}
if [ $DO_ALL -eq 1 ]; then
    wget -nc q -O "${POOL}/${ARCHIMAGE}" "${ARCHURI}/${ARCHIMAGE}"
    for domain in ${DOMAINS[@]} ; do
        mkimage $domain
    done
fi

echo -e "\n###\n# mkdomain\n###\n"

function mkdomain () {
    cat <<- EOC > "${1}.xml"
	<domain type="$DOMAIN_TYPE">
	    <name>$1</name>
	    <memory>${MEMSIZ[${1}]}</memory>
	    <os>
	        <type>hvm</type>
	        <boot dev="hd"/>
	    </os>
	    <features>
	        <acpi/>
	    </features>
	    <vcpu>${VCPUS[${1}]}</vcpu>
	    <devices>
	        <disk type="file" device="disk">
	            <driver type="qcow2" cache="none"/>
	            <source file="${POOL}/${1}.qcow2"/>
	            <target dev="vda" bus="virtio"/>
	        </disk>
	        <disk type="file" device="cdrom">
	            <source file="${POOL}/seed-${1}.iso"/>
	            <target dev="vdb" bus="virtio"/>
	            <readonly/>
	        </disk>
	            <interface type="network">
	            <source network="bus"/>
	            <model type="e1000"/>
	            <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
	        </interface>
	        <console type='pty'>
	            <target type='serial' port='0'/>
	        </console>
	        <input type='mouse' bus='ps2'/>
	        <input type='keyboard' bus='ps2'/>
	        <graphics type='vnc' port='-1' autoport='yes' keymap='en-us'/>
	        <sound model='ich6'>
	        </sound>
	        <video>
	            <model type='vmvga' vram='9216' heads='1'/>
	            <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
	        </video>
	        <memballoon model='virtio'>
	            <address type='pci' domain='0x0000' bus='0x00' slot='0x0a' function='0x0'/>
	        </memballoon>
	        <channel type='unix'>
	            <source mode='bind' path="/var/lib/libvirt/qemu/channel/target/${1}.org.qemu.guest_agent.0"/>
	            <target type='virtio' name='org.qemu.guest_agent.0' state='connected'/>
	            <alias name='channel0'/>
	            <address type='virtio-serial' controller='0' bus='0' port='1'/>
	        </channel>
	    </devices>
	</domain>
	EOC
    virsh define ${1}.xml
    virsh start ${1}
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        mkdomain $domain
    done

    echo -e "\n###\n# NODES MUST BE RESTARTED MANUALLY AFTER THE FIRST BOOT, ONLY ONCE TIME\n###\n"
fi    
virsh list

echo -e "\n###\n# wait4ssh\n###\n"

function ip4domain () {
    if [ ! -z "${IP4DOMAINS[${1}]}" ]; then
        echo "${IP4DOMAINS[${1}]}"
    else
        local ETHERP="([0-9a-f]{2}:){5}([0-9a-f]{2})"
        local IPP="^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"
        local net=${2:-'default'}
        local mac=$(virsh domiflist $1 | grep $net | grep -o -E $ETHERP)

        local ipaddr=$(arp -en | grep $mac | grep -o -P $IPP)
        IP4DOMAINS[${1}]=$ipaddr
        echo $ipaddr
    fi
}

function pingssh () {
    local ipaddr=$(ip4domain $1 'bus')
    (echo >/dev/tcp/${ipaddr}/22) &>/dev/null && return 0 || return 1
}

function wait4ssh () {
    until pingssh $1; do
        echo "Waiting ${DELAY} seconds more for ssh..."
        sleep $DELAY
    done
}
for domain in ${DOMAINS[@]} ; do
    wait4ssh $domain
done

echo -e "\n###\n# provision_jumpstart\n###\n"

function provision_jumpstart () {
    sudo apt-get -y install --no-install-recommends ca-certificates ntp ntpdate uuid-runtime git make jq nmap curl ipcalc sshpass patch python-cmd2

    sudo mkdir -p /etc/openstack-helm
    sudo cp ~/.ssh/id_rsa /etc/openstack-helm/deploy-key.pem
    sudo chown $JUMPSTART_USER /etc/openstack-helm/deploy-key.pem
    sudo mkdir -p /opt
    sudo chown -R $JUMPSTART_USER: /opt

    for i in "${!array[@]}"
    do
    echo "key  : $i"
    echo "value: ${array[$i]}"
    done

    for repo in "${!REPOS[@]}" ; do
        git clone "https://git.openstack.org/openstack/${repo}.git" "/opt/${repo}"
        pushd "/opt/${repo}"
            git checkout "${REPOS[${repo}]}"
        popd
    done

    cat > /opt/openstack-helm-infra/tools/gate/devel/multinode-inventory.yaml <<EOF
all:
  children:
    primary:
      hosts:
        k8s-m1:
          ansible_port: 22
          ansible_host: ${IP4DOMAINS[k8s-m1]}
          ansible_user: ubuntu
          ansible_ssh_private_key_file: /etc/openstack-helm/deploy-key.pem
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
    nodes:
      hosts:
        k8s-w1:
          ansible_port: 22
          ansible_host: ${IP4DOMAINS[k8s-w1]}
          ansible_user: ubuntu
          ansible_ssh_private_key_file: /etc/openstack-helm/deploy-key.pem
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
        k8s-w2:
          ansible_port: 22
          ansible_host: ${IP4DOMAINS[k8s-w2]}
          ansible_user: ubuntu
          ansible_ssh_private_key_file: /etc/openstack-helm/deploy-key.pem
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
        k8s-w3:
          ansible_port: 22
          ansible_host: ${IP4DOMAINS[k8s-w3]}
          ansible_user: ubuntu
          ansible_ssh_private_key_file: /etc/openstack-helm/deploy-key.pem
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
EOF

    cat > /opt/openstack-helm-infra/tools/gate/devel/multinode-vars.yaml <<EOF
kubernetes_network_default_device: $NET_DEFAULT_INTERFACE
EOF

    sed -i  '/external_dns_nameservers:/a\      - 172.16.0.1' /opt/openstack-helm-infra/tools/images/kubeadm-aio/assets/opt/playbooks/vars.yaml
}
if [ $DO_ALL -eq 1 ]; then
    provision_jumpstart
fi

echo -e "\n###\n# provision_nodes\n###\n"

function remote() {
    local domain=$1
    local ipaddr=$(ip4domain $domain 'bus')
    local step=$2
    local remote_user=ubuntu

    echo "### $1: Doing ${step} on ${ipaddr}"
    until ssh ${SSH_OPTIONS[@]} ${remote_user}@${ipaddr} ${step}; do
        echo "### ssh to $ipaddr failed, retrying in $DELAY seconds..."
        sleep $DELAY
    done
}

function do_ulimit() {
    local addr=$(ip4domain $1 'bus')

    ssh ${SSH_OPTIONS[@]} ubuntu@${addr} <<- EOC
	sudo su -
	cat >>/etc/security/limits.conf <<EOF
	*	soft	nofile	${ULIMIT}
	*	hard	nofile	${ULIMIT}
	root	soft	nofile	${ULIMIT}
	root	hard	nofile	${ULIMIT}
	EOF
	cat >>/etc/pam.d/common-session <<EOF
	session required pam_limits.so
	EOF
	cat >>/etc/pam.d/common-session-noninteractive <<EOF
	session required pam_limits.so
	EOF
	cat >>/etc/systemd/system.conf <<EOF
	DefaultLimitNOFILE=${ULIMIT}
	EOF
	cat >>/etc/systemd/user.conf <<EOF
	DefaultLimitNOFILE=${ULIMIT}
	EOF
	EOC
}

function do_reboot () {
    sleep $DELAY
    virsh reboot $1 --mode=agent
    sleep $DELAY
    wait4ssh $1
}

function provision_node () {
    local domain=$1
    local addr=$(ip4domain $1 'bus')    
    local -a UPGRADE_STEPS=("sudo apt-get update 2>&1 >> apt.log"
                            "sudo apt-get -y install qemu-guest-agent"
                            "sudo apt-get -y dist-upgrade 2>&1 >> apt.log")

    local -a PROVISION_STEPS=("sudo apt-get -y install --no-install-recommends"`
                                `" ntp"`
                                `" ntpdate"`
                                `" curl"`
                                `" git"`
                                `" 2>&1 >> apt.log")  
    for step in "${UPGRADE_STEPS[@]}"; do remote $domain "$step" ; done
    do_ulimit $domain
    do_reboot $domain

    for step in "${PROVISION_STEPS[@]}" ; do remote $domain "$step" ; done
    ssh ${SSH_OPTIONS[@]} ubuntu@${addr} <<- EOC
	sudo su -
	echo "net.ipv4.ip_forward = 1" >>/etc/sysctl.conf
	EOC
    do_reboot $domain
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        provision_node $domain
    done
fi

echo -e "\n###\n# add_to_ssh_config\n###\n"

function add_to_ssh_config() {
    local domain=$1
    local ipaddr=$(ip4domain $1 'bus')
    local oldip=$(grep -w $domain -A 1 ${HOME}/.ssh/config | awk '/Hostname/ {print $2}')
    if [[ -z $oldip ]]
    then
        cat <<- EOC >> "${HOME}/.ssh/config"
	
	Host $domain
	     Hostname $ipaddr
	     user ubuntu
	     StrictHostKeyChecking no
	     UserKnownHostsFile /dev/null
	EOC
    else
        sed -i "s/${oldip}/${ipaddr}/g" "${HOME}/.ssh/config"
    fi
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        add_to_ssh_config $domain
    done
fi

echo -e "\n###\n# populate_ssh\n###\n"

function populate_ssh() {
    local target=$1
    local targetaddr

    targetaddr=$(ip4domain $target 'bus')
    sshpass -p 'ubuntu' ssh-copy-id ${SSH_OPTIONS[@]} "ubuntu@${targetaddr}"
    scp ${SSH_OPTIONS[@]} ~/.ssh/id_rsa "ubuntu@${targetaddr}:id_rsa"
    echo "### Setting up deploy key on ${target} ($targetaddr)"
	ssh ${SSH_OPTIONS[@]} ubuntu@${targetaddr} <<- EOC
		sudo mkdir -p /etc/openstack-helm
		sudo mv /home/ubuntu/id_rsa /etc/openstack-helm/deploy-key.pem
		sudo chown ubuntu /etc/openstack-helm/deploy-key.pem
		EOC
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        populate_ssh $domain
    done
fi

echo -e "\n###\n# syncrepos\n###\n"

function syncrepos () {
    local target=$1

    ssh ${SSH_OPTIONS[@]} ubuntu@${target} "sudo chown -R ubuntu: /opt"
    for repo in "${!REPOS[@]}" ; do
        rsync -azv -e "ssh  -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null -o LogLevel=error" --progress --delete /opt/${repo}/ ubuntu@${target}:/opt/${repo}
    done
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        syncrepos $domain
    done
fi

echo -e "\n###\n# base_snapshot\n###\n"

function make_snapshot() {
    local domain=$1
    local name=$2
    
    virsh shutdown $domain
    sleep $DELAY
    virsh snapshot-create-as --domain $domain --name $name
    virsh start $domain
}
if [ $DO_ALL -eq 1 ]; then
    for domain in ${DOMAINS[@]} ; do
        make_snapshot $domain base
    done
fi
for domain in ${DOMAINS[@]} ; do
    wait4ssh $domain
done

echo -e "\n###\n# run_playbooks\n###\n"

function run_playbooks() {
	export LC_ALL=C
	cd /opt/openstack-helm-infra
	make dev-deploy setup-host multinode
	make dev-deploy k8s multinode
}
run_playbooks
