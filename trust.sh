#!/bin/bash
set -e

echo "> Добавляем ключи Линуса Торвальдса и мейнтейнеров"

gpg --import linux-hardened/keys/pgp/*.asc
