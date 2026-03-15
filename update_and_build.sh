#!/bin/bash
set -e

REPO_DIR="linux-hardened"
MY_PKGBASE="linux-secux"
CONFIG_FRAGMENT="config.secux"

if [ ! -d "$REPO_DIR" ]; then
    echo "> Клонируем linux-hardened..."
    pkgctl repo clone --protocol=https linux-hardened
else
    echo "> Обновляем linux-hardened..."
    cd $REPO_DIR
    git reset --hard HEAD
    git clean -fdx
    git pull
    cd ..
fi

echo "> Применяем модификации..."

sed -i "s/^pkgbase=.*/pkgbase=${MY_PKGBASE}/" $REPO_DIR/PKGBUILD
sed -i 's/${pkgbase}-${_srctag}.patch/linux-hardened-${_srctag}.patch/' $REPO_DIR/PKGBUILD
sed -i '/make htmldocs/d' $REPO_DIR/PKGBUILD
sed -i '/"\$pkgbase-docs"/d' $REPO_DIR/PKGBUILD
sed -i '/graphviz/d; /imagemagick/d; /python-sphinx/d; /texlive-latexextra/d' $REPO_DIR/PKGBUILD
sed -i '/local pid_docs=$!/d' $REPO_DIR/PKGBUILD
sed -i '/wait "${pid_docs}"/d' $REPO_DIR/PKGBUILD

# При сборке make olddefconfig отдаст приоритет последним строкам.
cat $REPO_DIR/config.x86_64 $CONFIG_FRAGMENT > $REPO_DIR/config.x86_64.tmp
mv $REPO_DIR/config.x86_64.tmp $REPO_DIR/config.x86_64

echo "> Переключаем сборку на LLVM, LTO и x86-64-v3..."

# LLVM=1 автоматически подтянет clang, lld, llvm-ar.
# KCFLAGS="-march=x86-64-v3" заставит ядро использовать AVX/AVX2 инструкции.
sed -i 's/make all/make LLVM=1 KCFLAGS="-march=x86-64-v3" all/g' $REPO_DIR/PKGBUILD
sed -i 's/make modules_install/make LLVM=1 KCFLAGS="-march=x86-64-v3" modules_install/g' $REPO_DIR/PKGBUILD
sed -i 's/make -s olddefconfig/make LLVM=1 -s olddefconfig/g' $REPO_DIR/PKGBUILD

# Arch Linux по умолчанию имеет отключенный LTO в базовом конфиге (CONFIG_LTO_NONE=y).
# Нам нужно гарантированно вырезать этот параметр перед слиянием с нашим CONFIG_FRAGMENT (config.secux)
sed -i '/CONFIG_LTO_NONE=y/d' $REPO_DIR/config.x86_64

# Финальная подготовка
cd $REPO_DIR

echo "> Обновляем контрольные суммы..."
updpkgsums

echo "> Запускаем сборку..."
makepkg -s

echo "> Готово. Пакеты лежат в папке $REPO_DIR"