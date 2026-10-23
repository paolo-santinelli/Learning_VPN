#!/usr/bin/env bash
#
# vpn-lab-test.sh - Verifica la connettivita' del laboratorio.
#
# Prima della VPN ci aspettiamo:
#   - i collegamenti "locali" funzionano (host<->suo router, router<->router)
#   - hostA -> hostB NON funziona (le reti private non sono instradabili)
#
# Dopo aver configurato la VPN, l'ultimo test dovra' diventare [ OK ].
#
# Uso:  sudo ./vpn-lab-test.sh

if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

# prova "descrizione" NAMESPACE DESTINAZIONE
# Esegue un singolo ping (-c1) con attesa massima di 1 secondo (-W1) DENTRO il
# namespace indicato ("ip netns exec NS comando" esegue un comando qualsiasi
# nel namespace). Stampa [ OK ] o [FALLITO] in base all'esito.
prova() {
    local desc="$1" ns="$2" dst="$3"
    if ip netns exec "$ns" ping -c1 -W1 -q "$dst" >/dev/null 2>&1; then
        printf '  [ OK ]    %s\n' "$desc"
    else
        printf '  [FALLITO] %s\n' "$desc"
    fi
}

echo "Collegamenti locali (devono funzionare):"
prova "hostA   -> routerA (10.0.1.1)"     hostA   10.0.1.1
prova "routerA -> routerB (203.0.113.2)"  routerA 203.0.113.2
prova "hostB   -> routerB (10.0.2.1)"     hostB   10.0.2.1

echo
echo "Attraversamento tra i siti (senza VPN deve fallire):"
prova "hostA   -> hostB   (10.0.2.10)"    hostA   10.0.2.10
