#!/usr/bin/env bash
#
# vpn-lab-tunnel.sh - PARTE 1 della demo: tunnel NON cifrato (IPIP oppure GRE)
#                     tra routerA e routerB.
#
# Prerequisito: il laboratorio deve essere acceso (sudo ./vpn-lab-up.sh).
#
# Cosa fa:
#   1. crea un'interfaccia "tun0" su ciascun router: e' l'estremita' del tunnel
#   2. le assegna un indirizzo (rete punto-punto 172.16.0.0/30)
#   3. aggiunge le rotte: "per raggiungere la rete privata dell'altro sito,
#      passa dal tunnel"
#   4. verifica che hostA riesca finalmente a raggiungere hostB
#
# Schema logico (la linea tratteggiata e' il tunnel, che in realta' viaggia
# dentro pacchetti normali sul segmento pubblico):
#
#   hostA --- routerA ======= tunnel (tun0) ======= routerB --- hostB
#   10.0.1.10  tun0=172.16.0.1  <-- rA-pub / rB-pub -->  tun0=172.16.0.2  10.0.2.10
#                  (203.0.113.1)                          (203.0.113.2)
#
# Uso:  sudo ./vpn-lab-tunnel.sh [ipip|gre]      (default: ipip)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

MODE="${1:-ipip}"
case "$MODE" in
    ipip|gre) ;;
    *) echo "Uso: sudo $0 [ipip|gre]" >&2; exit 1 ;;
esac

# Controlliamo che il laboratorio esista.
if ! ip netns list | grep -qw routerA; then
    echo "Laboratorio non trovato. Esegui prima:  sudo ./vpn-lab-up.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0) PULIZIA di un eventuale tunnel precedente
# ---------------------------------------------------------------------------
# Cosi' lo script e' ripetibile e puoi passare da ipip a gre (e viceversa)
# senza ricreare tutto il laboratorio. Eliminando tun0 spariscono anche le
# rotte che lo usavano.
ip -n routerA link del tun0 2>/dev/null || true
ip -n routerB link del tun0 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1) CREAZIONE DEL TUNNEL
# ---------------------------------------------------------------------------
# Un tunnel IPIP/GRE e' definito da due soli parametri:
#   local  = l'indirizzo IP "pubblico" di questo router (sorgente dei pacchetti
#            esterni)
#   remote = l'indirizzo IP "pubblico" dell'altro router (destinazione)
#
# Tutto cio' che viene inviato nell'interfaccia tun0 viene preso, messo dentro
# un nuovo pacchetto IP con questi indirizzi e spedito sul segmento pubblico.
# E' esattamente l'incapsulamento di cui parliamo nel seminario.
#
#   MODE=ipip : protocollo IP 4  -> [IP esterno][IP interno][dati]
#   MODE=gre  : protocollo IP 47 -> [IP esterno][header GRE][IP interno][dati]
#
# "type $MODE" sceglie il tipo di tunnel; il kernel carichera' da solo il
# modulo necessario (ipip oppure ip_gre) se non e' gia' presente.
ip -n routerA link add tun0 type "$MODE" local 203.0.113.1 remote 203.0.113.2
ip -n routerB link add tun0 type "$MODE" local 203.0.113.2 remote 203.0.113.1

# ---------------------------------------------------------------------------
# 2) INDIRIZZI DEL TUNNEL E ACCENSIONE
# ---------------------------------------------------------------------------
# Il tunnel e' come un cavo virtuale tra i due router: gli diamo una piccola
# rete punto-punto (/30, due soli indirizzi utilizzabili). Questi indirizzi
# sono quelli "interni" al tunnel e non compaiono mai sul segmento pubblico
# come indirizzi del collegamento: sul filo si vedono solo 203.0.113.1/.2 e,
# dentro, gli indirizzi dei pacchetti incapsulati.
ip -n routerA addr add 172.16.0.1/30 dev tun0
ip -n routerB addr add 172.16.0.2/30 dev tun0
ip -n routerA link set tun0 up
ip -n routerB link set tun0 up

# ---------------------------------------------------------------------------
# 3) ROTTE VERSO LE RETI PRIVATE REMOTE
# ---------------------------------------------------------------------------
# Questo e' il cuore del "site-to-site": routerA ora sa che la rete 10.0.2.0/24
# si raggiunge "attraverso il tunnel", passando per l'altro capo (172.16.0.2).
# E viceversa per routerB.
ip -n routerA route add 10.0.2.0/24 via 172.16.0.2 dev tun0
ip -n routerB route add 10.0.1.0/24 via 172.16.0.1 dev tun0

# ---------------------------------------------------------------------------
# 4) VERIFICA
# ---------------------------------------------------------------------------
echo "Tunnel $MODE attivo. Verifica:"

prova() {
    local desc="$1" ns="$2" dst="$3"
    if ip netns exec "$ns" ping -c1 -W1 -q "$dst" >/dev/null 2>&1; then
        printf '  [ OK ]    %s\n' "$desc"
    else
        printf '  [FALLITO] %s\n' "$desc"
    fi
}

prova "routerA -> routerB attraverso il tunnel (172.16.0.2)" routerA 172.16.0.2
prova "hostA   -> hostB   (10.0.2.10)  <-- prima falliva"    hostA   10.0.2.10
prova "hostB   -> hostA   (10.0.1.10)"                       hostB   10.0.1.10

echo
echo "Dettagli utili da mostrare:"
echo "  sudo ip -n routerA addr show tun0     # l'interfaccia del tunnel (nota l'MTU)"
echo "  sudo ip -n routerA route              # le rotte: 10.0.2.0/24 passa da tun0"
echo "  sudo ip -d -n routerA link show tun0  # dettagli: tipo, local, remote"
