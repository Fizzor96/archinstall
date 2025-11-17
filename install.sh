#!/usr/bin/env bash
set -euo pipefail

# ==================== CONFIG ====================
KEYMAP="hu"
TIMEZONE="Europe/Budapest"
DEFAULT_ROOT_GB=30
LUKS_PASS="asd123"
EXTRA_PKGS=(vlc htop fastfetch alacritty neovim git curl wget unzip tree bat fzf ripgrep xclip)
# ===============================================

# Global variables
DISK="" PARTITION_SEPARATOR="" BOOT_MODE=""
ENCRYPT="no" EFI_PART="" SWAP_PART="" CRYPT_PART="" ROOT_DEV="" HOME_DEV=""
ROOT_SIZE_GB="" HOSTNAME="arch" USERNAME="fizzor" ROOT_PASS="123" USER_PASS="123"
KERNEL="linux" GPU_DRIVERS="" DE_PKGS="" GREETER="" DE=""

# Helper functions
log()   { printf "\n\e[1;32m=== %s ===\e[0m\n" "$*"; }
error() { printf "\e[1;31m[ERROR] %s\e[0m\n" "$*" >&2; exit 1; }
ask()   { read -rp "$1 [Y/n] " ans; [[ $ans =~ ^[Nn]$ ]] && return 1 || return 0; }
askno() { read -rp "$1 [y/N] " ans; [[ $ans =~ ^[Nn]$ ]] && return 0 || return 1; }

# =============================================================================
# 1. PREPARATION
# =============================================================================
# log "Updating keyring & mirrors"
# pacman -Sy --noconfirm archlinux-keyring pacman-contrib reflector rsync terminus-font   # Install required packages
# sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf  # Enable parallel downloads
# log "Optimizing mirrors for Hungary"
# reflector -c "HU" -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist    # Optimize mirrors

log "Console keyboard layout: Hungarian"; loadkeys "$KEYMAP"    # Set keyboard layout

# Install required packages safely
pacman -Sy --noconfirm archlinux-keyring && \
pacman -Su --noconfirm && \
pacman -S --noconfirm pacman-contrib reflector rsync terminus-font

setfont ter-v22b    # Set console font

# Enable parallel downloads robustly
sed -i 's/^#\?ParallelDownloads\s*=.*/ParallelDownloads = 10/' /etc/pacman.conf

# Generate stable mirror list with retry
log "Optimizing mirrors for Hungary"
for i in {1..5}; do
    reflector --country HU \
              --age 24 \
              --fastest 5 \
              --sort rate \
              --protocol https \
              --save /etc/pacman.d/mirrorlist && break
    sleep 3
done

# =============================================================================
# 2. BOOT MODE DETECTION
# =============================================================================
if [[ -f /sys/firmware/efi/fw_platform_size ]]; then
    case "$(cat /sys/firmware/efi/fw_platform_size)" in
        64) BOOT_MODE="64"; log "Boot mode: UEFI 64-bit" ;;
        32) BOOT_MODE="32"; log "Boot mode: UEFI 32-bit" ;;
        *)  BOOT_MODE="BIOS"; log "Boot mode: Unknown UEFI → treating as BIOS" ;;
    esac
else
    BOOT_MODE="BIOS"; log "Boot mode: Legacy BIOS"
fi

# =============================================================================
# 3. INTERNET CONNECTION
# =============================================================================
ensure_internet() {
    ping -c1 archlinux.org &>/dev/null && return 0
    systemctl start iwd
    local dev=$(iwctl device list | awk 'NR==4 {print $2; exit}')
    [[ -z $dev ]] && ip link show | grep -q "state UP" && return 0
    while :; do
        iwctl station "$dev" scan; sleep 3
        mapfile -t nets < <(iwctl station "$dev" get-networks | awk 'NR>4 && NF {print $1}')
        ((${#nets[@]})) || { echo "No networks. Retry? [y]"; read r; [[ $r = y ]] && continue || error "No Wi-Fi"; }
        select ssid in "${nets[@]}"; do [[ -n $ssid ]] && break; done
        read -rsp "Wi-Fi password: " pass; echo
        iwctl --passphrase "$pass" station "$dev" connect "$ssid" && sleep 6 && ping -c1 archlinux.org &>/dev/null && break
    done
}
ensure_internet && log "Internet: OK"

# =============================================================================
# 4. DISK SELECTION
# =============================================================================
select_disk() {
    mapfile -t disks < <(lsblk -dnpo NAME,SIZE,TYPE | awk '$3=="disk" {print $1 " " $2}')
    ((${#disks[@]})) || error "No disks found!"

    log "Available disks:"
    for i in "${!disks[@]}"; do
        printf " %2d) %s\n" "$((i+1))" "${disks[i]}"
    done

    while :; do
        read -rp "Select target disk number: " n
        [[ $n =~ ^[0-9]+$ ]] || { echo "Please enter a number"; continue; }
        (( n >= 1 && n <= ${#disks[@]} )) && break
        echo "Invalid selection"
    done

    DISK=$(awk '{print $1}' <<< "${disks[n-1]}")
    log "Target disk: $DISK"
}
select_disk
[[ $DISK == *nvme* ]] && PARTITION_SEPARATOR="p" || PARTITION_SEPARATOR=""

# =============================================================================
# 5. USER CONFIGURATION
# =============================================================================
log "User configuration"
read -rp "Hostname [arch]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch}
read -rp "Username [fizzor]: " USERNAME; USERNAME=${USERNAME:-fizzor}
read -rsp "Root password [123]: " ROOT_PASS; echo; ROOT_PASS=${ROOT_PASS:-123}
read -rsp "User password [123]: " USER_PASS; echo; USER_PASS=${USER_PASS:-123}

log "Kernel selection"
echo "1) linux (vanilla)" ; echo "2) linux-zen" ; echo "3) linux-lts" ; echo "4) linux-hardened"
read -rp "Choice [1]: " k; k=${k:-1}
case "$k" in 2) KERNEL="linux-zen";; 3) KERNEL="linux-lts";; 4) KERNEL="linux-hardened";; *) KERNEL="linux";; esac
log "Selected kernel: $KERNEL"

log "GPU driver selection"
echo "1) NVIDIA  2) AMD  3) Intel  4) VM  5) None"
read -rp "Choice [1-5]: " g
case "$g" in
    1) GPU_DRIVERS="nvidia nvidia-utils nvidia-settings libva-nvidia-driver";;
    2) GPU_DRIVERS="xf86-video-amdgpu vulkan-radeon libva-mesa-driver mesa";;
    3) GPU_DRIVERS="xf86-video-intel vulkan-intel intel-media-driver mesa";;
    4) GPU_DRIVERS="mesa";;
    *) GPU_DRIVERS="";;
esac
[[ -z $GPU_DRIVERS ]] && log "GPU: generic modesetting" || log "GPU drivers: $GPU_DRIVERS"

# =============================================================================
# 6. DESKTOP ENVIRONMENT SELECTION
# =============================================================================
log "Desktop Environment selection"
echo "1) None (base system only)"
echo "2) i3-wm"
echo "3) Hyprland"
read -rp "Choice [1]: " de; de=${de:-1}

case "$de" in
    # 2) DE_PKGS="i3-wm i3status dmenu xorg xorg-server xorg-xinit lightdm lightdm-gtk-greeter"; GREETER="lightdm";;
    2) DE_PKGS="i3-wm i3status dmenu xorg-server xorg-xinit xorg-xrandr lightdm lightdm-gtk-greeter"; GREETER="lightdm"; DE="i3";;
    3) DE_PKGS="hyprland wayland-protocols qt5-wayland qt6-wayland xdg-desktop-portal-hyprland hyprpaper hyprpicker greetd tuigreet"; GREETER="greetd"; DE="hyprland";;
    *) DE_PKGS=""; GREETER="";;
esac

if [[ -n $GREETER ]]; then
    if [[ $de -eq 2 ]]; then
        log "Selected: i3-wm"
    else
        log "Selected: Hyprland"
    fi
else
    log "No desktop environment selected"
fi

# =============================================================================
# 7. PARTITIONING
# =============================================================================
partition_disk() {
    log "Partitioning $DISK"
    if ! askno "Enable full-disk encryption (LUKS) with default passphrase '$LUKS_PASS'?"; then
        ENCRYPT="yes"
        log "Encryption ENABLED → passphrase: $LUKS_PASS"
    else
        ENCRYPT="no"
        log "Encryption disabled"
    fi

    # Determine swap size based on RAM
    local ram_gb=$(free -g --si | awk '/^Mem:/ {print $2}')
    local swap_size="16G"; (( ram_gb <= 16 )) && swap_size="${ram_gb}G"; (( ram_gb > 64 )) && swap_size="32G"

    # Determine root size
    read -rp "Root size in GB [${DEFAULT_ROOT_GB}]: " ROOT_SIZE_GB; ROOT_SIZE_GB=${ROOT_SIZE_GB:-$DEFAULT_ROOT_GB}
    (( ROOT_SIZE_GB < 20 )) && error "Root too small"
    local root_size="${ROOT_SIZE_GB}G"

    # Determine EFI size
    # Probably Boot is a better naming
    local efi_size="1024M"
    [[ $BOOT_MODE == "32" ]] && efi_size="512M"

    # !TODO: FIX encryption
    clear; log "FINAL LAYOUT"; [[ $BOOT_MODE != "BIOS" ]] && echo "EFI → $efi_size"
    [[ $BOOT_MODE == "BIOS" ]] && echo "BIOS → 1M"; echo "Swap → $swap_size"; echo "Root → $root_size"; echo "Home → rest"
    [[ $ENCRYPT == yes ]] && echo "Encryption → YES"; echo
    echo "ALL DATA WILL BE DESTROYED!"; ask "Continue?" || error "Aborted"

    wipefs -af "$DISK" &>/dev/null; sgdisk --zap-all "$DISK" &>/dev/null
    dd if=/dev/zero of="$DISK" bs=1M count=50 status=none
    dmsetup remove_all --deferred &>/dev/null; cryptsetup close cryptlvm &>/dev/null || true

    sgdisk -og "$DISK"; partprobe "$DISK"; sleep 2; udevadm settle
    local n=1

    [[ $BOOT_MODE == "BIOS" ]] && { sgdisk -n ${n}:0:+1M -t ${n}:ef02 -c ${n}:BIOSBOOT "$DISK"; ((n++)); }
    [[ $BOOT_MODE != "BIOS" ]] && { sgdisk -n ${n}:0:+$efi_size -t ${n}:ef00 -c ${n}:EFI "$DISK"; EFI_PART="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++)); }
    sgdisk -n ${n}:0:+$swap_size -t ${n}:8200 -c ${n}:swap "$DISK"; SWAP_PART="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++))

    if [[ $ENCRYPT == yes ]]; then
        sgdisk -n ${n}:0:0 -t ${n}:8309 -c ${n}:LinuxCrypt "$DISK"; CRYPT_PART="${DISK}${PARTITION_SEPARATOR}${n}"
        partprobe "$DISK"; sleep 2; udevadm settle
        printf "%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$CRYPT_PART"
        printf "%s" "$LUKS_PASS" | cryptsetup open --type luks2 "$CRYPT_PART" cryptlvm
        pvcreate /dev/mapper/cryptlvm; vgcreate vg0 /dev/mapper/cryptlvm
        lvcreate -L "$root_size" -n root vg0; lvcreate -l 100%FREE -n home vg0
        ROOT_DEV="/dev/mapper/vg0-root"; HOME_DEV="/dev/mapper/vg0-home"
    else
        sgdisk -n ${n}:0:+$root_size -t ${n}:ea00 -c ${n}:root "$DISK"; ROOT_DEV="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++))
        sgdisk -n ${n}:0:0 -t ${n}:ea00 -c ${n}:home "$DISK"; HOME_DEV="${DISK}${PARTITION_SEPARATOR}${n}"
    fi

    partprobe "$DISK"; sleep 1; udevadm settle
    log "Partitioning done!"; lsblk -f "$DISK"
}
partition_disk

# =============================================================================
# 8. FORMAT + MOUNT + INSTALL
# =============================================================================
log "Formatting and mounting..."
[[ -n $EFI_PART ]] && mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"; swapon "$SWAP_PART"
mkfs.ext4 -F -L root "$ROOT_DEV"; mkfs.ext4 -F -L home "$HOME_DEV"
mount "$ROOT_DEV" /mnt; mkdir -p /mnt/home; mount "$HOME_DEV" /mnt/home
[[ -n $EFI_PART ]] && { mkdir -p /mnt/boot; mount "$EFI_PART" /mnt/boot; }

log "Installing system..."
pacstrap /mnt base base-devel $KERNEL linux-firmware lvm2 sudo networkmanager grub efibootmgr os-prober ntfs-3g $GPU_DRIVERS ${EXTRA_PKGS[@]} $DE_PKGS
genfstab -U /mnt >> /mnt/etc/fstab


# =============================================================================
# 9. CHROOT & FINAL SETUP
# =============================================================================
log "Final configuration inside chroot..."
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "hu"
EndSection
XKB

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOS

systemctl enable NetworkManager lightdm

# Bootloader
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    grub-install --target=i386-pc $DISK
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Encryption hooks
if cryptsetup status cryptlvm &>/dev/null 2>&1; then
    sed -i 's/ block filesystems keyboard fsck/ encrypt lvm2 block filesystems keyboard fsck/' /etc/mkinitcpio.conf
    mkinitcpio -P
fi

# Users
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
EOF

# =============================================================================
# 10. Install yay AUR helper - fully automatic, no unbound errors, no quoting issues
# =============================================================================
log "Installing yay (AUR helper) automatically for user $USERNAME"

export USERNAME
export USER_PASS   # password of the normal user, not root

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
pacman -Sy --noconfirm base-devel git
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME
sudo -u "$USERNAME" bash -c '
    set -euo pipefail
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg --noconfirm --needed -si
    cd /tmp
    rm -rf yay
'
rm -f /etc/sudoers.d/$USERNAME
EOF

log "yay installation finished"


# =============================================================================
# 11. CLEANUP
# =============================================================================
cleanup() {
    log "Cleaning"
    arch-chroot /mnt pacman -Scc --noconfirm
    arch-chroot /mnt rm -rf /var/log/* /tmp/* /usr/share/doc/* /usr/share/man/*
}
cleanup


log "INSTALLATION COMPLETE!"
echo
echo "Summary:"
echo "   Hostname           : $HOSTNAME"
echo "   User               : $USERNAME"
echo "   Kernel             : $KERNEL"
echo "   GPU                : ${GPU_DRIVERS:-generic}"
echo "   DE                 : ${DE}"
echo "   Display Manager    : ${GREETER}"
echo "   LUKS               : $ENCRYPT $( [[ $ENCRYPT == yes ]] && echo "(pass: $LUKS_PASS)" )"
echo "   AUR Helper         : yay"
echo
read -rp "Installation finished! Ready to unmount and reboot? [Y/n] " ans
[[ $ans =~ ^[Nn]$ ]] && echo "Okay, exiting. Manually run: umount -R /mnt; swapoff -a; reboot" && exit 0

umount -R /mnt
swapoff -a
reboot