#!/usr/bin/env bash
set -euo pipefail
clear; setfont ter-v22b

# ==================== CONFIG ====================
KEYMAP="hu"
TIMEZONE="Europe/Budapest"
DEFAULT_ROOT_GB=30
LUKS_PASS="123"
HOSTNAME="arch"
USERNAME="fizzor"
ROOT_PASS="123"
USER_PASS="123"
EXTRA_PKGS=(htop fastfetch alacritty neovim git curl wget unzip tree bat fzf ripgrep xclip)
# ===============================================

# Global variables
DISK="" PARTITION_SEPARATOR="" BOOT_MODE="" CRYPT_UUID=""
ENCRYPT="no" EFI_PART="" SWAP_PART="" CRYPT_PART="" ROOT_DEV="" HOME_DEV=""
ROOT_SIZE_GB="" KERNEL="linux" GPU_DRIVERS="" DE_PKGS="" GREETER="" DE=""

# Helper functions
log()   { printf "\n\e[1;32m=== %s ===\e[0m\n" "$*"; }
info() { printf '\n\e[93m %s \e[0m\n' "$*"; }
error() { printf "\e[1;31m[ERROR] %s\e[0m\n" "$*" >&2; exit 1; }
ask()   { read -rp "$1 [Y/n] " ans; [[ $ans =~ ^[Nn]$ ]] && return 1 || return 0; }
askno() { read -rp "$1 [y/N] " ans; [[ $ans =~ ^[Nn]$ ]] && return 0 || return 1; }

# info "Arch Linux Automated Installer"

# =============================================================================
# 0. KEYMAP SETUP
# =============================================================================
loadkeys "$KEYMAP"

# =============================================================================
# 1. BOOT MODE DETECTION
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
# 2. INTERNET CONNECTION
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
# 3. KEYRING & MIRRORS UPDATE
# =============================================================================
log "KEYRING & MIRRORS UPDATE"
# echo "Updating keyring & mirrors..."
pacman -Sy --noconfirm archlinux-keyring pacman-contrib &>/dev/null
sed -i 's/^#\?ParallelDownloads\s*=.*/ParallelDownloads = 10/' /etc/pacman.conf
echo "Keyring & mirrors updated."

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
    done

    DISK=$(awk '{print $1}' <<< "${disks[n-1]}")
    # log "Target disk: $DISK"
    info "Target disk: $DISK"
}
select_disk
[[ $DISK == *nvme* ]] && PARTITION_SEPARATOR="p" || PARTITION_SEPARATOR=""

# =============================================================================
# 5. USER CONFIGURATION
# =============================================================================
log "User configuration"
read -rp "Hostname [$HOSTNAME]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch}
read -rp "Username [$USERNAME]: " USERNAME; USERNAME=${USERNAME:-fizzor}
read -rsp "Root password [$ROOT_PASS]: " ROOT_PASS; echo; ROOT_PASS=${ROOT_PASS:-123}
read -rsp "User password [$USER_PASS]: " USER_PASS; echo; USER_PASS=${USER_PASS:-123}

log "Kernel selection"
echo "1) linux (vanilla)" ; echo "2) linux-zen" ; echo "3) linux-lts" ; echo "4) linux-hardened"
read -rp "Choice [1]: " k; k=${k:-1}
case "$k" in 2) KERNEL="linux-zen";; 3) KERNEL="linux-lts";; 4) KERNEL="linux-hardened";; *) KERNEL="linux";; esac
info "Selected kernel: $KERNEL"

log "GPU driver selection"
echo "1) NVIDIA"
echo "2) AMD"
echo "3) Intel"
echo "4) VM"
echo "5) None"
read -rp "Choice [1-5]: " g
case "$g" in
    1) GPU_DRIVERS="nvidia nvidia-utils nvidia-settings libva-nvidia-driver";;
    2) GPU_DRIVERS="xf86-video-amdgpu vulkan-radeon libva-mesa-driver mesa";;
    3) GPU_DRIVERS="xf86-video-intel vulkan-intel intel-media-driver mesa";;
    4) GPU_DRIVERS="mesa";;
    *) GPU_DRIVERS="";;
esac
[[ -z $GPU_DRIVERS ]] && info "GPU: generic modesetting" || info "GPU drivers: $GPU_DRIVERS"

# =============================================================================
# 6. DESKTOP ENVIRONMENT SELECTION
# =============================================================================
log "Desktop Environment selection"
echo "1) None (base system only)"
echo "2) i3-wm"
echo "3) Hyprland"
read -rp "Choice [1]: " de; de=${de:-1}

case "$de" in
    2) DE_PKGS="i3-wm i3status dmenu xorg-server xorg-xinit xorg-xrandr sddm"
       GREETER="sddm"
       DE="i3";;
    3) DE_PKGS="hyprpaper xdg-desktop-portal xdg-desktop-portal-hyprland seatd polkit-kde-agent sddm dbus"
       GREETER="sddm"
       DE="hyprland";;
    *) DE_PKGS=""; GREETER="";;
esac

if [[ -n $GREETER ]]; then
    [[ $de -eq 2 ]] && info "Selected: i3-wm" || info "Selected: Hyprland"
else
    info "No desktop environment selected"
fi

# =============================================================================
# 7. PARTITIONING
# =============================================================================
partition_disk() {
    log "Partitioning $DISK"
    # Ask clearly whether to enable encryption
    if askno "Enable full-disk encryption (LUKS)?"; then
        ENCRYPT="yes"
        read -rp "Enter LUKS passphrase [default: $LUKS_PASS]: " input_pass
        LUKS_PASS=${input_pass:-$LUKS_PASS}
        info "Encryption ENABLED"
        echo
    else
        ENCRYPT="no"
        info "Encryption DISABLED"
        echo
    fi

    local ram_gb
    ram_gb=$(free -g --si | awk '/^Mem:/ {print $2}')
    local swap_size="16G"
    (( ram_gb <= 16 )) && swap_size="${ram_gb}G"
    (( ram_gb > 64 )) && swap_size="32G"

    read -rp "Root size in GB [${DEFAULT_ROOT_GB}]: " ROOT_SIZE_GB; ROOT_SIZE_GB=${ROOT_SIZE_GB:-$DEFAULT_ROOT_GB}
    (( ROOT_SIZE_GB < 20 )) && error "Root too small"
    local root_size="${ROOT_SIZE_GB}G"
    local efi_size="1024M"
    [[ $BOOT_MODE == "32" ]] && efi_size="512M"

    clear; log "FINAL LAYOUT"
    [[ $BOOT_MODE != "BIOS" ]] && echo "EFI → $efi_size"
    [[ $BOOT_MODE == "BIOS" ]] && echo "BIOS → 1M"
    echo "Swap → $swap_size"; echo "Root → $root_size"; echo "Home → rest"
    echo "Encryption → $ENCRYPT"
    echo; info "ALL DATA WILL BE DESTROYED!"; ask "Continue?" || error "Aborted"

    # Wipe previous maps/partitions
    wipefs -af "$DISK" &>/dev/null
    sgdisk --zap-all "$DISK" &>/dev/null
    dd if=/dev/zero of="$DISK" bs=1M count=50 status=none
    # ensure no leftover dm mappings
    dmsetup remove_all --deferred &>/dev/null || true
    cryptsetup close cryptlvm &>/dev/null || true

    sgdisk -og "$DISK"; partprobe "$DISK"; sleep 2; udevadm settle
    local n=1

    [[ $BOOT_MODE == "BIOS" ]] && { sgdisk -n ${n}:0:+1M -t ${n}:ef02 -c ${n}:BIOSBOOT "$DISK"; ((n++)); }
    [[ $BOOT_MODE != "BIOS" ]] && { sgdisk -n ${n}:0:+$efi_size -t ${n}:ef00 -c ${n}:EFI "$DISK"; EFI_PART="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++)); }
    sgdisk -n ${n}:0:+$swap_size -t ${n}:8200 -c ${n}:swap "$DISK"; SWAP_PART="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++))

    if [[ $ENCRYPT == yes ]]; then
        # create one partition that will be LUKS container (use Linux filesystem GUID; content will be LUKS)
        sgdisk -n ${n}:0:0 -t ${n}:8300 -c ${n}:LinuxCrypt "$DISK"
        CRYPT_PART="${DISK}${PARTITION_SEPARATOR}${n}"
        partprobe "$DISK"; sleep 2; udevadm settle

        # Format LUKS and open it (read pass from stdin; require cryptsetup installed in live env)
        echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --key-file=- "$CRYPT_PART" --batch-mode -q
        echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$CRYPT_PART" cryptlvm

        # create LVM on top of /dev/mapper/cryptlvm
        pvcreate /dev/mapper/cryptlvm
        vgcreate vg0 /dev/mapper/cryptlvm
        lvcreate -L "$root_size" -n root vg0
        lvcreate -l 100%FREE -n home vg0

        ROOT_DEV="/dev/mapper/vg0-root"
        HOME_DEV="/dev/mapper/vg0-home"

        CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")
        [[ -z "$CRYPT_UUID" ]] && { echo "Failed to get UUID for $CRYPT_PART"; exit 1; }
    else
        sgdisk -n ${n}:0:+$root_size -t ${n}:8300 -c ${n}:root "$DISK"
        ROOT_DEV="${DISK}${PARTITION_SEPARATOR}${n}"; ((n++))
        sgdisk -n ${n}:0:0 -t ${n}:8300 -c ${n}:home "$DISK"
        HOME_DEV="${DISK}${PARTITION_SEPARATOR}${n}"
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
mkfs.ext4 -F -L root "$ROOT_DEV"
mkfs.ext4 -F -L home "$HOME_DEV"
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/home; mount "$HOME_DEV" /mnt/home
[[ -n $EFI_PART ]] && { mkdir -p /mnt/boot; mount "$EFI_PART" /mnt/boot; }

log "Installing system"
pacstrap /mnt base base-devel $KERNEL linux-firmware lvm2 sudo networkmanager grub efibootmgr os-prober ntfs-3g \
    ${EXTRA_PKGS[@]} ${DE_PKGS} || true   # continue even if nvidia fails here
genfstab -U /mnt >> /mnt/etc/fstab

# =============================================================================
# 9. CHROOT & FINAL SETUP
# =============================================================================
log "Final configuration inside chroot..."
export CRYPT_PART ROOT_DEV USERNAME ROOT_PASS USER_PASS HOSTNAME TIMEZONE KEYMAP DISK ENCRYPT KERNEL GPU_DRIVERS DE GREETER
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

[[ -n "$GREETER" ]] && systemctl enable NetworkManager $GREETER

# Encryption hooks & kernel parameters
if [[ "$ENCRYPT" == yes ]]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$CRYPT_UUID:cryptlvm root=/dev/mapper/vg0-root quiet splash\"|" /etc/default/grub
    # safe to enable cryptodisk support in grub for UEFI and BIOS bootmodes
    echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
    #echo 'GRUB_PRELOAD_MODULES="cryptodisk luks lvm"' >> /etc/default/grub
fi

mkinitcpio -P

# Bootloader
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    grub-install --target=i386-pc $DISK
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Users
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
EOF

# =============================================================================
# 10. Install yay AUR helper
# =============================================================================
log "Installing yay (AUR helper) automatically for user $USERNAME"
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME
pacman -Sy --noconfirm base-devel git
sudo -u "$USERNAME" bash -c '
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg --noconfirm --needed -si
    cd /tmp; rm -rf yay
'
rm -f /etc/sudoers.d/$USERNAME
EOF

# =============================================================================
# 11. NVIDIA + Hyprland specific fixes (AUR)
# =============================================================================
if [[ "$DE" == "hyprland" ]]; then

    # -------------------------------------------------------
    # Configure SDDM to use Wayland (if using sddm)
    # -------------------------------------------------------
    if [[ "${GREETER}" == "sddm" ]]; then
        arch-chroot /mnt /bin/bash << EOF
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/wayland.conf << 'SDDM'
[General]
DisplayServer=wayland

[Wayland]
Enable=true
SDDM
EOF
    fi

    # -------------------------------------------------------
    # NVIDIA: patched Hyprland + DRM modesetting + initramfs
    # -------------------------------------------------------
    if [[ "${GPU_DRIVERS:-}" == *"nvidia"* ]]; then
        arch-chroot /mnt /bin/bash -c "yay -S --noconfirm --needed hyprland-nvidia-git || true"
        arch-chroot /mnt /bin/bash "echo 'options nvidia_drm modeset=1' > /etc/modprobe.d/nvidia.conf"
EOF

        arch-chroot /mnt mkinitcpio -P || true

    else
        # ---------------------------------------------------
        # Non-NVIDIA: official Hyprland package
        # ---------------------------------------------------
        arch-chroot /mnt /bin/bash << EOF
yay -S --noconfirm --needed hyprland-git || true
EOF
    fi

    # -------------------------------------------------------
    # seatd is required for session permissions
    # -------------------------------------------------------
    arch-chroot /mnt /bin/bash << EOF
systemctl enable seatd || true
EOF

    # Hyprland Wayland session file
    arch-chroot /mnt /bin/bash << EOF
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/hyprland.desktop << 'HYPR'
[Desktop Entry]
Name=Hyprland
Comment=A dynamic tiling Wayland compositor
Exec=/usr/bin/Hyprland
Type=Application
HYPR
EOF

    # -------------------------------------------------------
    # Optional extras
    # -------------------------------------------------------
    arch-chroot /mnt /bin/bash -c "yay -S --noconfirm --needed bibata-cursor-theme waybar-hyprland-git || true"

fi


# =============================================================================
# 12. CLEANUP & FINISH
# =============================================================================
log "Cleaning"
arch-chroot /mnt pacman -Scc --noconfirm
arch-chroot /mnt rm -rf /var/log/* /tmp/* /usr/share/doc/* /usr/share/man/*

clear
log "INSTALLATION COMPLETE!"
echo "   Hostname           : $HOSTNAME"
echo "   User               : $USERNAME"
echo "   Kernel             : $KERNEL"
echo "   GPU                : ${GPU_DRIVERS:-generic}"
echo "   DE                 : ${DE:-none}"
echo "   Display Manager    : ${GREETER:-none}"
echo "   LUKS               : $ENCRYPT"
echo "   AUR Helper         : yay"
echo

read -rp "Ready to unmount and reboot? [Y/n] " ans
umount -Rl /mnt 2>/dev/null || umount -fRl /mnt
mountpoint -q /mnt && sleep 3 && umount -fRl /mnt
swapoff -a 2>/dev/null
if [[ "$ENCRYPT" == yes ]]; then
    lvchange -an vg0 2>/dev/null || true
    cryptsetup close cryptlvm && log "LUKS container closed"
fi
sync
reboot now