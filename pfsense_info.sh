#!/bin/sh

# --- Variáveis de Saída e Ferramentas ---
DMIDECODE_PATH=$(which dmidecode)
CURL_PATH=$(which curl)
PHP_PATH=$(which php)

# --- Variável para armazenar descrições (Interface -> Descrição) ---
# Pré-carrega as descrições de todas as interfaces configuradas a partir do config.xml
INTERFACE_DESCRIPTIONS=""
if [ -n "$PHP_PATH" ]; then
    INTERFACE_DESCRIPTIONS=$($PHP_PATH -r '
        $config = simplexml_load_file("/conf/config.xml");
        $descriptions = [];
        
        // Iterar sobre todas as interfaces (LAN, WAN, OPTx)
        foreach ($config->interfaces->children() as $iface) {
            $name = (string)$iface->if;
            // Pega a descrição configurada, se não existir, usa o nome da interface
            $description = empty((string)$iface->descr) ? $name : (string)$iface->descr; 
            if (!empty($name)) {
                // Substitui espaços por underscores para facilitar o grep no shell
                $descriptions[$name] = str_replace(" ", "_", $description);
            }
        }
        
        // Formatar o resultado como chave=valor (ex: hn0=LAN, vtnet1=WAN)
        foreach ($descriptions as $name => $desc) {
            echo $name . "=" . $desc . "\n";
        }
    ' 2>/dev/null)
fi

# --- 1. Obter a Interface LAN Principal ---
LAN_IF="N/A"
if [ -n "$PHP_PATH" ]; then
    # Obtém o nome da interface física (ex: hn0) que está mapeada como LAN na config
    LAN_IF=$($PHP_PATH -r '$config = simplexml_load_file("/conf/config.xml"); echo (string)$config->interfaces->lan->if;' 2>/dev/null)
fi
if [ -z "$LAN_IF" ] || [ "$LAN_IF" = "none" ]; then
    LAN_IF="Desconhecida"
fi
# ----------------------------------------

# --- 2. Coletar Descrição, IP e MAC de TODAS as Interfaces Ativas ---
INTERFACES_JSON=""
IF_COUNTER=0

# Lista todas as interfaces que não sejam loopback (lo0)
for IFACE in $(ifconfig -l | tr ' ' '\n' | grep -v '^lo0$'); do
    
    # Tenta obter a descrição do array pré-carregado.
    IF_DESC_RAW=$(echo "$INTERFACE_DESCRIPTIONS" | grep "^$IFACE=" | cut -d'=' -f2)
    
    # Substitui underscores por espaços e usa o nome da interface como fallback (se não tiver descrição)
    IF_DESC=$(echo "${IF_DESC_RAW:-$IFACE}" | tr '_' ' ')
    
    # Informações de rede
    IF_IP=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n 1)
    IF_MAC=$(ifconfig "$IFACE" 2>/dev/null | awk '/ether /{print $2}' | head -n 1)
    
    # Verifica se a interface está ativa e possui endereço IP
    if [ -n "$IF_IP" ] && [ -n "$IF_MAC" ]; then
        if [ "$IF_COUNTER" -gt 0 ]; then
            INTERFACES_JSON="${INTERFACES_JSON},"
        fi

        INTERFACES_JSON="${INTERFACES_JSON}
        {
            \"name\": \"$IFACE\",
            \"description\": \"$IF_DESC\",
            \"ip_address\": \"$IF_IP\",
            \"mac_address\": \"$IF_MAC\"
        }"
        IF_COUNTER=$((IF_COUNTER + 1))
    fi
done
# ----------------------------------------

# --- 3. Coletar Informações de Hardware ---

# Detecção de VM primeiro (mais robusto)
if /sbin/dmesg | grep -q 'VMware\|VirtualBox\|QEMU\|Hyper-V\|KVM\|VirtIO'; then
    CHASSIS_TYPE="VM (Detected via dmesg)"
elif [ -n "$DMIDECODE_PATH" ]; then
    # Se dmidecode estiver disponível, usa-o
    CHASSIS_TYPE_RAW=$($DMIDECODE_PATH -s chassis-type 2>/dev/null | head -n 1)
    CHASSIS_TYPE="${CHASSIS_TYPE_RAW:-Físico/Desconhecido}"

    MEM_TYPE=$($DMIDECODE_PATH -t 17 2>/dev/null | awk '/Type: / {print $2}' | sort -u | grep -v 'Unknown' | head -n 1)
    MEM_TYPE="${MEM_TYPE:-Desconhecido}"
else
    # Fallback se dmidecode não estiver disponível
    CHASSIS_TYPE="Físico/Desconhecido (DMIDECODE não encontrado)"
    MEM_TYPE="Não Aplicável (DMIDECODE não encontrado)"
fi

# Informações básicas
OS_INFO=$(/usr/bin/uname -rs)
CPU_INFO=$(/sbin/sysctl -n hw.model)
CPU_CORES=$(/sbin/sysctl -n hw.ncpu)
PROCESSOR="$CPU_INFO ($CPU_CORES Cores)"
MEM_TOTAL_KB=$(/sbin/sysctl -n hw.physmem)
MEM_TOTAL_GB=$(echo "scale=2; $MEM_TOTAL_KB / 1024 / 1024 / 1024" | /usr/bin/bc)

# Disco (Adicionado GB e detecção de tipo)
DISK_SIZE_RAW=$(/bin/df -h / | /usr/bin/awk 'NR==2{print $2}' | sed 's/G/GB/')
DISK_TYPE_RAW=$(/sbin/dmesg | /usr/bin/grep "da[0-9]\|ada[0-9]" | /usr/bin/grep -i 'SSD\|NVMe\|M.2' | /usr/bin/head -n 1)
if echo "$DISK_TYPE_RAW" | /usr/bin/grep -i -q "SSD\|NVMe\|M.2"; then
    DISK_TYPE="SSD"
elif echo "$DISK_TYPE_RAW" | /usr/bin/grep -i -q "HDD\|ATA"; then
    DISK_TYPE="HDD"
else
    DISK_TYPE="Desconhecido"
fi
DISK_INFO="$DISK_SIZE_RAW $DISK_TYPE"

# Hostname e IP da LAN Principal (Simples - Apenas IPv4 Decimal)
HOSTNAME=$(/bin/hostname)
LAN_IP=$(ifconfig "$LAN_IF" 2>/dev/null | awk '/inet /{print $2}' | head -n 1)
LAN_MAC=$(ifconfig "$LAN_IF" 2>/dev/null | awk '/ether /{print $2}' | head -n 1)

# Se o IP principal não for encontrado (ex: LAN_IF é um bridge), tenta buscar do array
if [ -z "$LAN_IP" ] && [ "$LAN_IF" != "N/A" ]; then
    # Tenta extrair o IP do array de interfaces com base no nome
    LAN_IP=$(echo "$INTERFACES_JSON" | grep "\"name\": \"$LAN_IF\"" -A 3 | grep "ip_address" | awk -F'"' '{print $4}' | head -n 1)
    LAN_MAC=$(echo "$INTERFACES_JSON" | grep "\"name\": \"$LAN_IF\"" -A 4 | grep "mac_address" | awk -F'"' '{print $4}' | head -n 1)
fi

# --- 4. Formatando em JSON ---
JSON_DATA=$(cat <<EOF
{
  "hostname": "$HOSTNAME",
  "os": "$OS_INFO",
  "chassis_type": "$CHASSIS_TYPE",
  "processor": "$PROCESSOR",
  "memory": "${MEM_TOTAL_GB}GB ${MEM_TYPE}",
  "disk": "$DISK_INFO",
  "lan_interface": "$LAN_IF",
  "lan_mac": "${LAN_MAC:-N/A}",
  "lan_ip": "${LAN_IP:-N/A}",
  "active_interfaces": [${INTERFACES_JSON}
  ]
}
EOF
)

echo "$JSON_DATA"

# --- 5. Enviando os dados ---
TARGET_URL="https://api.zeustecnologia.com.br/inventario/inventariopfsense" 

if [ -n "$CURL_PATH" ]; then
    /usr/local/bin/curl -X POST -H "Content-Type: application/json" -d "$JSON_DATA" "$TARGET_URL"
    if [ $? -eq 0 ]; then
        echo "\nDados enviados com sucesso para $TARGET_URL"
    else
        echo "\nERRO: Falha ao enviar dados via cURL."
    fi
else
    echo "\nAVISO: cURL não encontrado, pulando o envio POST."
fi
