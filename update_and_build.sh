#!/bin/bash
set -e

REPO_DIR="linux-hardened"
MY_PKGBASE="linux-secux"
CONFIG_FRAGMENT="config.ima"

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

# Финальная подготовка
cd $REPO_DIR

echo "> Обновляем контрольные суммы..."
updpkgsums

echo "> Запускаем сборку..."
makepkg -s

echo "> Готово. Пакеты лежат в папке $REPO_DIR"