#!/bin/bash
set -e

KERNEL_VER="$1"
HARDENED_TAG="$2"

if [ -z "$KERNEL_VER" ] || [ -z "$HARDENED_TAG" ]; then
    echo "[!] Использование: ./build.sh <версия_ядра> <тег_hardened>"
    exit 1
fi

BASE_DIR="$(pwd)"
SRC_DIR="$BASE_DIR/linux-src"
HARDENED_PATCH="linux-hardened-${HARDENED_TAG}.patch"
HARDENED_URL="https://github.com/anthraxx/linux-hardened/releases/download/${HARDENED_TAG}/${HARDENED_PATCH}"

if [ -f "config.secux" ]; then
    tr -d '\r' < "config.secux" > "config.secux.lf"
    mv "config.secux.lf" "config.secux"
fi

if [ ! -f "$HARDENED_PATCH" ]; then
    echo "> Скачиваем Hardened-патч: ${HARDENED_TAG}..."
    curl -sSfL -o "$HARDENED_PATCH" "$HARDENED_URL"
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "> Скачиваем исходники ядра v${KERNEL_VER}..."
    git clone --depth 1 --branch "v${KERNEL_VER}" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$SRC_DIR"
    cd "$SRC_DIR"
else
    cd "$SRC_DIR"
    echo "> Подготовка дерева исходников..."
    git reset --hard HEAD >/dev/null
    git clean -fd >/dev/null
    
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
    if [ "$CURRENT_TAG" != "v${KERNEL_VER}" ]; then
        echo "> Обновление до v${KERNEL_VER}..."
        git fetch --depth 1 origin tag "v${KERNEL_VER}"
        git checkout -f "v${KERNEL_VER}"
    fi
fi

echo "> Накладываем патчи..."

if ! patch -p1 --dry-run --fuzz=0 < "../$HARDENED_PATCH" >/dev/null 2>&1; then
    echo "[!] Oopsie: Патч $HARDENED_PATCH не ложится."
    exit 1
fi
patch -p1 --fuzz=0 < "../$HARDENED_PATCH" >/dev/null

sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION = -secux/' Makefile

if ! patch -p1 --dry-run --fuzz=0 < "../secuxlinux_ima.patch" >/dev/null 2>&1; then
    echo "[!] Oopsie: secuxlinux_ima.patch не ложится."
    exit 1
fi
patch -p1 --fuzz=0 < "../secuxlinux_ima.patch" >/dev/null

for patch_file in "../0001-amdgpu.patch" "../0002-amdgpu.patch"; do
    if [ -f "$patch_file" ]; then
        if ! patch -p1 --dry-run --fuzz=0 < "$patch_file" >/dev/null 2>&1; then
            echo "[!] Oopsie: Патч $(basename "$patch_file") не ложится."
            exit 1
        fi
        patch -p1 --fuzz=0 < "$patch_file" >/dev/null
        echo "  [OK] $(basename "$patch_file") применен."
    fi
done

echo "> Настраиваем Makefile для DKMS..."
sed -i '2i LLVM=1\nLLVM_IAS=1\nexport LLVM LLVM_IAS' Makefile

if [ ! -f "../arch-base-config" ]; then
    echo "> Получаем официальный дистрибутивный конфиг Arch linux-lts..."
    curl -sSfL "https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config" -o "../arch-base-config"
fi

echo "> Слияние конфигураций..."
# -m означает "только слияние", -Q полностью отключает предупреждения об оверайдах в логах.
scripts/kconfig/merge_config.sh -m -Q ../arch-base-config ../config.secux

sed -i 's/CONFIG_LOCALVERSION_AUTO=y/CONFIG_LOCALVERSION_AUTO=n/' .config

make LLVM=1 LLVM_IAS=1 CC="ccache clang" olddefconfig >/dev/null

echo "> Настраиваем зависимости PKGBUILD..."
cat << 'EOF' >> scripts/package/PKGBUILD

# Перехватываем динамически созданные функции пакета с помощью declare -f
_orig_pkg=$(declare -f "package_${pkgbase}")
eval "${_orig_pkg%\}}" '
    pkgdesc="Secux Linux hardened kernel and modules"
    depends+=(coreutils initramfs kmod mkinitcpio)
    provides+=(KSMBD-MODULE VIRTUALBOX-GUEST-MODULES WIREGUARD-MODULE)
    optdepends+=("wireless-regdb: to set the correct wireless channels" "linux-firmware: firmware images needed for some devices")
}'

_orig_hdrs=$(declare -f "package_${pkgbase}-headers")
eval "${_orig_hdrs%\}}" '
    pkgdesc="Headers and scripts for building modules for the Secux Linux hardened kernel"
    depends+=(pahole)
    provides+=(LINUX-HEADERS)
}'
EOF
export MAKEFLAGS="-j$(nproc)"
export PACMAN_PKGBASE="linux-secux"
export PACMAN_EXTRAPACKAGES="headers"

echo "> Запуск сборки ядра..."
make LLVM=1 LLVM_IAS=1 CC="ccache clang" KBUILD_BUILD_TIMESTAMP="" KCFLAGS="-march=x86-64-v3" LOCALVERSION="" pacman-pkg

echo "> Извлечение и подпись пакетов..."
mv *.pkg.tar.zst "$BASE_DIR/"
cd "$BASE_DIR"

for pkg in linux-secux-*.pkg.tar.zst; do
    echo "  Подписываем $pkg..."
    gpg --detach-sign --use-agent --yes "$pkg"
done

echo "> Yo!"