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

LTS_BRANCH = "6.18"

def begin_build(kernel_ver, hardened_tag):
    build_script = BASE_DIR / "build.sh"
    logging.info(f"Запуск сборки: Ядро {kernel_ver} + Патч {hardened_tag}")
    try:
        subprocess.run(['bash', str(build_script), kernel_ver, hardened_tag], check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Сборка прервана (вероятно, конфликт патча). Код: {e.returncode}")
        sys.exit(e.returncode)

def main():
    try:
        korg_resp = get("https://www.kernel.org/releases.json", timeout=10)
        korg_resp.raise_for_status()
        
        latest_kernel = None
        for release in korg_resp.json()['releases']:
            if release['version'].startswith(f"{LTS_BRANCH}."):
                latest_kernel = release['version']
                break
                
        if not latest_kernel:
            logging.error(f"Не найдена версия {LTS_BRANCH} на kernel.org")
            sys.exit(1)

        gh_resp = get("https://api.github.com/repos/anthraxx/linux-hardened/releases", timeout=10)
        gh_resp.raise_for_status()
        
        latest_hardened = None
        for r in gh_resp.json():
            if r['tag_name'].startswith(f"v{LTS_BRANCH}."):
                latest_hardened = r['tag_name']
                break

        if not latest_hardened:
            logging.info(f"Релизов для ветки {LTS_BRANCH} от anthraxx не найдено.")
            sys.exit(0)

    except Exception as e:
        logging.error(f"Ошибка получения версий: {e}")
        sys.exit(1)

    current_build = f"{latest_kernel}_{latest_hardened}"
    
    if LAST_TAG_VERSION.exists():
        previous_build = LAST_TAG_VERSION.read_text().strip()
        if previous_build == current_build:
            logging.info(f"Связка {current_build} уже собрана. Выход.")
            return
    
    logging.info(f"Новая связка найдена: {current_build}. Пробуем собрать...")
    
    begin_build(latest_kernel, latest_hardened)
    
    LAST_TAG_VERSION.write_text(current_build)

if __name__ == "__main__":
    main()