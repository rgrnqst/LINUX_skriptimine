#!/bin/bash
# home_bcp.sh - kasutajate kodukataloogide varundamine
# Autor: Roger-Romeo Arm, ITS24
# Iga /home all oleva kasutaja kodukataloog pakitakse eraldi arhiivi
# kujul <kasutaja>.<pp.kk.aaaa>.tar.gz ja kopeeritakse kausta /home_bcp.
# Kaivitamine: sudo ./home_bcp.sh  (tootab suvalisest kataloogist,
# sest koik teed on absoluutsed ja tar kasutab -C /home)

SRC=/home                # kodukataloogide asukoht
DEST=/home_bcp           # varukoopiate kaust
DATE=$(date +%d.%m.%Y)   # varundamise kuupaev, nt 21.10.2026

# teiste kasutajate failide lugemiseks on vaja root oigusi
if [ "$EUID" -ne 0 ]; then
    echo "Viga: kaivita root oigustes: sudo $0" >&2
    exit 1
fi

mkdir -p "$DEST"         # loo varukaust, kui seda veel pole
chmod 700 "$DEST"        # varukoopiaid naeb ainult root

TMP=$(mktemp -d)         # arhiivid tehakse esmalt ajutisse kausta
trap 'rm -rf "$TMP"' EXIT

for dir in "$SRC"/*/; do                 # iga kodukataloog /home all
    user=$(basename "$dir")              # kataloogi nimi = kasutaja nimi
    file="$user.$DATE.tar.gz"
    # -c loo, -z paki gzipiga, -f fail, -C /home -> arhiivis on tee user/...
    if tar -czf "$TMP/$file" -C "$SRC" "$user" && cp "$TMP/$file" "$DEST/"; then
        echo "OK: $user -> $DEST/$file ($(du -h "$DEST/$file" | cut -f1))"
    else
        echo "VIGA: kasutaja $user varundamine ebaonnestus" >&2
    fi
done
