#!/bin/bash
# backupexec.sh - kausta varundamine koos kontrollidega (praks2, ulesanne 12)
# Autor: Roger-Romeo Arm, ITS24
# Kasutus: ./backupexec.sh [-n] [-f] [-k N] [-c auto|zstd|gz|xz] [ALLIKAS] [SIHT]
#   -n  kuiv jooks: naitab arhiivi tulevaid faile, arhiivi ei loo
#   -f  tee koopia ka siis, kui allikas pole viimasest koopiast muutunud
#   -k  mitu uusimat koopiat alles jatta (vaikimisi 3)
#   -c  kompressor, auto = proovib koiki ja valib vaikseima arhiivi
# Vaikimisi ALLIKAS=<skripti kaust>/src ja SIHT=<skripti kaust>/backup,
# logi <skripti kaust>/logs/backup.log. Tootab suvalisest kataloogist.
set -uo pipefail

BASE=$(dirname "$(realpath "$0")")   # skripti enda kaust
DRY=0; FORCE=0; KEEP=3; COMP=auto
while getopts "nfk:c:h" opt; do
    case $opt in
        n) DRY=1 ;;
        f) FORCE=1 ;;
        k) KEEP=$OPTARG ;;
        c) COMP=$OPTARG ;;
        *) sed -n '2,10p' "$0"; exit 0 ;;
    esac
done
shift $((OPTIND - 1))

SRC=$(realpath "${1:-$BASE/src}")    # mida varundada
DEST=$(realpath -m "${2:-$BASE/backup}")  # kuhu varundada
LOG=$BASE/logs/backup.log
NAME=$(basename "$SRC")               # arhiivi juurkaust, nt src
PARENT=$(dirname "$SRC")              # tar -C kaust
STAMP=$(date +%Y%m%d_%H%M%S)          # kuupaev ja kellaaeg failinimes
IGNORE=$SRC/.backupignore             # valistuste fail

mkdir -p "$DEST" "$(dirname "$LOG")"
log() { printf '[ %s ] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
die() { log "VIGA: $*"; exit 1; }

TMP=$(mktemp -d)                      # ajutine kaust kompressorite testiks
trap 'rm -rf "$TMP"' EXIT             # kustutatakse alati, ka vea korral

[ -d "$SRC" ] || die "allikat $SRC ei ole olemas"
EXCL=()                               # valistused .backupignore failist
if [ -f "$IGNORE" ]; then
    # tar ei tunne mustrit kaldkriipsuga lopus (imgs/), see eemaldatakse;
    # tuhjad read ja # kommentaarid jaetakse vahele
    sed -e 's#/*$##' -e '/^#/d' -e '/^$/d' "$IGNORE" > "$TMP/ignore"
    EXCL=(--exclude-from="$TMP/ignore")
fi

# tar voog allikast (ilma pakkimata), kasutatakse kuivas jooksus ja vordluses
tar_stream() { tar "${EXCL[@]}" -cf - -C "$PARENT" "$NAME"; }

log "BACKUP START: $SRC -> $DEST"

# 1. kuiv jooks - ainult nimekiri, uut faili ei teki
if [ "$DRY" -eq 1 ]; then
    log "Kuiv jooks, arhiivi laheks:"
    tar_stream | tar -tvf -
    log "BACKUP END: kuiv jooks, arhiivi ei loodud"
    exit 0
fi

# 2. vaba ruumi kontroll: allika suurus vs vaba ruum sihtkaustas (baitides)
NEED=$(du -sb "$SRC" | awk '{print $1}')
FREE=$(df -B1 "$DEST" | awk 'NR==2{print $4}')
log "Allika suurus $NEED B, vaba ruum $FREE B"
[ "$NEED" -lt "$FREE" ] || die "sihtkaustas pole piisavalt vaba ruumi"

# 3. kas sama sisuga koopia on juba olemas (vordleb failide nimekirja,
#    suurusi ja muutmisaegu viimase koopiaga)
LAST=$(ls -1t "$DEST/$NAME"_*.tar.* 2>/dev/null | grep -v '\.sha256$' | head -n 1)
if [ -n "$LAST" ] && [ "$FORCE" -eq 0 ] &&
   diff -q <(tar -tvf "$LAST") <(tar_stream | tar -tvf -) >/dev/null; then
    log "Muudatusi pole, viimane koopia $(basename "$LAST") on ajakohane"
    log "BACKUP END: uut koopiat ei tehtud (-f sunnib tegema)"
    exit 0
fi

# 4. kompressori valik
make_tar() {   # $1 = kompressor, $2 = arhiivi fail
    case $1 in
        zstd) tar -I 'zstd -19 -T0' "${EXCL[@]}" -cf "$2" -C "$PARENT" "$NAME" ;;
        gz)   tar -z "${EXCL[@]}" -cf "$2" -C "$PARENT" "$NAME" ;;
        xz)   tar -J "${EXCL[@]}" -cf "$2" -C "$PARENT" "$NAME" ;;
        *)    return 1 ;;
    esac
}
if [ "$COMP" = auto ]; then
    for c in zstd gz xz; do
        make_tar "$c" "$TMP/test.$c" 2>/dev/null &&
            log "  test $c: $(stat -c %s "$TMP/test.$c") B"
    done
    COMP=$(ls -1Sr "$TMP"/test.* | head -n 1 | sed 's/.*test\.//')  # vaikseim
    log "Valitud kompressor: $COMP"
fi
case $COMP in
    zstd) EXT=tar.zst ;;
    gz)   EXT=tar.gz ;;
    xz)   EXT=tar.xz ;;
    *)    die "tundmatu kompressor $COMP" ;;
esac
ARCH=$DEST/${NAME}_$STAMP.$EXT
[ -e "$ARCH" ] && die "arhiiv $ARCH on juba olemas"

# 5. arhiivi loomine (auto puhul liigutatakse valmis testarhiiv)
if [ -f "$TMP/test.$COMP" ]; then
    mv "$TMP/test.$COMP" "$ARCH"
else
    make_tar "$COMP" "$ARCH" || die "arhiivi loomine ebaonnestus"
fi
log "Loodud $(basename "$ARCH"), suurus $(du -h "$ARCH" | awk '{print $1}')"

# 6. kontroll: arhiiv avaneb ja sisaldab alamkaustu
LIST=$(tar -tf "$ARCH") || die "arhiiv ei avane"
DIRS=$(grep -c '/$' <<< "$LIST")
[ "$DIRS" -gt 1 ] || die "arhiivis pole alamkaustu"
log "Arhiiv avaneb: $(wc -l <<< "$LIST") kirjet, $((DIRS - 1)) alamkausta"

# 7. SHA-256 kontrollsumma arvutamine ja kontroll
cd "$DEST" || die "ei saa minna kausta $DEST"
F=$(basename "$ARCH")
sha256sum "$F" > "$F.sha256"
sha256sum -c "$F.sha256" | tee -a "$LOG" || die "kontrollsumma ei klapi"

# 8. alles jaavad ainult KEEP uusimat koopiat (koos .sha256 failiga)
ls -1t "$NAME"_*.tar.* | grep -v '\.sha256$' | tail -n +$((KEEP + 1)) |
while read -r old; do
    rm -f "$old" "$old.sha256"
    log "Kustutatud vana koopia $old"
done

log "BACKUP END: OK, koopiaid alles $(ls -1 "$NAME"_*.tar.* | grep -vc '\.sha256$')"
