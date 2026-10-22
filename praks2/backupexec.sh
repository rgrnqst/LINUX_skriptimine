#!/usr/bin/env bash
#
# backupexec.sh - kausta varundamine kuupäevaga ja kontrolliga
#
# Autor: Roger-Romeo Arm, ITS24
#
# Skript teeb ühe käivitusega kõik ülesande punktid 1-11:
#   - kontrollib lähtekausta ja vajalikke käske
#   - loeb välistused failist <lähtekaust>/.backupignore (--exclude-from)
#   - kuiv jooks (-n): näitab, mis arhiivi läheks, arhiivi ei loo
#   - kontrollib olemasolevat arhiivi: kui pärast viimast koopiat pole
#     midagi muutunud, uut koopiat ei tehta (-f sunnib tegema)
#   - kontrollib vaba ruumi (du -sb ja df -B1 võrdlus)
#   - pakib ajutisse kausta (mktemp -d) kõigi olemasolevate kompressoritega
#     (zstd, xz, gzip) ja valib väikseima arhiivi
#   - kontrollib, et arhiiv avaneb (tar -t) ja sisaldab alamkaustu
#   - arvutab SHA-256 kontrollsumma ja kontrollib seda (sha256sum -c)
#   - hoiab alles ainult KEEP kõige uuemat koopiat
#   - logib kõik sammud ekraanile ja logifaili
#   - trap kustutab ajutised failid ka vea või Ctrl+C korral
#
# Kasutamine:
#   backupexec.sh [-n] [-f] [-v] [-c auto|zstd|xz|gzip] [-k N] [lähtekaust] [sihtkaust]
#
#   -n   kuiv jooks, arhiivi ei looda
#   -f   tee koopia ka siis, kui lähtekaust pole muutunud
#   -v   kontrolli kõiki olemasolevaid koopiaid (kontrollsumma + avanemine)
#   -c   kompressor, vaikimisi auto (proovib kõiki ja valib väikseima)
#   -k   mitu kõige uuemat koopiat alles hoida, vaikimisi 3
#   -h   abi
#
# Vaikimisi kaustad on seotud skripti asukohaga, mitte käivitamise kohaga,
# seega skripti võib käivitada ükskõik millisest kataloogist:
#   lähtekaust  <skripti kaust>/src
#   sihtkaust   <skripti kaust>/backup
#   logifail    <skripti kaust>/logs/backup.log
#
# Keskkonnamuutujad: KEEP, COMPRESSOR, LOG_FILE, RESERVE_MB (lisavaru MB, vaikimisi 10)
#
# Väljumiskoodid: 0 = korras (või polnud vaja varundada), 1 = viga, 2 = vale kasutus

set -euo pipefail

# ---------- Seaded ----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
KEEP="${KEEP:-3}"
COMPRESSOR="${COMPRESSOR:-auto}"
RESERVE_MB="${RESERVE_MB:-10}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/logs/backup.log}"
DRY_RUN=0
FORCE=0
VERIFY_ONLY=0
TMP_DIR=""

usage() {
    sed -n '/^# Kasutamine:/,/^# Väljumiskoodid:/s/^# \{0,1\}//p' "$0"
}

# ---------- Abifunktsioonid ----------

# log TASE TEKST - rida ajatempliga ekraanile ja logifaili
log() {
    local level=$1; shift
    local line
    line=$(printf '[%s] %-7s %s' "$(date '+%F %T')" "$level" "$*")
    printf '%s\n' "$line" >> "$LOG_FILE"
    if [[ $level == VIGA ]]; then
        printf '%s\n' "$line" >&2
    else
        printf '%s\n' "$line"
    fi
}

die() { log VIGA "$*"; exit 1; }

# Kuival jooksul ainult hoiatus, päris käivitusel viga
fail() { if (( DRY_RUN )); then log HOIATUS "$*"; else die "$*"; fi; }

human() { numfmt --to=iec --suffix=B "$1"; }

# Kompressori pakkimiskäsk ja faililaiend
comp_cmd() { case $1 in zstd) echo "zstd -19 -T0" ;; xz) echo "xz -9 -T0 -q" ;; gzip) echo "gzip -9" ;; esac; }
comp_ext() { case $1 in zstd) echo "tar.zst" ;; xz) echo "tar.xz" ;; gzip) echo "tar.gz" ;; esac; }

# Laiendi järgi lahtipakkija (tar -I lisab ise võtme -d)
comp_by_ext() { case $1 in *.zst) echo zstd ;; *.xz) echo xz ;; *.gz) echo gzip ;; esac; }

# Olemasolevad koopiad, uuemad ees (ls -1t)
list_backups() {
    ls -1t -- "$BACKUP_DIR/$NAME"_*.tar.{zst,xz,gz} 2>/dev/null || true
}

# trap: ajutiste failide kustutamine ja lõputeade, käivitub alati skripti lõpus
cleanup() {
    local rc=$?
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
        log INFO "Ajutine kaust kustutatud: $TMP_DIR"
    fi
    if (( rc == 0 )); then
        log INFO "===== LÕPP: korras ====="
    else
        log VIGA "===== LÕPP: viga (väljumiskood $rc) ====="
    fi
    exit "$rc"
}

# ---------- Argumendid ----------
while getopts ":nfvc:k:h" opt; do
    case $opt in
        n) DRY_RUN=1 ;;
        f) FORCE=1 ;;
        v) VERIFY_ONLY=1 ;;
        c) COMPRESSOR=$OPTARG ;;
        k) KEEP=$OPTARG ;;
        h) usage; exit 0 ;;
        :) echo "Võti -$OPTARG vajab väärtust" >&2; usage >&2; exit 2 ;;
        *) echo "Tundmatu võti: -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
(( $# <= 2 )) || { echo "Liiga palju argumente" >&2; usage >&2; exit 2; }

[[ $KEEP =~ ^[1-9][0-9]*$ ]] || { echo "KEEP peab olema positiivne täisarv: $KEEP" >&2; exit 2; }
[[ $RESERVE_MB =~ ^[0-9]+$ ]] || { echo "RESERVE_MB peab olema täisarv: $RESERVE_MB" >&2; exit 2; }
case $COMPRESSOR in auto|zstd|xz|gzip) ;; *) echo "Tundmatu kompressor: $COMPRESSOR" >&2; exit 2 ;; esac

# Absoluutsed teed, et töötaks sõltumata käivitamise kohast
SRC="$(readlink -m -- "${1:-$SCRIPT_DIR/src}")"
BACKUP_DIR="$(readlink -m -- "${2:-$SCRIPT_DIR/backup}")"
LOG_FILE="$(readlink -m -- "$LOG_FILE")"
NAME="$(basename "$SRC")"
PARENT="$(dirname "$SRC")"
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"

mkdir -p -- "$(dirname "$LOG_FILE")" || { echo "Logikausta ei saa luua: $(dirname "$LOG_FILE")" >&2; exit 1; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if (( DRY_RUN )); then
    log INFO "===== ALGUS (kuiv jooks): $SRC ====="
else
    log INFO "===== ALGUS: $SRC ====="
fi
log INFO "Sihtkaust: $BACKUP_DIR, logi: $LOG_FILE"

# ---------- 1. Eelkontrollid ----------
for cmd in tar sha256sum du df numfmt; do
    command -v "$cmd" >/dev/null || die "Käsku '$cmd' ei leitud"
done
[[ -d $SRC ]] || die "Lähtekausta pole olemas: $SRC"
[[ -r $SRC && -x $SRC ]] || die "Lähtekausta ei saa lugeda: $SRC"
case "$BACKUP_DIR/" in "$SRC"/*) die "Sihtkaust ei tohi olla lähtekausta sees" ;; esac
case "$LOG_FILE" in "$SRC"/*) die "Logifail ei tohi olla lähtekausta sees" ;; esac

# ---------- -v: olemasolevate koopiate kontroll ----------
if (( VERIFY_ONLY )); then
    total=0; bad=0
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        total=$((total + 1))
        b=$(basename "$f")
        if [[ ! -f $f.sha256 ]]; then
            log HOIATUS "$b: kontrollsumma fail puudub"
            bad=$((bad + 1))
        elif (cd "$BACKUP_DIR" && sha256sum --quiet -c -- "$b.sha256" >/dev/null 2>&1) \
             && tar -I "$(comp_by_ext "$f")" -tf "$f" >/dev/null 2>&1; then
            log OK "$b: kontrollsumma OK, arhiiv avaneb"
        else
            log VIGA "$b: VIGANE (kontrollsumma ei klapi või arhiiv ei avane)"
            bad=$((bad + 1))
        fi
    done < <(list_backups)
    (( total > 0 )) || die "Sihtkaustas pole ühtegi koopiat"
    (( bad == 0 )) || die "Vigaseid koopiaid: $bad / $total"
    log OK "Kõik $total koopiat on korras"
    exit 0
fi

# ---------- 2. Ajutine kaust ----------
# Päris käivitusel sihtkausta sees, et ruumikontroll kehtiks ja mv oleks samas failisüsteemis
if (( DRY_RUN )); then
    TMP_DIR=$(mktemp -d) || die "Ajutist kausta ei saa luua"
else
    mkdir -p -- "$BACKUP_DIR" || die "Sihtkausta ei saa luua: $BACKUP_DIR"
    [[ -w $BACKUP_DIR ]] || die "Sihtkausta ei saa kirjutada: $BACKUP_DIR"
    TMP_DIR=$(mktemp -d "$BACKUP_DIR/.tmp.XXXXXX") || die "Ajutist kausta ei saa luua"
fi
log INFO "Ajutine kaust: $TMP_DIR"

# ---------- 3. Välistused (.backupignore) ----------
# GNU tar ei sobita mustrit "imgs/" kaustaga, seega eemaldatakse lõpu-/,
# samuti kommentaarid, tühjad read ja Windowsi reavahetused.
EXCLUDES="$TMP_DIR/exclude.list"
: > "$EXCLUDES"
if [[ -f $SRC/.backupignore ]]; then
    sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e 's#/*[[:space:]]*$##' -e '/^$/d' \
        "$SRC/.backupignore" > "$EXCLUDES"
    log INFO "Välistused failist .backupignore: $(paste -sd' ' "$EXCLUDES")"
else
    log INFO "Faili .backupignore pole, midagi ei välistata"
fi
TAR_OPTS=(--exclude-from="$EXCLUDES")

# ---------- 4. Kompressorite valik ----------
if [[ $COMPRESSOR == auto ]]; then
    CANDIDATES=()
    for c in zstd xz gzip; do
        command -v "$c" >/dev/null && CANDIDATES+=("$c")
    done
    (( ${#CANDIDATES[@]} > 0 )) || die "Ühtegi kompressorit (zstd, xz, gzip) ei leitud"
    log INFO "Kompressor: auto, proovin: ${CANDIDATES[*]}"
else
    command -v "$COMPRESSOR" >/dev/null || die "Kompressorit '$COMPRESSOR' pole paigaldatud"
    CANDIDATES=("$COMPRESSOR")
    log INFO "Kompressor: $COMPRESSOR"
fi

# ---------- 5. Olemasoleva arhiivi kontroll ----------
LATEST=$(list_backups | sed -n '1p')
if [[ -n $LATEST ]]; then
    log INFO "Viimane olemasolev koopia: $(basename "$LATEST")"
    if [[ -z $(find "$SRC" -newer "$LATEST" -print -quit) ]]; then
        if (( FORCE )); then
            log INFO "Pärast viimast koopiat pole midagi muutunud, aga -f sunnib uue tegema"
        elif (( DRY_RUN )); then
            log INFO "Pärast viimast koopiat pole midagi muutunud, päris käivitusel uut koopiat ei tehtaks"
        else
            log INFO "Pärast viimast koopiat pole lähtekaustas midagi muutunud, uut koopiat ei tehta (sundimiseks -f)"
            exit 0
        fi
    else
        log INFO "Lähtekaustas on pärast viimast koopiat muudatusi"
    fi
else
    log INFO "Varasemaid koopiaid pole"
fi

# ---------- 6. Vaba ruumi kontroll ----------
# Halvim juht: iga proovitav arhiiv on sama suur kui lähtekaust + lisavaru
SRC_BYTES=$(du -sb -- "$SRC" | awk '{print $1}')
if (( DRY_RUN )) && [[ ! -d $BACKUP_DIR ]]; then
    DF_PATH=$(dirname "$BACKUP_DIR")
else
    DF_PATH=$BACKUP_DIR
fi
FREE_BYTES=$(df -P -B1 -- "$DF_PATH" | awk 'NR==2{print $4}')
NEED_BYTES=$(( SRC_BYTES * ${#CANDIDATES[@]} + RESERVE_MB * 1024 * 1024 ))
log INFO "Lähtekausta suurus $(human "$SRC_BYTES"), vaja $(human "$NEED_BYTES"), vaba $(human "$FREE_BYTES")"
if (( FREE_BYTES < NEED_BYTES )); then
    fail "Vaba ruumi pole piisavalt, varundust ei alustata"
else
    log OK "Vaba ruumi on piisavalt"
fi

# ---------- -n: kuiv jooks ----------
if (( DRY_RUN )); then
    log INFO "Arhiivi läheksid järgmised failid (arhiivi ei looda):"
    LISTING=$(tar "${TAR_OPTS[@]}" -cf - -C "$PARENT" "$NAME" | tar -tvf -) \
        || die "Failide loendamine ebaõnnestus"
    printf '%s\n' "$LISTING"
    log INFO "Kokku $(grep -c . <<< "$LISTING") kirjet, arhiivi nimi oleks ${NAME}_${STAMP}.tar.*"
    exit 0
fi

# ---------- 7. Pakkimine ja parima kompressori valik ----------
BEST=""; BEST_FILE=""; BEST_SIZE=""
for c in "${CANDIDATES[@]}"; do
    f="$TMP_DIR/${NAME}_${STAMP}.$(comp_ext "$c")"
    log INFO "Pakin: tar -I '$(comp_cmd "$c")'"
    if tar "${TAR_OPTS[@]}" -I "$(comp_cmd "$c")" -cf "$f" -C "$PARENT" "$NAME"; then
        size=$(stat -c %s -- "$f")
        log INFO "  $c: $(human "$size") ($size baiti)"
        if [[ -z $BEST_SIZE ]] || (( size < BEST_SIZE )); then
            BEST=$c; BEST_FILE=$f; BEST_SIZE=$size
        fi
    else
        log HOIATUS "  $c: pakkimine ebaõnnestus, jätan vahele"
        rm -f -- "$f"
    fi
done
[[ -n $BEST ]] || die "Ühegi kompressoriga ei õnnestunud arhiivi luua"
ARCHIVE=$(basename "$BEST_FILE")
log OK "Valitud kompressor: $BEST ($(human "$BEST_SIZE")), arhiiv $ARCHIVE"

# ---------- 8. Arhiivi kontroll: avaneb ja sisaldab alamkaustu ----------
LIST=$(tar -I "$BEST" -tf "$BEST_FILE" 2>&1) || die "Arhiiv ei avane: $LIST"
grep -qxF "$NAME/" <<< "$LIST" || die "Arhiivis puudub juurkaust $NAME/"
read -r N_DIRS N_FILES < <(awk -v top="$NAME/" '/\/$/ { if ($0 != top) d++; next } NF { f++ } END { print d+0, f+0 }' <<< "$LIST")
log INFO "Arhiivi esimesed read:"
head -n 5 <<< "$LIST" | sed 's/^/    /'
if (( N_DIRS > 0 )); then
    log OK "Arhiiv avaneb: $N_DIRS alamkausta, $N_FILES faili"
else
    log HOIATUS "Arhiiv avaneb, kuid alamkaustu pole ($N_FILES faili)"
fi

# ---------- 9. Kontrollsumma ja teisaldamine sihtkausta ----------
[[ ! -e $BACKUP_DIR/$ARCHIVE ]] || die "Arhiiv $ARCHIVE on juba olemas, üle ei kirjutata"
(cd "$TMP_DIR" && sha256sum -- "$ARCHIVE" > "$ARCHIVE.sha256") || die "Kontrollsumma arvutamine ebaõnnestus"
mv -n -- "$BEST_FILE" "$BEST_FILE.sha256" "$BACKUP_DIR/" || die "Arhiivi ei saa sihtkausta teisaldada"
if CHECK=$(cd "$BACKUP_DIR" && sha256sum -c -- "$ARCHIVE.sha256" 2>&1); then
    log OK "Kontrollsumma: $CHECK"
else
    rm -f -- "$BACKUP_DIR/$ARCHIVE" "$BACKUP_DIR/$ARCHIVE.sha256"
    die "Kontrollsumma ei klapi, vigane koopia kustutati: $CHECK"
fi

# ---------- 10. Vanade koopiate kustutamine ----------
mapfile -t OLD < <(list_backups | tail -n +"$((KEEP + 1))")
for f in "${OLD[@]}"; do
    rm -f -- "$f" "$f.sha256"
    log INFO "Kustutatud vana koopia: $(basename "$f")"
done
log INFO "Alles koopiaid: $(list_backups | grep -c . || true) (KEEP=$KEEP)"

log OK "VALMIS: $BACKUP_DIR/$ARCHIVE"
exit 0
