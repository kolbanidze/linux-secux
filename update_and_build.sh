#!/bin/bash
set -e

REPO_DIR="linux-lts"
MY_PKGBASE="linux-secux"
CONFIG_FRAGMENT="config.secux"

TARGET_TAG="$1"
if [ -z "$TARGET_TAG" ]; then
    echo "Ошибка: Не передан тег hardened-патча"
    exit 1
fi

HARDENED_PATCH="linux-hardened-${TARGET_TAG}.patch"
HARDENED_URL="https://github.com/anthraxx/linux-hardened/releases/download/${TARGET_TAG}/${HARDENED_PATCH}"

if [ ! -d "$REPO_DIR" ]; then
    echo "> Клонируем $REPO_DIR..."
    pkgctl repo clone --protocol=https $REPO_DIR
else
    echo "> Обновляем $REPO_DIR..."
    cd "$REPO_DIR"
    git reset --hard HEAD
    git clean -fdx
    git pull
    cd ..
fi

echo "> Скачиваем Hardened-патч локально..."
cd "$REPO_DIR"
curl -L -o "$HARDENED_PATCH" "$HARDENED_URL"

echo "> Вырезаем изменения Makefile во избежание конфликтов SUBLEVEL..."
# patchutils is needed
filterdiff -x 'a/Makefile' -x 'b/Makefile' "$HARDENED_PATCH" > "${HARDENED_PATCH}.clean"
mv "${HARDENED_PATCH}.clean" "$HARDENED_PATCH"

echo "> Внедряем Hardened-патч и IMA политику в PKGBUILD..."
cp ../secuxlinux_ima.patch .

# Удаляем конфликтующий ZEN-патч из исходников Arch LTS
sed -i '/0001-ZEN-Add-sysctl-and-CONFIG-to-disallow-unprivileged-C.patch/d' PKGBUILD

sed -i "/^source=(/a \  'secuxlinux_ima.patch'\n  '${HARDENED_PATCH}'" PKGBUILD

sed -i 's/export KBUILD_BUILD_HOST=archlinux/export KBUILD_BUILD_HOST=secuxlinux/' PKGBUILD
sed -i '/make htmldocs/d' PKGBUILD
sed -i '/"\$pkgbase-docs"/d' PKGBUILD
sed -i '/graphviz/d; /imagemagick/d; /python-sphinx/d; /texlive-latexextra/d' PKGBUILD
sed -i '/local pid_docs=$!/d' PKGBUILD
sed -i '/wait "${pid_docs}"/d' PKGBUILD
sed -i 's/tools\/bpf\/bpftool\/vmlinux.h//g' PKGBUILD
sed -i '/tools\/bpf\/bpftool/d' PKGBUILD
sed -i '/tools\/bpf\/resolve_btfids\/resolve_btfids/d' PKGBUILD

# Инъекция LLVM и KCFLAGS во все вызовы make внутри PKGBUILD
# Ищет точное слово make (в начале строки или после пробела) и добавляет аргументы
sed -i -E 's/(^|[[:space:]])make([[:space:]]|$)/\1make LLVM=1 LLVM_IAS=1 KCFLAGS="-march=x86-64-v3"\2/g' PKGBUILD

sed -i '/make.*olddefconfig/i \  # Инъекция флагов для DKMS\n  sed -i "1a LLVM=1\\nLLVM_IAS=1\\nexport LLVM LLVM_IAS" Makefile' PKGBUILD

echo "> Разрешение конфликтов Kconfig и слияние конфигов..."

sed -i -E '/CONFIG_(LTO_NONE|DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT|DEBUG_INFO_DWARF4|DEBUG_INFO_DWARF5|DEBUG_INFO_BTF)=/d' config

grep -E '^(# )?CONFIG_' "../$CONFIG_FRAGMENT" | sed -E 's/^# (CONFIG_[^ ]+) is not set/\1/; s/^(CONFIG_[^=]+)=.*/\1/' | while read -r conf; do
    sed -i "/^${conf}=/d" config
    sed -i "/^# ${conf} is not set/d" config
done

# Присоединение нашего кастомного фрагмента
cat "../$CONFIG_FRAGMENT" >> config

echo "> Обновляем контрольные суммы..."
updpkgsums

echo "> Настройка окружения и запуск сборки..."
export MAKEFLAGS="-j$(nproc)"

sed -i "1i COMPRESSZST=(zstd -c -T0 --ultra -20 -)" PKGBUILD

makepkg -s --noconfirm

echo "> Готово! Пакеты ядра $MY_PKGBASE успешно собраны через LLVM."