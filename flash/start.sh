#!/bin/bash -eE

function __error_handing__(){
    local last_status_code=$1;
    local error_line_number=$2;
    echo 1>&2 "Error - exited with status $last_status_code at line $error_line_number";
    perl -slne 'if($.+5 >= $ln && $.-4 <= $ln){ $_="$. $_"; s/$ln/">" x length($ln)/eg; s/^\D+.*?$/\e[1;31m$&\e[0m/g;  print}' -- -ln=$error_line_number $0
}

trap  '__error_handing__ $? $LINENO' ERR

printf '\n<<<<<<<<<<<< create directories           >>>>>>>>>>>>\n\n'
[ -d dl ] || mkdir dl
[ -d files ] || mkdir files
[ -d orig_fw ] || mkdir orig_fw

printf '\n<<<<<<<<<<<< create backup            >>>>>>>>>>>>\n\n'
edl rf orig_fw.bin

printf '\n<<<<<<<<<<<< dump oem boot image      >>>>>>>>>>>>\n\n'
edl r boot orig_fw/boot.bin

printf '\n<<<<<<<<<<<< download needed files        >>>>>>>>>>>>\n\n'
# OpenStick
wget -P files https://github.com/OpenStick/OpenStick/releases/download/v1/boot-ufi001c.img
wget -P dl https://github.com/OpenStick/OpenStick/releases/download/v1/debian.zip

# Qualcom firmware
wget -P dl http://releases.linaro.org/96boards/dragonboard410c/linaro/rescue/21.12/dragonboard-410c-bootloader-emmc-linux-176.zip

# qhypstub and lk2nd
wget -P dl https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2/raw/prebuilt.zip

printf '\n<<<<<<<<<<<< assemble firmware files      >>>>>>>>>>>>\n\n'
unzip -o -j -d files dl/debian.zip debian/rootfs.img
unzip -o -j -d files/ dl/dragonboard-410c-bootloader-emmc-linux-176.zip \
    dragonboard-410c-bootloader-emmc-linux-176/{{rpm,sbl1,tz}.mbn,sbc_1.0_8016.bin}

# do not overwrite if manually built
unzip -n -d files dl/prebuilt.zip

printf '\n<<<<<<<<<<<< install bootloader           >>>>>>>>>>>>\n\n'
edl w aboot files/emmc_appsboot-test-signed.mbn

printf '\n<<<<<<<<<<<< reboot to fastboot           >>>>>>>>>>>>\n\n'
edl e boot
edl reset

# wait for fastboot
until [ "x$(fastboot devices)" != "x" ]
do
    sleep 1
done

echo $(fastboot devices)

printf '\n<<<<<<<<<<<< fastboot dump oem files      >>>>>>>>>>>>\n\n'
fastboot oem read-partition fsc && fastboot get_staged orig_fw/fsc.bin
fastboot oem read-partition fsg && fastboot get_staged orig_fw/fsg.bin
fastboot oem read-partition modemst1 && fastboot get_staged orig_fw/modemst1.bin
fastboot oem read-partition modemst2 && fastboot get_staged orig_fw/modemst2.bin
fastboot oem read-partition modem && fastboot get_staged orig_fw/modem.bin
fastboot oem read-partition persist && fastboot get_staged orig_fw/persist.bin
fastboot oem read-partition sec && fastboot get_staged orig_fw/sec.bin

printf '\n<<<<<<<<<<<< fastboot flash firmware      >>>>>>>>>>>>\n\n'
fastboot flash partition files/gpt_both0.bin
fastboot flash aboot files/emmc_appsboot-test-signed.mbn
fastboot flash hyp files/qhypstub-test-signed.mbn
fastboot flash rpm files/rpm.mbn
fastboot flash sbl1 files/sbl1.mbn
fastboot flash tz files/tz.mbn
fastboot flash cdt files/sbc_1.0_8016.bin
fastboot flash boot files/boot-ufi001c.img
fastboot flash rootfs files/rootfs.img

printf '\n<<<<<<<<<<<< fastboot restore oem files   >>>>>>>>>>>>\n\n'
fastboot flash sec orig_fw/sec.bin
fastboot flash fsc orig_fw/fsc.bin
fastboot flash fsg orig_fw/fsg.bin
fastboot flash modemst1 orig_fw/modemst1.bin
fastboot flash modemst2 orig_fw/modemst2.bin

printf '\n<<<<<<<<<<<< reboot                       >>>>>>>>>>>>\n\n'
fastboot reboot

printf '\n<<<<<<<<<<<< waiting ...                  >>>>>>>>>>>>\n\n'
adb wait-for-device

printf '\n<<<<<<<<<<<< Update modem firmware        >>>>>>>>>>>>\n\n'
cat > update.sh << EOF
#!/bin/sh -e
mount /tmp/modem.bin /mnt
cp -v /mnt/image/m* /mnt/image/wc* /lib/firmware || true
umount /mnt

mount /tmp/persist.bin /mnt
cp -v /mnt/WCNSS_qcom_wlan_nv.bin /lib/firmware/wlan/prima 
umount /mnt

rm /tmp/*bin /tmp/*sh
EOF

adb push update.sh orig_fw/modem.bin orig_fw/persist.bin /tmp
adb shell sh /tmp/update.sh

printf '\n<<<<<<<<<<<< update flattened device tree >>>>>>>>>>>>\n\n'
wget -P files https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2/raw/patch.dts
adb pull /sys/firmware/fdt
dtc -I dtb -O dts fdt -o files/default.dts
rm fdt
cat files/default.dts files/patch.dts | dtc -I dts -O dts -o files/jz01-45-v33.dts
dtc -I dts -O dtb files/jz01-45-v33.dts -o files/jz01-45-v33.dtb

adb push files/jz01-45-v33.* /boot

printf '\n<<<<<<<<<<<< creating update script       >>>>>>>>>>>>\n\n'

cat > update.sh << EOF
#!/bin/sh -e

# replace boot with extlinux
mkfs.ext2 /dev/disk/by-partlabel/boot

mount /dev/disk/by-partlabel/boot /mnt
mkdir /mnt/extlinux
cat > /mnt/extlinux/extlinux.conf << EOF1
linux /vmlinuz
fdt /default.dtb
append earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF1

# copy boot files
mv /boot/* /mnt/

# create links
(cd /mnt; ln -sf vm* vmlinuz; ln -sf jz01-45-v33.dtb default.dtb)

# update fstab
cat > /etc/fstab << EOF2
/dev/disk/by-partlabel/boot /boot ext2 defaults 0 0
EOF2

umount /mnt

EOF

chmod a+x update.sh

printf '\n<<<<<<<<<<<< run update.sh                >>>>>>>>>>>>\n\n'
adb push update.sh /tmp
adb shell /tmp/update.sh

printf '\n<<<<<<<<<<<< rebooting ...                >>>>>>>>>>>>\n\n'
adb reboot

printf '\n<<<<<<<<<<<< waiting ...                  >>>>>>>>>>>>\n\n'
adb wait-for-device

printf '\n<<<<<<<<<<<< done!                        >>>>>>>>>>>>\n\n'

rm update.sh
