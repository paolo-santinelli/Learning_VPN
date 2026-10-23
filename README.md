# VPN in ambiente Linux: laboratorio con network namespace

Materiale del seminario **«VPN in ambiente Linux»** (Linux Day), con le slide e gli script per rifare a casa la dimostrazione.

Il laboratorio simula due sedi collegate da una rete pubblica, usando solo **network namespace** e **cavi virtuali (veth)**: non servono macchine virtuali né hardware. Si costruisce un tunnel tra le due sedi, si cattura il traffico con tcpdump o Wireshark e si confronta ciò che si vede **dentro** il tunnel con ciò che si vede **fuori**.

Due esperimenti:

1. **Tunnel senza cifratura (IPIP o GRE):** si vede l'incapsulamento, e il contenuto dei pacchetti è leggibile da chiunque stia sul percorso.
2. **Tunnel WireGuard:** stesso scenario, ma sul segmento pubblico il contenuto non si legge più.

## Topologia

```
[hostA]--(10.0.1.0/24)--[routerA]--(203.0.113.0/24)--[routerB]--(10.0.2.0/24)--[hostB]
10.0.1.10        10.0.1.1 | 203.0.113.1    203.0.113.2 | 10.0.2.1        10.0.2.10
                          \____ segmento "pubblico" ____/
```

| Elemento | Indirizzo |
|---|---|
| Rete privata sito A | 10.0.1.0/24 |
| Rete privata sito B | 10.0.2.0/24 |
| Segmento «pubblico» (TEST-NET-3, riservato alla documentazione) | 203.0.113.0/24 |
| Rete del tunnel (punto-punto) | 172.16.0.0/30 |

Senza VPN le due reti private non si raggiungono, perché gli indirizzi privati non sono instradabili. La VPN risolve proprio questo.

## Requisiti

- Linux con kernel 5.6 o successivo (per WireGuard, incluso nel kernel).
- Permessi di amministratore (`sudo`): creare namespace e interfacce li richiede.
- Pacchetti: `iproute2`, `tcpdump`, `python3`, e `wireguard-tools` per il secondo esperimento.
- Wireshark (facoltativo) per aprire le catture `.pcap`.

Su Debian/Ubuntu:

```bash
sudo apt install iproute2 tcpdump python3 wireguard-tools wireshark
```

## Gli script

Tutti vanno eseguiti come root (`sudo`) e sono commentati riga per riga.

| Script | Cosa fa |
|---|---|
| `vpn-lab-up.sh` | Costruisce il laboratorio: crea i 4 namespace (`hostA`, `routerA`, `routerB`, `hostB`), i cavi virtuali, gli indirizzi e le rotte di base, e abilita l'inoltro dei pacchetti sui router. Tra le due reti private non c'è nessuna rotta, di proposito. |
| `vpn-lab-test.sh` | Verifica la connettività con dei ping. Prima della VPN i collegamenti locali devono dare `[ OK ]` e `hostA -> hostB` deve dare `[FALLITO]`. Dopo la VPN diventa `[ OK ]`. |
| `vpn-lab-tunnel.sh [ipip\|gre]` | **Esperimento 1.** Crea un tunnel non cifrato tra `routerA` e `routerB` (interfaccia `tun0`, indirizzi 172.16.0.1 e 172.16.0.2), aggiunge le rotte verso le reti remote e verifica che `hostA` raggiunga `hostB`. Default: `ipip`. |
| `vpn-lab-wireguard.sh [--senza-test]` | **Esperimento 2.** Genera una coppia di chiavi per router (nella cartella `./chiavi-wg`), crea l'interfaccia `wg0`, configura peer e `AllowedIPs`, aggiunge le rotte e mostra `wg show`. Se esiste già un tunnel `tun0`, lo rimuove. Con `--senza-test` non genera traffico di verifica, così l'handshake resta da catturare. |
| `vpn-lab-capture.sh [cartella] [interfaccia]` | Genera traffico da `hostA` a `hostB` (3 ping e una richiesta HTTP con una frase riconoscibile) e lo cattura in due punti di `routerA`: su `rA-pub` (segmento pubblico, come viaggerebbe su Internet) e sull'interfaccia del tunnel (`tun0` o `wg0`). Alla fine controlla in quale file la frase si legge. Default: `./catture` e `tun0`. |
| `vpn-lab-down.sh` | Smonta tutto. Eliminare un namespace distrugge anche interfacce, rotte e tunnel che contiene. |

## Come si usa

### Esperimento 1: tunnel senza cifratura

```bash
sudo ./vpn-lab-up.sh
sudo ./vpn-lab-test.sh                  # hostA -> hostB deve fallire
sudo ./vpn-lab-tunnel.sh ipip           # oppure: gre
sudo ./vpn-lab-test.sh                  # ora deve funzionare
sudo ./vpn-lab-capture.sh ./catture tun0
```

Apri i file `.pcap` in `./catture` con Wireshark. Sul segmento pubblico (`rA-pub`) vedi un pacchetto IP dentro un altro pacchetto IP (IPIP, protocollo 4) oppure dentro GRE (protocollo 47), e la frase segreta si legge in chiaro. Sull'interfaccia del tunnel vedi il pacchetto originale.

### Esperimento 2: WireGuard

```bash
sudo ./vpn-lab-wireguard.sh --senza-test
sudo ./vpn-lab-capture.sh ./catture-wg wg0
```

Su `rA-pub` ci sono pacchetti UDP sulla porta 51820 decodificati come WireGuard (tipo di messaggio, indici, contatori), ma la frase non si legge. Su `wg0` lo stesso traffico appare in chiaro.

### Pulizia

```bash
sudo ./vpn-lab-down.sh
```

## Comandi utili per esplorare i namespace

Un network namespace è una copia isolata dello stack di rete: ha le sue interfacce, i suoi indirizzi, le sue rotte e le sue regole. `ip -n NOME` è la scorciatoia per `ip netns exec NOME ip`.

```bash
# Elenco e contenuto
ip netns list                              # i namespace esistenti
ip -n routerA -br addr                     # interfacce e indirizzi, in forma compatta
ip -n routerA link                         # interfacce, anche quelle spente
ip -n routerA route                        # tabella di routing
ip -n routerA route get 10.0.2.10          # quale strada userebbe per quella destinazione
ip -n routerA neigh                        # tabella ARP
ip -n routerA -d link show tun0            # dettagli del tunnel (tipo, local, remote)
ip -all netns exec ip -br addr             # lo stesso comando in tutti i namespace

# Eseguire comandi dentro un namespace
sudo ip netns exec hostA ping -c3 10.0.2.10        # un singolo comando
sudo ip netns exec routerA bash                    # una shell dentro il namespace
ip netns identify $$                               # in quale namespace sono? (nessun nome = quello principale)
sudo ip netns exec routerA sysctl net.ipv4.ip_forward   # l'inoltro è attivo sui router?
sudo ip netns exec routerA ss -ulpn                # socket UDP in ascolto (con WireGuard compare la 51820)

# Osservare il traffico
sudo ip netns exec routerA tcpdump -ni rA-pub      # segmento pubblico
sudo ip netns exec routerA tcpdump -ni tun0        # dentro il tunnel IPIP/GRE
sudo ip netns exec routerA tcpdump -ni wg0         # dentro il tunnel WireGuard
sudo ip netns exec routerA tcpdump -ni rA-pub -X   # con il contenuto dei pacchetti in esadecimale e ASCII

# WireGuard
sudo ip netns exec routerA wg show                 # peer, ultimo handshake, byte scambiati
sudo ip netns exec routerA wg show wg0 allowed-ips # solo gli AllowedIPs

# Dall'esterno
ls /run/netns/                                     # ogni namespace con nome è un file qui
ip netns pids routerA                              # processi che girano nel namespace
```

Nel laboratorio le interfacce hanno questi nomi: `hA-rA` e `rA-hA` (cavo tra `hostA` e `routerA`), `rA-pub` e `rB-pub` (segmento pubblico), `rB-hB` e `hB-rB` (cavo tra `routerB` e `hostB`).

## Esperimento facoltativo: l'MTU del tunnel

Incapsulare un pacchetto aggiunge byte, quindi dentro il tunnel il pacchetto originale può essere più piccolo di quello che passa sul collegamento fisico (MTU 1500).

| Tunnel | Byte aggiunti | MTU dell'interfaccia del tunnel |
|---|---|---|
| IPIP | 20 | 1480 |
| GRE | 24 | 1476 |
| WireGuard | circa 60-80 | 1420 (valore predefinito) |

Per vederlo, con il tunnel IPIP attivo:

```bash
# MTU dell'interfaccia del tunnel
ip -n routerA link show tun0

# Ping "da 1500 byte" che vieta la frammentazione (-M do):
# 1472 di dati + 28 di intestazioni ICMP e IP = 1500, quindi NON passa
sudo ip netns exec hostA ping -c1 -M do -s 1472 10.0.2.10

# 1452 + 28 = 1480, quindi passa
sudo ip netns exec hostA ping -c1 -M do -s 1452 10.0.2.10
```

Il valore di `-s` è la parte di dati del ping: per trovare il limite si sottraggono 28 byte all'MTU (GRE: 1448, WireGuard: 1392). Il router non può inoltrare il pacchetto troppo grande, né frammentarlo perché `-M do` lo vieta, quindi lo scarta e avvisa `hostA` con un messaggio ICMP. È la causa tipica delle VPN reali in cui il ping funziona ma i trasferimenti grandi si bloccano.




## Cose da sapere

- Il laboratorio è solo didattico: le chiavi create da `vpn-lab-wireguard.sh` in `./chiavi-wg` servono per l'esperimento e non vanno riutilizzate altrove.
- Le cartelle `chiavi-wg/` e `catture*/` non vanno pubblicate: conviene aggiungerle a `.gitignore`.
- Tutto ciò che il laboratorio crea vive nei namespace. Al riavvio del computer sparisce da solo, e `vpn-lab-down.sh` lo elimina subito.
- Se un namespace con lo stesso nome esiste già, `vpn-lab-up.sh` fa prima una pulizia preventiva.

## Per approfondire

- WireGuard: <https://www.wireguard.com/> (quickstart, installazione su Windows e Android, descrizione del protocollo)
- strongSwan (IPsec su Linux): <https://docs.strongswan.org/>
- OpenVPN: <https://openvpn.net/>
- RFC 2003 (IPIP), RFC 2784 (GRE), RFC 4303 (ESP)

## Autore

Paolo Santinelli, ITIS «E. Fermi», Modena.
