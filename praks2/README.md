# Praks2 - varukoopia kuupaevaga ja kontrolliga

Roger-Romeo Arm, ITS24. Varundatav kaust: ~/skriptimine/praks2/src,
koopiad: backup/, logi: logs/backup.log (backup/ ja logs/ on .gitignore-s).

| Nr | Ulesanne | Kask |
|----|----------|------|
| 1 | Lihtne koopia | `tar -I 'zstd -19 -T0' -cf backup/src_$(date +%Y%m%d_%H%M%S).tar.zst -C ~/skriptimine/praks2 src` |
| 2 | Arhiivi kontroll | `tar -I 'zstd -d' -tf backup/src_*.tar.zst \| head -n 5` |
| 3 | Suurus | `du -h backup/src_*.tar.zst \| awk '{print $1}'` |
| 4 | 3 viimast koopiat | `ls -1t src_*.tar.zst \| tail -n +4 \| xargs -r rm -f` |
| 5 | Valistamine | `tar ... --exclude='*.jpg' --exclude='bin' -cf ...` |
| 6 | Kuiv jooks | `tar -cf - -C ~/skriptimine/praks2 src \| tar -tvf -` |
| 7 | Logimine | `echo "[ $(date '+%F %T') ] BACKUP START" >> logs/backup.log` |
| 8 | Vaba ruum | `du -sb src` vs `df -B1 backup \| awk 'NR==2{print $4}'` |
| 9 | SHA-256 | `sha256sum F > F.sha256; sha256sum -c F.sha256` |
| 10 | Kompressor | zstd: `-I 'zstd -19 -T0'`, gzip: `-z`, xz: `-J` |
| 11 | .backupignore | `tar --exclude-from=src/.backupignore ...` |

## backupexec.sh (ulesanne 12)

Teeb koik ulaltoodu uhe skriptiga: kuiv jooks (-n), vaba ruumi kontroll,
kontroll kas sama sisuga koopia on juba olemas (-f sunnib), kompressori
valik (-c auto valib vaikseima), valistused .backupignore failist,
arhiivi avanemise ja alamkaustade kontroll, SHA-256, logimine ja
ainult -k N uusima koopia hoidmine. Ajutised failid: mktemp -d + trap.

    ./backupexec.sh -n        # kuiv jooks
    ./backupexec.sh           # tavaline varundus
    ./backupexec.sh -f -c xz  # sunnitud koopia xz-ga

## home_bcp.sh

Kasutajate kodukataloogide varundus: iga /home/<kasutaja> pakitakse
faili <kasutaja>.<pp.kk.aaaa>.tar.gz ja kopeeritakse kausta /home_bcp.
Kaivitamine: `sudo ./home_bcp.sh` (tootab suvalisest kataloogist).
