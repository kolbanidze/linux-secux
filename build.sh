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
HARDENED_SIG="${HARDENED_PATCH}.sig"
HARDENED_SIG_URL="${HARDENED_URL}.sig"

# Ключ Levente Polyak (anthraxx), владельца linux-hardened.
# https://archlinux.org/master-keys/
HARDENED_KEY_FPR="E240B57E2C4630BA768E2F26FC1B547C8D8172C8"
HARDENED_GNUPGHOME="${BASE_DIR}/.hardened-gnupg"
SKIP_SIGCHECK="${SECUX_SKIP_SIGCHECK:-0}"

# только парсит патч и падает
patch_is_valid() {
    [ -s "$1" ] && git apply --stat "$1" >/dev/null 2>&1
}

download_file() {
    local url="$1" out="$2" tmp="${2}.part"
    rm -f "$tmp"
    # дофига атомарно и ибебебеб
    if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
            --connect-timeout 20 -o "$tmp" "$url"; then
        mv -f "$tmp" "$out"
    else
        rm -f "$tmp"
        return 1
    fi
}

gpg_hardened() {
    gpg --homedir "$HARDENED_GNUPGHOME" --batch "$@"
}

ensure_hardened_key() {
    mkdir -p -m 700 "$HARDENED_GNUPGHOME"
    gpg_hardened --list-keys "$HARDENED_KEY_FPR" >/dev/null 2>&1 && return 0

    local ks
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
        gpg_hardened --keyserver "$ks" --recv-keys "$HARDENED_KEY_FPR" >/dev/null 2>&1 || continue
        gpg_hardened --list-keys "$HARDENED_KEY_FPR" >/dev/null 2>&1 && return 0
    done
    return 1
}

# Проверяем detached-подпись и что там ожидаемый ключ
verify_patch_sig() {
    local patch="$1" sig="$2" status
    [ -s "$patch" ] && [ -s "$sig" ] || return 1
    status="$(gpg_hardened --status-fd 1 --verify "$sig" "$patch" 2>/dev/null)" || return 1
    printf '%s\n' "$status" | grep -q "^\[GNUPG:\] VALIDSIG ${HARDENED_KEY_FPR} "
}

hardened_patch_ok() {
    patch_is_valid "$HARDENED_PATCH" || return 1
    [ "$SKIP_SIGCHECK" = "1" ] && return 0
    verify_patch_sig "$HARDENED_PATCH" "$HARDENED_SIG"
}

# вырезаем из патча секции указанных файлов
strip_files_from_patch() {
    local patch="$1"; shift
    local list=" $* "
    awk -v list="$list" '
        /^diff --git / {
            skip = 0
            n = split(list, files, " ")
            for (i = 1; i <= n; i++)
                if (files[i] != "" && $4 == "b/" files[i]) skip = 1
        }
        !skip { print }
    ' "$patch"
}

# Накладываем патч сначала строго, затем всё более мягко
apply_patch() {
    local patch="$1"; shift
    local name; name="$(basename "$patch")"
    local excluded=() arg
    for arg in "$@"; do
        case "$arg" in
            --exclude=*) excluded+=("${arg#--exclude=}") ;;
        esac
    done

    if git apply --check "$@" "$patch" 2>/dev/null; then
        git apply "$@" "$patch"
        echo "  [OK] $name применен."
        return 0
    fi

    # Чистое 3-way слияние
    if git apply --check -3 "$@" "$patch" 2>/dev/null; then
        git apply -3 "$@" "$patch"
        echo "  [OK] $name применен через 3-way merge."
        return 0
    fi

    echo "  [~] $name: точное наложение не удалось, пробуем -C1 --recount..."
    if git apply --check -C1 --recount "$@" "$patch" 2>/dev/null; then
        git apply -C1 --recount "$@" "$patch"
        echo "  [OK] $name применен с уменьшенным контекстом."
        return 0
    fi

    # Последний шан - обычный patch с fuzz.
    echo "  [~] $name: пробуем patch -p1 -F3..."
    if ! command -v patch >/dev/null 2>&1; then
        echo "  [!] patch(1) не установлен (pacman -S patch), fuzz недоступен."
    else
        local filtered="$patch" tmp=""
        if [ ${#excluded[@]} -gt 0 ]; then
            tmp="$(mktemp)"
            strip_files_from_patch "$patch" "${excluded[@]}" > "$tmp"
            filtered="$tmp"
        fi
        if patch -p1 -N -F3 --dry-run -i "$filtered" >/dev/null 2>&1; then
            patch -p1 -N -F3 --no-backup-if-mismatch -i "$filtered"
            rm -f "$tmp"
            echo "  [OK] $name применен с fuzz."
            return 0
        fi
        rm -f "$tmp"
    fi

    echo "[!] Oopsie: Патч $name не ложится."
    git apply --check "$@" "$patch" || true
    return 1
}

if [ -f "config.secux" ]; then
    tr -d '\r' < "config.secux" > "config.secux.lf"
    mv "config.secux.lf" "config.secux"
fi

if [ "$SKIP_SIGCHECK" = "1" ]; then
    echo "> [!] Проверка подписи патча отключена (SECUX_SKIP_SIGCHECK=1)."
elif ! ensure_hardened_key; then
    echo "[!] Oopsie: не удалось получить ключ ${HARDENED_KEY_FPR}."
    echo "Проверьте сеть/keyserver. Обход (не рекомендуется): SECUX_SKIP_SIGCHECK=1"
    exit 1
fi

if hardened_patch_ok; then
    if [ "$SKIP_SIGCHECK" = "1" ]; then
        echo "> Используем локальный патч: ${HARDENED_PATCH} (подпись НЕ проверялась)"
    else
        echo "> Используем локальный патч: ${HARDENED_PATCH} (подпись проверена)"
    fi
else
    if [ -f "$HARDENED_PATCH" ]; then
        echo "> Локальный патч отсутствует, поврежден или не совпадает с подписью. Перекачиваем..."
    fi
    rm -f "$HARDENED_PATCH" "$HARDENED_SIG"
    echo "> Скачиваем Hardened-патч и подпись: ${HARDENED_TAG}..."
    if ! download_file "$HARDENED_URL" "$HARDENED_PATCH" \
       || ! download_file "$HARDENED_SIG_URL" "$HARDENED_SIG" \
       || ! hardened_patch_ok; then
        echo "[!] Oopsie: не удалось скачать или проверить ${HARDENED_PATCH}."
        echo "    Ожидался ключ ${HARDENED_KEY_FPR}."
        echo "    Обход проверки (не рекомендуется): SECUX_SKIP_SIGCHECK=1"
        exit 1
    fi
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
    rm -f .version # comment me if you want to increase pkgrel
    
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
    if [ "$CURRENT_TAG" != "v${KERNEL_VER}" ]; then
        echo "> Обновление до v${KERNEL_VER}..."
        git fetch --depth 1 origin tag "v${KERNEL_VER}"
        git checkout -f "v${KERNEL_VER}"
    fi
fi

echo "> Накладываем патчи..."

apply_patch "../$HARDENED_PATCH" --exclude=Makefile

sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION = -secux/' Makefile

apply_patch "../secuxlinux_ima.patch"

for patch_file in "../0001-amdgpu.patch" "../0002-amdgpu.patch"; do
    if [ -f "$patch_file" ]; then
        apply_patch "$patch_file"
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