from requests import get
from json import loads as json_decode
from json import dumps as json_encode
import os
from subprocess import run
from pathlib import Path

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LAST_TAG_VERSION = "last-tag-version.txt"
PATH_TO_INCOMING_FOLDER = "/home/server/incoming"

def check_packages():
    workdir = Path(f"{BASE_DIR}/linux-hardened")
    files = list(workdir.glob("*.pkg.tar.zst*"))
    if len(files) != 4:
        print("Something went wrong during build process.")
        return
    pkg_files = list(workdir.glob('linux-secux*'))
    run(['rsync', '-a'] + pkg_files + ['/home/server/incoming/'], check=True, capture_output=False)

def begin_build():
    # os.chdir(BASE_DIR)
    run(['bash', f"{BASE_DIR}/update_and_build.sh"], capture_output=False, check=False)

def main():
    resp = get("https://api.github.com/repos/anthraxx/linux-hardened/releases/latest")
    if resp.status_code != 200:
        return
    linux_hardened_json = json_decode(resp.content)
    tag_name = linux_hardened_json['tag_name']

    if os.path.isfile(LAST_TAG_VERSION): 
        with open(f"{BASE_DIR}/{LAST_TAG_VERSION}", "r+") as file:
            previous_version = file.read()
            if previous_version == tag_name:
                print("[*] No new versions arrived. Exitting...")
                return
            else:
                file.seek(0)
                file.write(tag_name)
    else:
        with open(f"{BASE_DIR}/{LAST_TAG_VERSION}", "w") as file:
            file.write(tag_name)
    
    begin_build()
    check_packages()
    


if __name__ == "__main__":
    main()