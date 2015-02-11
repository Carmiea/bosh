#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

# Turn-off reverse DNS resolution in sshd
sed "/^ *UseDNS/d" -i $chroot/etc/ssh/sshd_config
echo 'UseDNS no' >> $chroot/etc/ssh/sshd_config

# No root ssh
sed "/^ *PermitRootLogin/d" -i $chroot/etc/ssh/sshd_config
echo 'PermitRootLogin no' >> $chroot/etc/ssh/sshd_config

if [ "${stemcell_operating_system}" == "centos" ]; then
  # Disallow CBC Ciphers
  sed "/^ *Ciphers/d" -i $chroot/etc/ssh/sshd_config
  echo 'Ciphers aes256-ctr,aes192-ctr,aes128-ctr' >> $chroot/etc/ssh/sshd_config

  # Disallow Weak MACs
  sed "/^ *MACs/d" -i $chroot/etc/ssh/sshd_config
  echo 'MACs hmac-sha2-512,hmac-sha2-256,hmac-ripemd160' >> $chroot/etc/ssh/sshd_config
else
  # Disallow CBC Ciphers
  sed "/^ *Ciphers/d" -i $chroot/etc/ssh/sshd_config
  echo 'Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' >> $chroot/etc/ssh/sshd_config

  # Disallow Weak MACs
  sed "/^ *MACs/d" -i $chroot/etc/ssh/sshd_config
  echo 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-ripemd160-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,hmac-ripemd160' >> $chroot/etc/ssh/sshd_config
fi
