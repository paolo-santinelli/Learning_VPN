#!/usr/bin/env bash
#
# vpn-lab-up.sh - Costruisce il laboratorio per la demo VPN site-to-site
#                 usando i NETWORK NAMESPACE di Linux.
#
# Topologia che verra' creata:
#
#   [hostA]---(10.0.1.0/24)---[routerA]---(203.0.113.0/24)---[routerB]---(10.0.2.0/24)---[hostB]
#   10.0.1.10        10.0.1.1 | 203.0.113.1      203.0.113.2 | 10.0.2.1          10.0.2.10
#                             \_____ segmento "pubblico" ____/
#
# - Sito A: rete privata 10.0.1.0/24
# - Sito B: rete privata 10.0.2.0/24
# - Segmento "pubblico": 203.0.113.0/24 (e' un range riservato alla
#   documentazione, TEST-NET-3: lo usiamo perche' "sembra" una rete pubblica
#   ma non rischia di collidere con indirizzi reali).
#
# Questo e' l'equivalente Linux dei due MikroTik CHR + VirtualBox:
#   - ogni namespace = una "macchina" di rete isolata
#   - ogni coppia veth = un cavo di rete virtuale tra due macchine
#
# Uso:  sudo ./vpn-lab-up.sh
# Per smontare tutto:  sudo ./vpn-lab-down.sh

# -e  : esci al primo comando che fallisce
# -u  : errore se usi una variabile non definita
# -o pipefail : una pipeline fallisce se fallisce uno qualunque dei suoi comandi
set -euo pipefail

# Creare namespace e interfacce richiede privilegi di amministratore.
if [[ $EUID -ne 0 ]]; then
    echo "Questo script va eseguito come root:  sudo $0" >&2
    exit 1
fi

NAMESPACES=(hostA routerA routerB hostB)

# ---------------------------------------------------------------------------
# 0) PULIZIA PREVENTIVA
# ---------------------------------------------------------------------------
# Se lo script viene rilanciato, eliminiamo prima un eventuale laboratorio
# gia' presente. Cosi' lo script e' "ripetibile": utile se durante il seminario
# vuoi ripartire da zero. Cancellare un namespace elimina anche le interfacce
# che contiene (e quindi anche l'altra meta' di ogni cavo veth).
for ns in "${NAMESPACES[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 1) CREAZIONE DEI NAMESPACE
# ---------------------------------------------------------------------------
# Un NETWORK NAMESPACE e' uno stack di rete completo e isolato: ha le proprie
# interfacce, la propria tabella di routing, il proprio firewall. Per i comandi
# che ci girano dentro e' come essere su un'altra macchina.
#
#   ip netns add NOME   -> crea il namespace
#
# Subito dopo accendiamo l'interfaccia di loopback (lo) di ciascuno: un
# namespace nuovo ha "lo" spenta, e molte applicazioni (e certi test) si
# aspettano che funzioni.
#
# NOTA: "ip -n NOME <comando>" e' una scorciatoia per eseguire il comando
# "ip <comando>" DENTRO il namespace NOME. E' equivalente a
# "ip netns exec NOME ip <comando>", ma piu' breve.
for ns in "${NAMESPACES[@]}"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
done

# ---------------------------------------------------------------------------
# 2) CREAZIONE DEI "CAVI" (coppie veth)
# ---------------------------------------------------------------------------
# Una coppia VETH e' come un cavo di rete con due estremita': quello che entra
# da una esce dall'altra. Ogni estremita' e' un'interfaccia di rete a tutti gli
# effetti e puo' essere collocata in un namespace diverso. E' cosi' che
# colleghiamo tra loro le nostre "macchine".
#
# Sintassi:
#   ip link add NOME1 netns NS1 type veth peer name NOME2 netns NS2
# crea il cavo e mette direttamente ciascuna estremita' nel suo namespace.
#
# Convenzione dei nomi: "<mio>-<altro>", cosi' si capisce a colpo d'occhio
# dove va il cavo (es. rA-pub = router A, lato rete pubblica).
#
# Cavo 1: hostA <-> routerA   (rete privata del sito A)
ip link add hA-rA netns hostA   type veth peer name rA-hA netns routerA
#
# Cavo 2: routerA <-> routerB (segmento "pubblico": e' qui che passera' la VPN)
ip link add rA-pub netns routerA type veth peer name rB-pub netns routerB
#
# Cavo 3: routerB <-> hostB   (rete privata del sito B)
ip link add rB-hB netns routerB type veth peer name hB-rB netns hostB

# ---------------------------------------------------------------------------
# 3) INDIRIZZI IP
# ---------------------------------------------------------------------------
# Dentro ogni namespace assegniamo un indirizzo a ciascuna interfaccia.
#   ip -n NS addr add INDIRIZZO/PREFISSO dev INTERFACCIA
#
# Sito A
ip -n hostA   addr add 10.0.1.10/24    dev hA-rA
ip -n routerA addr add 10.0.1.1/24     dev rA-hA
# Segmento pubblico
ip -n routerA addr add 203.0.113.1/24  dev rA-pub
ip -n routerB addr add 203.0.113.2/24  dev rB-pub
# Sito B
ip -n routerB addr add 10.0.2.1/24     dev rB-hB
ip -n hostB   addr add 10.0.2.10/24    dev hB-rB

# ---------------------------------------------------------------------------
# 4) ACCENSIONE DELLE INTERFACCE
# ---------------------------------------------------------------------------
# Le interfacce nascono spente (DOWN). Vanno accese esplicitamente.
ip -n hostA   link set hA-rA  up
ip -n routerA link set rA-hA  up
ip -n routerA link set rA-pub up
ip -n routerB link set rB-pub up
ip -n routerB link set rB-hB  up
ip -n hostB   link set hB-rB  up

# ---------------------------------------------------------------------------
# 5) ROUTING
# ---------------------------------------------------------------------------
# Gli host usano il proprio router come gateway predefinito: tutto il traffico
# che non e' per la loro rete locale viene mandato al router.
ip -n hostA route add default via 10.0.1.1
ip -n hostB route add default via 10.0.2.1

# I router devono inoltrare pacchetti da un'interfaccia all'altra: di default
# Linux scarta i pacchetti non destinati a se' stesso. Il parametro
# net.ipv4.ip_forward e' PER-NAMESPACE, quindi va attivato in ciascun router.
ip netns exec routerA sysctl -qw net.ipv4.ip_forward=1
ip netns exec routerB sysctl -qw net.ipv4.ip_forward=1

# IMPORTANTE (scelta didattica): NON aggiungiamo rotte tra 10.0.1.0/24 e
# 10.0.2.0/24. Come su Internet vera, i router "pubblici" non sanno nulla
# delle reti private: gli indirizzi privati (RFC 1918) non sono instradabili.
# Quindi, a questo punto, hostA NON riesce a raggiungere hostB. E' proprio il
# problema che la VPN risolvera': la mostreremo come "prima/dopo".

echo
echo "Laboratorio pronto. Namespace creati:"
ip netns list
echo
echo "Prova a verificare la situazione di partenza con:  sudo ./vpn-lab-test.sh"
