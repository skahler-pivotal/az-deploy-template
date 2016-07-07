#!/bin/bash

IPADDR=$1
HOSTNAME=$2
SEGMENTS=$3
APITOKEN=$4
SSHPRIVKEY=$5
IP_PREFIX=$6
SEGMENT_IP_BASE=$7

#Print what we received as arguements
echo "$0 $*"

# Enable IP<->hostname mapping
echo -e "\n${IPADDR} ${HOSTNAME}" | tee --append /etc/hosts

# Allow passwordless sudo
sed -i -e 's/ALL$/NOPASSWD: ALL/' /etc/sudoers.d/waagent

# Don't require TTY for sudo
sed -i -e 's/^Defaults    requiretty/#Defaults    requiretty/' /etc/sudoers

# Allow loopback SSH
ssh-keyscan ${HOSTNAME} | tee --append /etc/ssh/ssh_known_hosts

# Generate ssh folder/key with right permissions, then overwrite
ssh-keygen -P "" -f /root/.ssh/id_rsa
echo -e "${SSHPRIVKEY}" > /root/.ssh/id_rsa
rm -f /root/.ssh/id_rsa.pub

# Generate ssh folder/key with right permissions, then overwrite
su gpadmin -c 'ssh-keygen -P "" -f /home/gpadmin/.ssh/id_rsa'
echo -e "${SSHPRIVKEY}" > /home/gpadmin/.ssh/id_rsa
rm -f /home/gpadmin/.ssh/id_rsa.pub

# Make sure root has passwordless SSH as well
cp /home/gpadmin/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys

# Disable selinux
sed -ie "s|SELINUX=enforcing|SELINUX=disabled|" /etc/selinux/config
setenforce 0

# Set ulimits for gpadmin
cat >> /etc/security/limits.d/99-gpdb.conf <<EOF
## Greenplum Database Limits
gpadmin soft nofile 65536
gpadmin hard nofile 65536
gpadmin soft nproc 131072
gpadmin hard nproc 131072
EOF

# Install an configure fail2ban for the script kiddies
yum install epel-release -y
yum install fail2ban -y

cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

sed -ie "s|ignoreip = 127\.0\.0\.1/8|ignoreip = 127.0.0.1/8\nignoreip = ${IPADDR}/24|" /etc/fail2ban/jail.local

echo -e "\n\n
[ssh-iptables]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=ssh, protocol=tcp]
logpath  = /var/log/secure
maxretry = 5
" >> /etc/fail2ban/jail.local

service fail2ban start
chkconfig fail2ban on

yum install xfsprogs -y

if [[ "${HOSTNAME}" == *"mdw"* ]] ; then

    # Work out of the gpadmin home directory

    cd /home/gpadmin

    # Stage the GPDB tarball

    curl -o /home/gpadmin/greenplum-db.zip  -d "" -H "Authorization: Token ${APITOKEN}" -L https://network.pivotal.io/api/v2/products/pivotal-gpdb/releases/1683/product_files/4367/download

    unzip /home/gpadmin/greenplum-db.zip

    chown gpadmin:gpadmin /home/gpadmin/greenplum-db-*.bin
    chmod u+x /home/gpadmin/greenplum-db-*.bin

    sed -i 's/more <</cat <</g' /home/gpadmin/greenplum-db-*.bin
    sed -i 's/agreed=/agreed=1/' /home/gpadmin/greenplum-db-*.bin
    sed -i 's/pathVerification=/pathVerification=1/' /home/gpadmin/greenplum-db-*.bin
    sed -i '/defaultInstallPath=/a installPath=${defaultInstallPath}' /home/gpadmin/greenplum-db-*.bin

    for GPDBINSTALLBINARY in /home/gpadmin/greenplum-db-*.bin
    do
      sudo $GPDBINSTALLBINARY
    done

    # Stage the GPCC tarball

    curl -o /home/gpadmin/greenplum-cc-web.zip -d "" -H "Authorization: Token ${APITOKEN}" -L https://network.pivotal.io/api/v2/products/pivotal-gpdb/releases/1683/product_files/5097/download

    /usr/bin/unzip /home/gpadmin/greenplum-cc-web-*.zip

    chown gpadmin:gpadmin /home/gpadmin/greenplum-cc-web-*
    chmod u+x /home/gpadmin/greenplum-cc-web-*

    sed -i 's/more <</cat <</g' /home/gpadmin/greenplum-cc-web-*.bin
    sed -i 's/agreed=/agreed=1/' /home/gpadmin/greenplum-cc-web-*.bin
    sed -i 's/pathVerification=/pathVerification=1/' /home/gpadmin/greenplum-cc-web-*.bin
    sed -i '/defaultInstallPath=/a installPath=${defaultInstallPath}' /home/gpadmin/greenplum-cc-web-*.bin
    

    for GPCCINSTALLBINARY in /home/gpadmin/greenplum-cc-web-*.bin
    do
      sudo $GPDBINSTALLBINARY
    done

    sudo chown -R gpadmin:gpadmin /usr/local/greenplum*

    # Create a cluster deploy hostfiles
    python -c "print 'mdw' ; print '\n'.join(['sdw{0}'.format(n+1) for n in range(${SEGMENTS})])" > /home/gpadmin/hosts.all
    python -c "print '\n'.join(['sdw{0}'.format(n+1) for n in range(${SEGMENTS})])" > /home/gpadmin/hosts.segs

    chown gpadmin:gpadmin /home/gpadmin/hosts.*

    # Update system host file with segment hosts
    python -c "print '\n'.join(['10.4.0.{0} {1}'.format(ip, 'sdw{0}'.format(n+1)) for n, ip in enumerate(range(${SEGMENT_IP_BASE}, ${SEGMENT_IP_BASE} + ${SEGMENTS}))])" >> /etc/hosts

    # Partition the data disk
    echo -e "n\np\n1\n\n\nw\n" | fdisk /dev/sdc

    # Create the XFS filesystem
    mkfs.xfs /dev/sdc1

    # Add an entry to /etc/fstab
    echo -e "/dev/sdc1  /data  xfs rw,noatime,inode64,allocsize=16m  0 0" >> /etc/fstab

    # Create and mount master's data dir
    mkdir /data
    mount /data

    mkdir /data/master

    # Get some Anaconda stuff on master
    wget -O /tmp/Anaconda2-4.0.0-Linux-x86_64.sh http://repo.continuum.io/archive/Anaconda2-4.0.0-Linux-x86_64.sh

    sh /tmp/Anaconda2-4.0.0-Linux-x86_64.sh -b -p /opt/anaconda

    /opt/anaconda2/bin/conda install psycopg2
    pip install ipython-sql
    pip install azure

    chmod ugo+w /opt/anaconda/{,pkgs,conda-meta,lib/python2.7/site-packages}

else
    # Run the prep-segment.sh

    READAHEAD="/sbin/blockdev --setra 16384 /dev/sd[c-z]"

    FSTAB_HEAD="# BEGIN GENERATED CONTENT"
    FSTAB_TAIL="# END GENERATED CONTENT"

    if [[ -z $DRIVE_PATTERN ]]; then
      DRIVE_PATTERN='/dev/sd[c-z]'
    fi

    echo "$READAHEAD" >> /etc/rc.local

    export GLOBIGNORE="/dev/xvdf"
    DRIVES=($(ls $DRIVE_PATTERN))
    DRIVE_COUNT=${#DRIVES[@]}

    if [[ -z "${VOLUMES}" ]]; then
      if [[ $DRIVE_COUNT -lt 8 ]]; then
        VOLUMES=1
      elif [[ $DRIVE_COUNT -lt 12 ]]; then
        VOLUMES=2
      else
        VOLUMES=4
      fi
    fi

    if (( ${DRIVE_COUNT} % ${VOLUMES} != 0 )); then
      echo "Drive count (${DRIVE_COUNT}) not divisible by number of volumes (${VOLUMES}), using VOLUMES=1"
      VOLUMES=1
    fi

    FSTAB=()

    umount /dev/md[0-9]* || true

    umount ${DRIVES[*]} || true

    mdadm --stop /dev/md[0-9]* || true

    mdadm --zero-superblock ${DRIVES[*]}

    for VOLUME in $(seq $VOLUMES); do
      DPV=$(expr "$DRIVE_COUNT" "/" "$VOLUMES")
      DRIVE_SET=($(ls ${DRIVE_PATTERN} | head -n $(expr "$DPV" "*" "$VOLUME") | tail -n "$DPV"))

      mdadm --create /dev/md${VOLUME} --run --level 0 --chunk 256K --raid-devices=${#DRIVE_SET[@]} ${DRIVE_SET[*]}

      mkfs.xfs -K -f /dev/md${VOLUME}

      mkdir -p /data${VOLUME}

      FSTAB+="/dev/md${VOLUME}  /data${VOLUME}  xfs rw,noatime,inode64,allocsize=16m  0 0\n"
    done

    mdadm --detail --scan > /etc/mdadm.conf

    for DRIVE in ${DRIVES[*]}; do
      sed -i -r "s|^${DRIVE}.+$||" /etc/fstab
    done

    sed -i -e "/$FSTAB_HEAD/,/$FSTAB_TAIL/d" /etc/fstab
    echo "$FSTAB_HEAD" >> /etc/fstab
    echo -e "${FSTAB[@]}" >> /etc/fstab
    echo "$FSTAB_TAIL" >> /etc/fstab

    mount -a

    mkdir /data{1..$VOLUMES}/primary

fi

# Fix datadir ownership
chown -Rf gpadmin:gpadmin /data*

# Set kernel parameters

SYSCTL_HEAD="# BEGIN GENERATED CONTENT"
SYSCTL_TAIL="# END GENERATED CONTENT"
SYSCTL="$SYSCTL_HEAD
kernel.shmmax = 500000000
kernel.shmmni = 4096
kernel.shmall = 4000000000
kernel.sem = 250 512000 100 2048
kernel.sysrq = 1
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.msgmni = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_tw_recycle = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.arp_filter = 1
net.ipv4.ip_local_port_range = 1025 65535
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.core.netdev_max_backlog = 10000
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
vm.overcommit_memory = 2
vm.overcommit_ratio = 100
# Azure Networking Bits
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 10000000 10000000 10000000
net.ipv4.tcp_wmem = 10000000 10000000 10000000
net.ipv4.tcp_mem = 10000000 10000000 10000000
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.core.optmem_max = 134217728
$SYSCTL_TAIL"

KERNEL="elevator=none transparent_hugepage=never"

sed -i -e "/$SYSCTL_HEAD/,/$SYSCTL_TAIL/d" /etc/sysctl.conf
echo "$SYSCTL" >> /etc/sysctl.conf
echo "$SYSCTL" | /sbin/sysctl -p -

sed -i -r "s/kernel(.+)/kernel\1 $KERNEL/" /boot/grub/grub.conf
echo never > /sys/kernel/mm/transparent_hugepage/enabled
for BLOCKDEV in /sys/block/*/queue/scheduler; do
  echo none > "$BLOCKDEV"
done

# Disable strict host checking for cluster hosts
for h in `grep sdw /etc/hosts | cut -f2 -d ' '` ; do echo -e "\nHost ${h}\n  StrictHostKeyChecking no\n" | tee --append /etc/ssh/ssh_config ; done ;

# Push host file
for h in `grep sdw /etc/hosts | cut -f2 -d ' '` ; do scp /etc/hosts ${h}:/etc/ ; done ;

# Install Hyper-V Linux Integration Services
yum install microsoft-hyper-v -y

# Install iperf3 for benchmarking
yum install iperf3 -y

# Install repo for later GCC
yum install centos-release-scl -y

# Install GCC 4.9
yum install devtoolset-3-gcc -y

# Download repofile for Boost154, cpprest, ORC for Wasb2Orc
wget https://bintray.com/kdunn926/AzureLinux/rpm -O /etc/yum.repos.d/bintray-kdunn926-AzureLinux.repo
yum install protobuf boost orc cpprestsdk azurestoragecpp -y

easy_install pip

pip install azure

# Make scratch space available for everyone
chmod 777 /mnt/resource/

echo "Done"
