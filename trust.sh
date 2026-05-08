#!/bin/bash
set -e

echo "> Добавляем ключи Линуса Торвальдса и мейнтейнеров"

gpg --import linux-lts/keys/pgp/*.asc
