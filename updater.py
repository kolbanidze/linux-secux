#!/usr/bin/env python3
import os
import sys
import logging
import subprocess
from pathlib import Path
from requests import get

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s: %(message)s')

BASE_DIR = Path(os.path.dirname(os.path.abspath(__file__)))
LAST_TAG_VERSION = BASE_DIR / "last-tag-version.txt"
INCOMING_DIR = Path("/home/server/incoming")

def check_packages():
    workdir = BASE_DIR / "linux-lts"
    pkg_files = list(workdir.glob('linux-secux-*'))
    
    if not pkg_files:
        logging.error("Build failed: No package files found.")
        sys.exit(1)

    logging.info(f"Found {len(pkg_files)} packages, moving to {INCOMING_DIR}")
    
    try:
        subprocess.run(['rsync', '-a'] + [str(p) for p in pkg_files] + [str(INCOMING_DIR)], check=True)
        logging.info("Packages successfully moved to incoming.")
    except subprocess.CalledProcessError as e:
        logging.error(f"Rsync failed: {e}")
        sys.exit(1)

def begin_build(tag_name):
    build_script = BASE_DIR / "update_and_build.sh"
    logging.info("Starting update_and_build.sh...")
    try:
        subprocess.run(['bash', str(build_script), tag_name], check=True)
        logging.info("Build finished successfully.")
    except subprocess.CalledProcessError as e:
        logging.error(f"Build script failed with exit code {e.returncode}")
        sys.exit(e.returncode)

def main():
    try:
        gitlab_url = "https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/PKGBUILD"
        pkgbuild_resp = get(gitlab_url, timeout=10)
        pkgbuild_resp.raise_for_status()
        
        arch_pkgver = None
        arch_pkgrel = None
        
        for line in pkgbuild_resp.text.splitlines():
            if line.startswith("pkgver="):
                arch_pkgver = line.split("=")[1].strip().strip("'\"")
            elif line.startswith("pkgrel="):
                arch_pkgrel = line.split("=")[1].strip().strip("'\"")
                
        if not arch_pkgver or not arch_pkgrel:
            logging.error("Не удалось спарсить pkgver и pkgrel из PKGBUILD")
            sys.exit(1)
            
        logging.info(f"Обнаружена версия в GitLab: {arch_pkgver}-{arch_pkgrel}")

        # Формируем базовую версию  "6.18" из "6.18.25"
        arch_version_parts = arch_pkgver.split('.')
        major_minor = f"{arch_version_parts[0]}.{arch_version_parts[1]}"

        gh_resp = get("https://api.github.com/repos/anthraxx/linux-hardened/releases", timeout=10)
        gh_resp.raise_for_status()
        
        target_tag = None
        for r in gh_resp.json():
            # Ищем последний доступный релиз для текущей ветки (например, v6.18.*-hardened)
            if r['tag_name'].startswith(f"v{major_minor}."):
                target_tag = r['tag_name']
                break

        if not target_tag:
            logging.info(f"Hardened-патч для текущей LTS версии ({arch_pkgver}) еще не готов. Ожидаем.")
            return

    except Exception as e:
        logging.error(f"Ошибка при проверке версий: {e}")
        sys.exit(1)

    # Формируем уникальный идентификатор сборки (LTS версия + версия патча)
    current_build = f"{arch_pkgver}-{arch_pkgrel}-{target_tag}"
    
    if LAST_TAG_VERSION.exists():
        previous_build = LAST_TAG_VERSION.read_text().strip()
        if previous_build == current_build:
            logging.info(f"Связка {current_build} уже собрана. Выход.")
            return
    
    logging.info(f"Найдено совпадение версий: LTS {arch_pkgver} и патч {target_tag}. Начинаем сборку...")
    
    LAST_TAG_VERSION.write_text(current_build)
    
    begin_build(target_tag)
    check_packages()

if __name__ == "__main__":
    main()