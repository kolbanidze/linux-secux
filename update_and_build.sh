#!/bin/bash
set -e

REPO_DIR="linux-hardened"
MY_PKGBASE="linux-secux"
CONFIG_FRAGMENT="config.secux"

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

echo "> Применяем модификации PKGBUILD..."
cd "$REPO_DIR"

sed -i "s/^pkgbase=.*/pkgbase=${MY_PKGBASE}/" PKGBUILD
sed -i 's/${pkgbase}-${_srctag}.patch/linux-hardened-${_srctag}.patch/' PKGBUILD
sed -i 's/export KBUILD_BUILD_HOST=archlinux/export KBUILD_BUILD_HOST=secuxlinux/' PKGBUILD
sed -i '/make htmldocs/d' PKGBUILD
sed -i '/"\$pkgbase-docs"/d' PKGBUILD
sed -i '/graphviz/d; /imagemagick/d; /python-sphinx/d; /texlive-latexextra/d' PKGBUILD
sed -i '/local pid_docs=$!/d' PKGBUILD
sed -i '/wait "${pid_docs}"/d' PKGBUILD
sed -i 's/tools\/bpf\/bpftool\/vmlinux.h//g' PKGBUILD
sed -i '/tools\/bpf\/bpftool/d' PKGBUILD

echo "> Внедряем патч IMA политики в PKGBUILD..."
cp ../secuxlinux_ima.patch .
sed -i "/^source=(/a \  'secuxlinux_ima.patch'" PKGBUILD

# Инъекция LLVM и KCFLAGS во все вызовы make внутри PKGBUILD
# Ищет точное слово make (в начале строки или после пробела) и добавляет аргументы
sed -i -E 's/(^|[[:space:]])make([[:space:]]|$)/\1make LLVM=1 LLVM_IAS=1 KCFLAGS="-march=x86-64-v3"\2/g' PKGBUILD

sed -i '/make.*olddefconfig/i \  # Инъекция флагов для DKMS\n  sed -i "1a LLVM=1\\nLLVM_IAS=1\\nexport LLVM LLVM_IAS" Makefile' PKGBUILD

echo "> Разрешение конфликтов Kconfig и слияние конфигов..."

# Точечное удаление дефолтных опций из блоков Choice, чтобы Kconfig не ругался
sed -i -E '/CONFIG_(LTO_NONE|DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT|DEBUG_INFO_DWARF4|DEBUG_INFO_DWARF5|DEBUG_INFO_BTF)=/d' config.x86_64

# Парсим наш фрагмент и удаляем любые старые упоминания этих ключей из базы
grep -E '^(# )?CONFIG_' "../$CONFIG_FRAGMENT" | sed -E 's/^# (CONFIG_[^ ]+) is not set/\1/; s/^(CONFIG_[^=]+)=.*/\1/' | while read -r conf; do
    sed -i "/^${conf}=/d" config.x86_64
    sed -i "/^# ${conf} is not set/d" config.x86_64
done

# Присоединение нашего кастомного фрагмента
cat "../$CONFIG_FRAGMENT" >> config.x86_64

echo "> Обновляем контрольные суммы..."
updpkgsums

echo "> Настройка окружения и запуск сборки..."
export MAKEFLAGS="-j$(nproc)"
export COMPRESSZST=(zstd -c -T0 --ultra -20 -)

makepkg -s --noconfirm

echo "> Готово! Пакеты ядра $MY_PKGBASE успешно собраны через LLVM."