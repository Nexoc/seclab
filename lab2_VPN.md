
# Инструкция к VPN Lab  
**Лаба:** VPN Part I (WireGuard & OpenVPN)  

## Назначение

Этот документ описывает полный пошаговый порядок выполнения лабораторной работы:

- зафиксировать базовую сетевую схему
- настроить удалённый захват трафика через Wireshark
- поднять туннель WireGuard
- поднять туннель OpenVPN
- сравнить шифрованный и расшифрованный трафик
- проверить MTU и fragmentation
- провести throughput-тесты через `iperf3`
- собрать скриншоты и вывод команд для итогового отчёта

---

# 1. Топология лаборатории

Обычно в лабе используются:

- **gateway**
- **PC1**
- **PC2**
- **локальный компьютер** с Wireshark

Wireshark запускается на локальном компьютере, а захват выполняется удалённо через **SSH remote capture (sshdump)** с **PC1 через gateway**.

---

# 2. Необходимое ПО

## На PC1 и PC2

```bash
sudo apt update
sudo apt install -y wireguard openvpn tcpdump iperf3 openssh-server
````

## На gateway

```bash
sudo apt update
sudo apt install -y iptables
```

## На локальном компьютере

Установить **Wireshark** и убедиться, что выбран компонент
**SSH remote capture (sshdump)**.

---

# 3. Первичная фиксация сетевой конфигурации

На **PC1** и **PC2** выполнить:

```bash
hostname
ip a
ip route
```

## Что занести в отчёт

Заполнить:

* Physical NIC IP для PC1
* Physical NIC IP для PC2
* позже: IP WireGuard
* позже: IP OpenVPN

## Что сохранить

Скопировать или сфотографировать:

* вывод `ip a`
* вывод `ip route`

---

# 4. Настройка Wireshark Remote Capture

## 4.1 Настроить DNAT на gateway

Выполнить на **gateway**:

```bash
sudo iptables -t nat -A PREROUTING -p tcp -d <GATEWAY_EXTERNAL_IP> --dport 22 -j DNAT --to-destination <PC1_PHYSICAL_IP>:22
```

Подставить:

* `<GATEWAY_EXTERNAL_IP>` — внешний IP gateway
* `<PC1_PHYSICAL_IP>` — физический IP PC1

---

## 4.2 Разрешить захват пакетов на PC1

Выполнить на **PC1**:

```bash
sudo setcap cap_net_raw+ep $(which tcpdump)
```

---

## 4.3 Настроить Wireshark

На локальном компьютере открыть Wireshark и выбрать:

```text
SSH remote capture: sshdump
```

Использовать следующие параметры:

### Remote SSH Server Settings

* **Remote SSH server address:** `<Gateway IP>`
* **Port:** `22`

### Authentication

* **Username:** `csdc`
* **Password:** пароль пользователя на PC1

### Capture

* **Remote interface:** `ens18`
  (или ваш реальный физический интерфейс)
* **Remote capture filter:** `not port 22`

Фильтр нужен, чтобы SSH-трафик не попадал в захват.

---

# 5. WireGuard

## 5.1 Генерация ключей

### На PC1

```bash
wg genkey | tee pc1_private.key | wg pubkey > pc1_public.key
cat pc1_public.key
```

### На PC2

```bash
wg genkey | tee pc2_private.key | wg pubkey > pc2_public.key
cat pc2_public.key
```

Обменяться **public key** между машинами.

---

## 5.2 Создание конфигурации WireGuard

## PC1: `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.10.10.1/24
PrivateKey = <PC1_PRIVATE_KEY>
ListenPort = 51820

[Peer]
PublicKey = <PC2_PUBLIC_KEY>
AllowedIPs = 10.10.10.2/32
Endpoint = <PC2_PHYSICAL_IP>:51820
PersistentKeepalive = 25
```

## PC2: `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.10.10.2/24
PrivateKey = <PC2_PRIVATE_KEY>
ListenPort = 51820

[Peer]
PublicKey = <PC1_PUBLIC_KEY>
AllowedIPs = 10.10.10.1/32
Endpoint = <PC1_PHYSICAL_IP>:51820
PersistentKeepalive = 25
```

---

## 5.3 Запуск WireGuard

На обеих машинах:

```bash
sudo wg-quick up wg0
ip a show wg0
sudo wg
```

## Проверка туннеля

### С PC1

```bash
ping -c 4 10.10.10.2
```

### С PC2

```bash
ping -c 4 10.10.10.1
```

---

## 5.4 Захват трафика для отчёта

### Захват снаружи туннеля

В Wireshark выбрать **физический интерфейс** (`ens18` или реальный NIC).

Сгенерировать трафик через туннель, например:

```bash
ping -c 4 10.10.10.2
```

Ожидаемое наблюдение:

* шифрованные UDP-пакеты
* внешние IP адреса peer’ов
* порт WireGuard `51820`

### Захват внутри туннеля

Сменить интерфейс в Wireshark на:

```text
wg0
```

Снова сгенерировать трафик.

Ожидаемое наблюдение:

* расшифрованный ICMP-трафик
* внутренние VPN IP, например `10.10.10.1 -> 10.10.10.2`

---

## Что писать в отчёте

### Commands used (key generation)

```bash
wg genkey | tee <private.key> | wg pubkey > <public.key>
```

### Commands used (interface start)

```bash
sudo wg-quick up wg0
```

### Traffic Observation

**Physical Interface:**
На физическом интерфейсе видны шифрованные UDP-пакеты между peer’ами WireGuard.

**wg0 Interface:**
На `wg0` виден расшифрованный внутренний трафик, например ICMP.

### Difference between interfaces

На физическом интерфейсе виден только внешний зашифрованный трафик туннеля.
На `wg0` видны исходные внутренние пакеты после расшифровки.

---

# 6. OpenVPN

Для этой лабы самый простой вариант:

* **Mode:** `tun`
* **Protocol:** `udp`
* **Authentication:** `PSK`

---

## 6.1 Генерация static key

На одной машине:

```bash
sudo openvpn --genkey secret /etc/openvpn/static.key
```

Потом этот же ключ нужно передать на вторую машину.

---

## 6.2 Создание server config

### PC1: `/etc/openvpn/server.conf`

```conf
dev tun
ifconfig 10.20.20.1 10.20.20.2
secret /etc/openvpn/static.key
port 1194
proto udp
verb 3
```

---

## 6.3 Создание client config

### PC2: `/etc/openvpn/client.conf`

```conf
remote <PC1_PHYSICAL_IP> 1194
dev tun
ifconfig 10.20.20.2 10.20.20.1
secret /etc/openvpn/static.key
proto udp
nobind
verb 3
```

---

## 6.4 Запуск OpenVPN

### На PC1

```bash
sudo openvpn --config /etc/openvpn/server.conf
```

### На PC2

```bash
sudo openvpn --config /etc/openvpn/client.conf
```

## Проверка туннеля

```bash
ip a | grep tun0
ping -c 4 10.20.20.1
ping -c 4 10.20.20.2
```

---

## 6.5 Захват трафика для отчёта

### Снаружи туннеля

В Wireshark выбрать физический интерфейс.

Ожидаемое наблюдение:

* зашифрованный трафик OpenVPN
* обычно UDP `1194`

### Внутри туннеля

Сменить интерфейс на:

```text
tun0
```

Ожидаемое наблюдение:

* расшифрованный ICMP/TCP трафик
* внутренние OpenVPN IP

---

## Что писать в отчёте

### Parameter choices

* **Mode:** `tun`
* **Protocol:** `udp`
* **Authentication:** `PSK`

### Reason for configuration choice

`tun` подходит для маршрутизируемого IP-трафика.
UDP выбран, чтобы избежать TCP-over-TCP overhead, а PSK — самый простой вариант для лабораторной работы.

### Traffic Observation

**Physical Interface:**
На физическом интерфейсе виден шифрованный трафик OpenVPN.

**Tunnel Interface (`tun0`):**
На `tun0` виден расшифрованный внутренний трафик.

---

# 7. MTU и Fragmentation

## 7.1 Тест размеров пакетов

Тестировать нужно **через VPN-туннель**, а не по физическим IP.

## WireGuard

```bash
ping -M do -s 500 10.10.10.2 -c 2
ping -M do -s 1400 10.10.10.2 -c 2
ping -M do -s 1450 10.10.10.2 -c 2
ping -M do -s 1500 10.10.10.2 -c 2
ping -M do -s 1550 10.10.10.2 -c 2
```

## OpenVPN

```bash
ping -M do -s 500 10.20.20.2 -c 2
ping -M do -s 1400 10.20.20.2 -c 2
ping -M do -s 1450 10.20.20.2 -c 2
ping -M do -s 1500 10.20.20.2 -c 2
ping -M do -s 1550 10.20.20.2 -c 2
```

---

## 7.2 Найти точный предел MTU

Пример:

```bash
for s in 1300 1310 1320 1330 1340 1350 1360 1370 1380 1390 1400 1410 1420 1430 1440 1450; do
  echo "SIZE=$s"
  ping -M do -s $s -c 1 <VPN_IP>
done
```

Потом можно сузить диапазон и искать точнее.

---

## Как интерпретировать результат

Если пакет проходит:

* fragmentation ещё нет

Если появляется ошибка вида:

* `Frag needed`
* `message too long`

значит fragmentation уже началась.

---

## Важное замечание

`ping -s` — это **payload size**, а не полный MTU.

Для IPv4 приблизительно:

```text
MTU = payload + 28
```

потому что:

* 20 байт IP header
* 8 байт ICMP header

---

## Что писать в отчёте

### Ping command used

```bash
ping -M do -s <size> <vpn-ip> -c 2
```

### Пример рекомендации

Уменьшить MTU туннеля, чтобы избежать внешней fragmentation.
Для WireGuard можно задать `MTU = ...` в `wg0.conf`.
Для OpenVPN можно настроить `tun-mtu` и при необходимости `mssfix`.

---

# 8. Throughput Tests

С помощью `iperf3` сравниваются:

* без VPN
* WireGuard
* OpenVPN

---

## 8.1 Без VPN

### На PC2

```bash
iperf3 -s
```

### На PC1

```bash
iperf3 -c <PC2_PHYSICAL_IP>
iperf3 -c <PC2_PHYSICAL_IP> -l 512
iperf3 -c <PC2_PHYSICAL_IP> -l 1400
iperf3 -c <PC2_PHYSICAL_IP> -l 8000
```

---

## 8.2 Через WireGuard

### На PC2

```bash
iperf3 -s
```

### На PC1

```bash
iperf3 -c 10.10.10.2
iperf3 -c 10.10.10.2 -l 512
iperf3 -c 10.10.10.2 -l 1400
iperf3 -c 10.10.10.2 -l 8000
```

---

## 8.3 Через OpenVPN

### На PC2

```bash
iperf3 -s
```

### На PC1

```bash
iperf3 -c 10.20.20.2
iperf3 -c 10.20.20.2 -l 512
iperf3 -c 10.20.20.2 -l 1400
iperf3 -c 10.20.20.2 -l 8000
```

---

## 8.4 Latency

### Без VPN

```bash
ping -c 10 <PC2_PHYSICAL_IP>
```

### WireGuard

```bash
ping -c 10 10.10.10.2
```

### OpenVPN

```bash
ping -c 10 10.20.20.2
```

В отчёт брать среднее значение `avg`.

---

## 8.5 TCP handshakes

Для обычного TCP `iperf3` теста обычно наблюдается один нормальный TCP handshake:

```text
SYN -> SYN/ACK -> ACK
```

Если в Wireshark есть retries или reconnect, это нужно отдельно отметить.

---

# 9. Packet Size Overhead

Сравнить:

* plain traffic
* WireGuard
* OpenVPN

---

## Метод измерения

1. Отправить одинаковый payload, например:

```bash
ping -c 1 -s 1000 <target>
```

2. В Wireshark посмотреть размер пакета:

   * обычный трафик
   * внешний пакет WireGuard
   * внешний пакет OpenVPN

3. Посчитать:

```text
Overhead = Tunnel packet size - Plain packet size
```

---

## Пример формулировки для отчёта

Использовался фиксированный ICMP payload, после чего в Wireshark сравнивались размеры пакетов на физическом интерфейсе. Overhead рассчитывался как разница между размером tunnel packet и plain packet.

---

## Возможное наблюдение

Размер tunnel packet увеличивается из-за дополнительных заголовков encapsulation и encryption. Увеличение не всегда строго одинаковое для всех пакетов, потому что состав заголовков может немного различаться.

---

# 10. Comparison

Типичный результат:

| Feature          | WireGuard | OpenVPN |
| ---------------- | --------- | ------- |
| Setup complexity | проще     | сложнее |
| Performance      | лучше     | ниже    |
| Packet overhead  | меньше    | больше  |

---

# 11. Conclusion

Пример вывода:

WireGuard оказался проще в настройке и показал лучшую throughput при меньшем overhead. OpenVPN работал надёжно, но потребовал больше конфигурации и добавил больший overhead. В захватах трафика на физическом интерфейсе был виден зашифрованный трафик, а на tunnel-интерфейсах — расшифрованный внутренний трафик. Fragmentation начиналась раньше из-за уменьшения эффективного MTU при использовании VPN.

---

# 12. Обязательные скриншоты

Во время лабы нужно собрать следующие скриншоты:

1. **WireGuard traffic (inside vs outside tunnel)**

   * физический интерфейс
   * `wg0`

2. **OpenVPN traffic (inside vs outside tunnel)**

   * физический интерфейс
   * `tun0`

3. **Fragmentation example**

   * один успешный ping
   * один неуспешный ping / пример fragmentation

4. **Throughput test**

   * экран с результатом `iperf3`

---

# 13. Рекомендуемый порядок выполнения

1. Зафиксировать physical IP адреса
2. Установить нужные пакеты
3. Настроить Wireshark remote capture
4. Поднять WireGuard
5. Снять WireGuard traffic outside/inside tunnel
6. Поднять OpenVPN
7. Снять OpenVPN traffic outside/inside tunnel
8. Выполнить MTU/fragmentation tests
9. Выполнить throughput tests
10. Заполнить comparison и conclusion

---

# 14. Краткий чеклист

* [ ] physical IP адреса записаны
* [ ] Wireshark remote capture работает
* [ ] WireGuard туннель работает
* [ ] OpenVPN туннель работает
* [ ] результаты MTU записаны
* [ ] результаты throughput записаны
* [ ] overhead измерен
* [ ] все обязательные скриншоты сделаны
* [ ] comparison заполнен
* [ ] conclusion написан


