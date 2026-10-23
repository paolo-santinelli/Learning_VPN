#!/usr/bin/env bash
#
# vpn-lab-down.sh - Smonta completamente il laboratorio VPN.
#
# Eliminare un namespace distrugge tutto cio' che contiene: interfacce, indirizzi,
# rotte, tunnel. Le coppie veth spariscono da sole, perche' cancellando un lato
# del "cavo" sparisce anche l'altro.
#
# Uso:  sudo ./vpn-lab-down.sh

if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

for ns in hostA routerA routerB hostB; do
    if ip netns del "$ns" 2>/dev/null; then
        echo "Rimosso namespace: $ns"
    fi
done

echo "Laboratorio smontato."
