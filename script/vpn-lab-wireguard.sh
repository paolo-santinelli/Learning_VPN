#!/usr/bin/env bash
#
# vpn-lab-wireguard.sh - PARTE 2 della demo: tunnel CIFRATO con WireGuard
#                        tra routerA e routerB.
#
# Prerequisiti:
#   - laboratorio acceso (sudo ./vpn-lab-up.sh)
#   - pacchetto wireguard-tools installato (fornisce il comando "wg")
#       Debian/Ubuntu:  sudo apt install wireguard-tools
#   - kernel Linux 5.6 o successivo (WireGuard e' incluso nel kernel)
#
# Cosa fa:
#   1. genera una coppia di chiavi (privata + pubblica) per ciascun router
#   2. crea l'interfaccia wg0 in ciascun router
#   3. configura ogni router con la propria chiave privata e la chiave PUBBLICA
#      dell'altro (il "peer"), piu' gli AllowedIPs
#   4. assegna gli indirizzi del tunnel e aggiunge le rotte
#   5. verifica che hostA raggiunga hostB e mostra lo stato con "wg show"
#
# Se esiste gia' un tunnel della Parte 1 (tun0), viene rimosso: le rotte
# verso le subnet remote passano cosi' da wg0 invece che da tun0.
#
# Uso:  sudo ./vpn-lab-wireguard.sh
#       sudo ./vpn-lab-wireguard.sh --senza-test   # salta la verifica finale, cosi'
#                                                  # l'handshake avviene al primo
#                                                  # traffico che genererai tu (utile
#                                                  # per catturarlo)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

if ! command -v wg >/dev/null; then
    echo "Manca il comando 'wg'. Installalo con:  sudo apt install wireguard-tools" >&2
    exit 1
fi

if ! ip netns list | grep -qw routerA; then
    echo "Laboratorio non trovato. Esegui prima:  sudo ./vpn-lab-up.sh" >&2
    exit 1
fi

KEYDIR="${KEYDIR:-./chiavi-wg}"
PORTA=51820

# ---------------------------------------------------------------------------
# 0) PULIZIA di eventuali tunnel precedenti (Parte 1 o esecuzioni precedenti)
# ---------------------------------------------------------------------------
for ns in routerA routerB; do
    ip -n "$ns" link del tun0 2>/dev/null || true
    ip -n "$ns" link del wg0  2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 1) GENERAZIONE DELLE CHIAVI
# ---------------------------------------------------------------------------
# In WireGuard l'identita' di un peer E' la sua chiave pubblica. Non ci sono
# certificati ne' autorita' di certificazione: ogni lato ha
#   - una chiave PRIVATA (segreta, non lascia mai il router)
#   - una chiave PUBBLICA, derivata dalla privata, che si puo' dare a chiunque
#
#   wg genkey          -> genera una chiave privata
#   wg pubkey          -> legge una privata da stdin e stampa la pubblica
#
# "umask 077" fa si' che i file creati siano leggibili solo dal proprietario:
# una chiave privata non dovrebbe mai essere leggibile da altri.
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"
for r in routerA routerB; do
    ( umask 077; wg genkey > "$KEYDIR/$r.key" )
    wg pubkey < "$KEYDIR/$r.key" > "$KEYDIR/$r.pub"
done
PUB_A="$(cat "$KEYDIR/routerA.pub")"
PUB_B="$(cat "$KEYDIR/routerB.pub")"

# ---------------------------------------------------------------------------
# 2) CREAZIONE DELLE INTERFACCE wg0
# ---------------------------------------------------------------------------
# Come per IPIP/GRE, il tunnel e' un'interfaccia di rete virtuale; qui il tipo
# e' "wireguard". Il kernel carica il modulo da solo se serve.
ip -n routerA link add wg0 type wireguard
ip -n routerB link add wg0 type wireguard

# ---------------------------------------------------------------------------
# 3) CONFIGURAZIONE DEI PEER
# ---------------------------------------------------------------------------
# "wg set" configura l'interfaccia. Va eseguito DENTRO il namespace, quindi
# "ip netns exec NS wg set ...". Parametri:
#
#   private-key FILE   la chiave privata di QUESTO router
#   listen-port N      porta UDP su cui WireGuard ascolta
#   peer CHIAVE        l'altro router, identificato dalla sua chiave PUBBLICA
#   endpoint IP:PORTA  dove si trova l'altro router (l'indirizzo "pubblico")
#   allowed-ips LISTA  il parametro piu' originale di WireGuard ("cryptokey
#                      routing"). Ha un doppio ruolo:
#                        - in USCITA: i pacchetti destinati a questi indirizzi
#                          vengono cifrati per QUESTO peer
#                        - in ENTRATA: un pacchetto decifrato da questo peer
#                          viene accettato solo se il suo IP sorgente rientra
#                          in questa lista (protezione anti-spoofing gratuita)
#
# Per routerA, il peer (routerB) e' responsabile di:
#   172.16.0.2/32  l'indirizzo del suo capo del tunnel
#   10.0.2.0/24    la rete privata del sito B
ip netns exec routerA wg set wg0 \
    private-key "$KEYDIR/routerA.key" \
    listen-port "$PORTA" \
    peer "$PUB_B" \
        endpoint 203.0.113.2:"$PORTA" \
        allowed-ips 172.16.0.2/32,10.0.2.0/24

ip netns exec routerB wg set wg0 \
    private-key "$KEYDIR/routerB.key" \
    listen-port "$PORTA" \
    peer "$PUB_A" \
        endpoint 203.0.113.1:"$PORTA" \
        allowed-ips 172.16.0.1/32,10.0.1.0/24

# ---------------------------------------------------------------------------
# 4) INDIRIZZI, ACCENSIONE E ROTTE
# ---------------------------------------------------------------------------
# Stessa rete punto-punto 172.16.0.0/30 usata nella Parte 1, cosi' il
# confronto tra i due tunnel e' diretto.
ip -n routerA addr add 172.16.0.1/30 dev wg0
ip -n routerB addr add 172.16.0.2/30 dev wg0
ip -n routerA link set wg0 up
ip -n routerB link set wg0 up

# Le rotte verso le subnet remote passano da wg0. Attenzione: AllowedIPs NON
# crea le rotte nel sistema operativo (le aggiungerebbe "wg-quick", che qui non
# usiamo): decide solo a quale peer cifrare un pacchetto che gia' esce da wg0.
# La rotta serve a far arrivare il pacchetto a wg0.
ip -n routerA route add 10.0.2.0/24 dev wg0
ip -n routerB route add 10.0.1.0/24 dev wg0

echo "Tunnel WireGuard configurato."

# ---------------------------------------------------------------------------
# 5) VERIFICA
# ---------------------------------------------------------------------------
# WireGuard non ha una fase di "connessione": l'handshake parte da solo al
# primo pacchetto da inviare. Per questo la verifica usa piu' tentativi
# (-c2) e un'attesa piu' lunga (-W3): il primo ping include l'handshake.
if [[ "${1:-}" == "--senza-test" ]]; then
    echo "Verifica saltata (--senza-test): nessun traffico e' ancora passato, quindi"
    echo "l'handshake non e' ancora avvenuto."
else
    prova() {
        local desc="$1" ns="$2" dst="$3"
        if ip netns exec "$ns" ping -c2 -W3 -q "$dst" >/dev/null 2>&1; then
            printf '  [ OK ]    %s\n' "$desc"
        else
            printf '  [FALLITO] %s\n' "$desc"
        fi
    }
    echo "Verifica:"
    prova "routerA -> routerB attraverso il tunnel (172.16.0.2)" routerA 172.16.0.2
    prova "hostA   -> hostB   (10.0.2.10)"                       hostA   10.0.2.10
    prova "hostB   -> hostA   (10.0.1.10)"                       hostB   10.0.1.10
    echo
    echo "Stato di WireGuard su routerA:"
    ip netns exec routerA wg show wg0
fi

echo
echo "Comandi utili da mostrare:"
echo "  sudo ip netns exec routerA wg show        # peer, handshake, byte scambiati"
echo "  sudo ip -d -n routerA link show wg0       # dettagli dell'interfaccia (nota l'MTU)"
echo "  cat $KEYDIR/routerA.pub                   # una chiave pubblica (la privata NON si mostra)"
