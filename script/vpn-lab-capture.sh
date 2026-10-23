#!/usr/bin/env bash
#
# vpn-lab-capture.sh - Genera traffico attraverso il tunnel e lo cattura
#                      in DUE punti, per confrontare "fuori" e "dentro".
#
# Funziona con qualunque tunnel del laboratorio (ipip, gre, wireguard):
# basta indicare il nome dell'interfaccia del tunnel (tun0 oppure wg0).
#
# Punti di cattura (sempre su routerA):
#   - rA-pub : l'interfaccia verso il segmento PUBBLICO. Qui si vede il pacchetto
#              come viaggerebbe su Internet: incapsulato (e, con WireGuard, cifrato).
#   - TUNNEL : l'interfaccia del tunnel (tun0 o wg0). Qui si vede il pacchetto
#              originale, gia' "scartato dalla busta" (e decifrato).
#
# Traffico generato (da hostA verso hostB, attraverso il tunnel):
#   - 3 ping
#   - una richiesta HTTP a una pagina che contiene una frase riconoscibile,
#     per verificare se il contenuto si legge in chiaro sul segmento pubblico
#
# Le catture vengono salvate in file .pcap che puoi aprire con Wireshark.
#
# NOTA su WireGuard: l'handshake avviene al PRIMO traffico dopo la creazione del
# tunnel. Per catturarlo, crea il tunnel con  sudo ./vpn-lab-wireguard.sh --senza-test
# (cosi' non genera traffico di verifica) e lancia subito dopo questo script.
#
# Prerequisiti: laboratorio acceso + tunnel attivo, tcpdump e python3 installati.
# Uso:  sudo ./vpn-lab-capture.sh [cartella-output] [interfaccia-tunnel]
#       default: ./catture  e  tun0
#       esempio WireGuard:  sudo ./vpn-lab-capture.sh ./catture-wg wg0

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

for cmd in tcpdump python3; do
    command -v "$cmd" >/dev/null || { echo "Manca il comando: $cmd" >&2; exit 1; }
done

OUT="${1:-./catture}"
IF="${2:-tun0}"

if ! ip -n routerA link show "$IF" >/dev/null 2>&1; then
    echo "Interfaccia '$IF' non trovata in routerA." >&2
    echo "Crea prima il tunnel:  sudo ./vpn-lab-tunnel.sh [ipip|gre]  oppure  sudo ./vpn-lab-wireguard.sh" >&2
    exit 1
fi

mkdir -p "$OUT"
EXT="$OUT/esterno-rA-pub.pcap"
INT="$OUT/interno-$IF.pcap"
WWW="$(mktemp -d)"
FRASE="MESSAGGIO-SEGRETO-DAL-SITO-B"
echo "<html><body>$FRASE</body></html>" > "$WWW/index.html"

PIDS=()
cleanup() {
    # SIGTERM: tcpdump chiude il file pcap in modo pulito e il server HTTP termina.
    # (Non usiamo SIGINT: i processi lanciati in background da uno script
    # ignorano Ctrl-C/SIGINT, e Python rispetta questa impostazione.)
    for p in "${PIDS[@]:-}"; do
        [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$WWW"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# AVVIO DELLE CATTURE
# ---------------------------------------------------------------------------
# "ip netns exec routerA tcpdump ..." esegue tcpdump DENTRO il namespace routerA.
#   -i IF   interfaccia da ascoltare
#   -n      non risolvere i nomi (piu' veloce, output piu' chiaro)
#   -U      scrivi su file subito, senza bufferizzare (nessun pacchetto perso)
#   -w FILE salva in formato pcap (apribile con Wireshark)
ip netns exec routerA tcpdump -i rA-pub -n -U -w "$EXT" 'not arp' 2>/dev/null &
PIDS+=($!)
ip netns exec routerA tcpdump -i "$IF" -n -U -w "$INT" 2>/dev/null &
PIDS+=($!)

# Aspettiamo che tcpdump sia davvero partito (crea il file .pcap appena e' pronto),
# cosi' non perdiamo i primi pacchetti. Meglio di un "sleep" a tempo fisso.
for _ in $(seq 1 50); do
    [[ -s "$EXT" && -s "$INT" ]] && break
    sleep 0.2
done

# ---------------------------------------------------------------------------
# GENERAZIONE DEL TRAFFICO
# ---------------------------------------------------------------------------
# Un piccolo server web dentro hostB...
ip netns exec hostB python3 -m http.server 8080 --bind 10.0.2.10 --directory "$WWW" >/dev/null 2>&1 &
PIDS+=($!)

# Aspettiamo che il server accetti connessioni. Il test e' fatto DENTRO hostB
# (connessione locale), quindi non genera traffico sul tunnel e non sporca la cattura.
# "/dev/tcp/IP/PORTA" e' una funzione di bash per aprire una connessione TCP.
for _ in $(seq 1 100); do
    ip netns exec hostB bash -c 'exec 3<>/dev/tcp/10.0.2.10/8080' 2>/dev/null && break
    sleep 0.2
done

# ...e un client dentro hostA che lo contatta attraverso il tunnel.
echo "== Traffico di prova da hostA a hostB =="
ip netns exec hostA ping -c3 -W3 -q 10.0.2.10 | tail -n 2
ip netns exec hostA python3 -c "
import urllib.request
print('Risposta HTTP ricevuta:', urllib.request.urlopen('http://10.0.2.10:8080/', timeout=5).read().decode().strip())
"
sleep 1

# Fermiamo le catture prima di leggere i file.
cleanup
trap - EXIT
PIDS=()

# ---------------------------------------------------------------------------
# RIEPILOGO
# ---------------------------------------------------------------------------
echo
echo "== Cattura ESTERNA (rA-pub): il traffico come viaggia sul segmento pubblico =="
tcpdump -nn -v -r "$EXT" 2>/dev/null | grep -A1 'proto' | head -n 8 || true

echo
echo "== Cattura INTERNA ($IF): solo il pacchetto originale =="
tcpdump -nn -r "$INT" 2>/dev/null | head -n 4 || true

echo
echo "== La frase segreta si legge in chiaro? =="
for f in "$EXT" "$INT"; do
    if tcpdump -nn -A -r "$f" 2>/dev/null | grep -q "$FRASE"; then
        printf '   SI'"'"'  in chiaro in: %s\n' "$f"
    else
        printf '   NO   non leggibile in: %s\n' "$f"
    fi
done

echo
echo "File salvati in: $OUT"
ls -1 "$OUT"
echo "Aprili con Wireshark per l'analisi dettagliata."
