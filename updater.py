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
    workdir = BASE_DIR / "linux-hardened"
    pkg_files = list(workdir.glob('linux-secux-*.pkg.tar.zst'))
    
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

def begin_build():
    build_script = BASE_DIR / "update_and_build.sh"
    logging.info("Starting update_and_build.sh...")
    try:
        subprocess.run(['bash', str(build_script)], check=True)
        logging.info("Build finished successfully.")
    except subprocess.CalledProcessError as e:
        logging.error(f"Build script failed with exit code {e.returncode}")
        sys.exit(e.returncode)

def main():
    try:
        resp = get("https://api.github.com/repos/anthraxx/linux-hardened/releases/latest", timeout=10)
        resp.raise_for_status()
        tag_name = resp.json()['tag_name']
    except Exception as e:
        logging.error(f"Failed to fetch GitHub release: {e}")
        sys.exit(1)

    if LAST_TAG_VERSION.exists():
        previous_version = LAST_TAG_VERSION.read_text().strip()
        if previous_version == tag_name:
            logging.info(f"Version {tag_name} already built. Exiting.")
            return
    
    logging.info(f"New version detected: {tag_name}. Starting build...")
    
    LAST_TAG_VERSION.write_text(tag_name)
    
    begin_build()
    check_packages()

if __name__ == "__main__":
    main()