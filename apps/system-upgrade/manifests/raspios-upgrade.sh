#!/bin/sh
set -eu

marker_dir="/var/lib/rancher/system-upgrade/reboot"
marker="${marker_dir}/raspios-trixie"
boot_id="$(cat /proc/sys/kernel/random/boot_id)"

mkdir -p "${marker_dir}"

if [ -f "${marker}" ]; then
  previous_boot_id="$(cat "${marker}")"
  if [ "${previous_boot_id}" != "${boot_id}" ]; then
    rm -f "${marker}"
    echo "Raspberry Pi OS update completed after reboot"
    exit 0
  fi

  echo "Reboot marker exists for current boot; requesting reboot again"
  systemctl reboot
  while true; do
    sleep 3600
  done
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

apt-get update
apt-get -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  full-upgrade
apt-get -y autoremove --purge
apt-get clean

printf '%s\n' "${boot_id}" > "${marker}"
sync

systemctl reboot
while true; do
  sleep 3600
done
