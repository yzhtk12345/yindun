#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Client Subscription Manager & Background Daemon (sub.sh)
# Description: 本地订阅分发守护进程（最终完美版：支持 1~8 号协议 + Argo 443 隧道 + IPv6 中括号修正矩阵）
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
NODES_DB="${CONFIG_DIR}/all_nodes.txt"
PORT_RECORD_FILE="${CONFIG_DIR}/sub_web_port.txt"
PID_FILE="${CONFIG_DIR}/sub_server.pid"
PYTHON_SERVER_FILE="${CONFIG_DIR}/sub_server.py"
SUBSCRIPTION_GENERATOR="${CONFIG_DIR}/generate_sub.py"
TOKEN_FILE="${CONFIG_DIR}/sub_token.txt"

mkdir -p "$CONFIG_DIR"

detect_firewall() {
    if systemctl is-active --quiet ufw 2>/dev/null || command -v ufw &>/dev/null; then
        echo "ufw"
    elif systemctl is-active --quiet firewalld 2>/dev/null || command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

cleanup_old_sub_firewall_rules() {
    local fw_type=$(detect_firewall)
    if [ -f "$PORT_RECORD_FILE" ]; then
        local old_port=$(cat "$PORT_RECORD_FILE")
        if [[ -n "$old_port" ]]; then
            case "$fw_type" in
                ufw) ufw delete allow "${old_port}/tcp" >/dev/null 2>&1; ufw reload >/dev/null 2>&1 ;;
                firewalld) firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 ;;
                iptables) iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true ;;
            esac
        fi
    fi
}

manage_firewall_port() {
    local action="$1" port="$2" comment="$3" fw_type=$(detect_firewall)
    case "$fw_type" in
        ufw) [[ "$action" == "add" ]] && ufw allow "$port/tcp" comment "$comment" >/dev/null 2>&1 && ufw reload >/dev/null 2>&1 ;;
        firewalld) [[ "$action" == "add" ]] && firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 ;;
        iptables) [[ "$action" == "add" ]] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ;;
    esac
}

check_port_used() {
    local port="$1"
    command -v ss &>/dev/null && ss -tuln | grep -q ":${port} " && return 0 || nc -z 127.0.0.1 "$port" &>/dev/null && return 0 || return 1
}

get_web_port() {
    local target_port=""
    if [ -f "$PORT_RECORD_FILE" ]; then
        target_port=$(cat "$PORT_RECORD_FILE")
        if [[ "$target_port" =~ ^[0-9]+$ ]] && [ "$target_port" -ge 10000 ] && [ "$target_port" -le 20000 ]; then
            read -p "是否需要重新生成随机端口和重置 Token？[y/N]: " reset_choice
            if [[ "$reset_choice" =~ ^[Yy]$ ]]; then
                cleanup_old_sub_firewall_rules
                rm -f "$PORT_RECORD_FILE" "$TOKEN_FILE"
                target_port=""
            fi
        fi
    fi
    if [ -z "$target_port" ]; then
        while true; do
            target_port=$((RANDOM % 10001 + 10000))
            ! check_port_used "$target_port" && break
        done
        echo "$target_port" > "$PORT_RECORD_FILE"
    fi
    echo "$target_port"
}

get_public_ip() {
    local ip=""
    for service in "https://api.ipify.org" "https://ip.sb" "https://icanhazip.com"; do
        ip=$(curl -s4 --max-time 3 "$service" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done
    echo "45.207.156.146"
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
}

prepare_subscription_generator() {
    cat << 'EOF' > "$SUBSCRIPTION_GENERATOR"
import os, urllib.parse, json

config_dir = os.path.dirname(os.path.abspath(__file__))
nodes_db = os.path.join(config_dir, "all_nodes.txt")
all_links_path = os.path.join(config_dir, "all_links.txt")
box_links_path = os.path.join(config_dir, "box_links.json")
mi_links_path = os.path.join(config_dir, "mi_links.yaml")

mi_proxies = []
box_outbounds = []
all_links = []
mi_node_names = []
box_node_names = []

PREFERRED_CF_IPS = [
    {"tag": "优选-090227", "addr": "cf.090227.xyz", "is_v6": False},
    {"tag": "优选-182682", "addr": "cloudflare.182682.xyz", "is_v6": False},
    {"tag": "优选-Shopify", "addr": "www.shopify.com", "is_v6": False},
    {"tag": "优选-IPv6", "addr": "2606:4700::0", "is_v6": True}
]

if os.path.exists(nodes_db):
    with open(nodes_db, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            parts = {k: v for item in line.split("|") if "=" in item for k, v in [item.split("=", 1)]}
            node_type = parts.get("TYPE")

            if node_type == "vless-reality":
                name = parts.get("NAME", "node").replace("-in-", "-out-")
                ip, port_val, uuid, pub, shortid, domain = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PUB"), parts.get("SHORTID"), parts.get("DOMAIN", "gateway.icloud.com")
                mi_node_names.append(name)
                box_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: {domain}
    reality-opts:
      public-key: {pub}
      short-id: {shortid}
      support-x25519mlkem768: false""")
                box_outbounds.append({"type": "vless", "tag": name, "server": ip, "server_port": int(port_val), "uuid": uuid, "flow": "xtls-rprx-vision", "tls": {"enabled": True, "server_name": domain, "utls": {"enabled": True, "fingerprint": "chrome"}, "reality": {"enabled": True, "public_key": pub, "short_id": shortid}}})
                all_links.append(f"vless://{uuid}@{ip}:{port_val}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={domain}&fp=chrome&pbk={pub}&sid={shortid}#{urllib.parse.quote(name)}")

            elif node_type == "hysteria2":
                name = parts.get("NAME", "hy2-node").replace("-in-", "-out-")
                ip, port_val, password, fingerprint, sni = parts.get("IP"), parts.get("PORT"), parts.get("PASSWORD"), parts.get("FINGERPRINT"), parts.get("SNI", "gateway.icloud.com")
                mi_node_names.append(name)
                box_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: hysteria2
    server: {ip}
    port: {port_val}
    password: {password}
    sni: {sni}
    skip-cert-verify: false
    fingerprint: {fingerprint}
    alpn:
      - h3""")
                box_outbounds.append({"type": "hysteria2", "tag": name, "server": ip, "server_port": int(port_val), "password": password, "tls": {"enabled": True, "server_name": sni, "insecure": True, "alpn": ["h3"]}})
                all_links.append(f"hysteria2://{password}@{ip}:{port_val}?sni={sni}&pinSHA256={fingerprint}#{urllib.parse.quote(name)}")

            elif node_type == "tuic":
                name = parts.get("NAME", "tuic-node").replace("-in-", "-out-")
                ip, port_val, tuic_uuid, password, fingerprint, sni = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PASSWORD"), parts.get("FINGERPRINT"), parts.get("SNI", "www.apple.com")
                mi_node_names.append(name)
                box_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: tuic
    server: {ip}
    port: {port_val}
    uuid: {tuic_uuid}
    password: {password}
    sni: {sni}
    skip-cert-verify: false
    fingerprint: {fingerprint}
    congestion-controller: bbr
    alpn:
      - h3""")
                box_outbounds.append({"type": "tuic", "tag": name, "server": ip, "server_port": int(port_val), "uuid": tuic_uuid, "password": password, "tls": {"enabled": True, "server_name": sni, "insecure": True, "alpn": ["h3"]}, "congestion_control": "bbr"})
                all_links.append(f"tuic://{tuic_uuid}:{password}@{ip}:{port_val}?sni={sni}&congestion_control=bbr&alpn=h3&pinSHA256={fingerprint}&allow_insecure=1#{urllib.parse.quote(name)}")

            elif node_type in ["mieru-tcp", "mieru-udp"]:
                name = parts.get("NAME", "mieru-node").replace("-in-", "-out-")
                ip, port_val, username, password = parts.get("IP"), parts.get("PORT"), parts.get("USER"), parts.get("PASS")
                transport_type = "TCP" if node_type == "mieru-tcp" else "UDP"
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: mieru
    server: {ip}
    port: {port_val}
    username: {username}
    password: {password}
    transport: {transport_type}""")
                all_links.append(f"mierus://{urllib.parse.quote(username)}:{urllib.parse.quote(password)}@{ip}:{port_val}?profile={urllib.parse.quote(name)}&port={port_val}&protocol={transport_type}#{urllib.parse.quote(name)}")

            elif node_type == "snell":
                name = parts.get("NAME", "snell-node").replace("-in-", "-out-")
                ip, port_val, psk = parts.get("IP"), parts.get("PORT"), parts.get("PSK")
                v_version = int(parts.get("VERSION", "6"))
                v_mode = parts.get("MODE", "default")
                mi_node_names.append(name)
                box_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: snell
    server: {ip}
    port: {port_val}
    psk: {psk}
    version: {v_version}
    udp: true
    mode: {v_mode}""")
                box_outbounds.append({"type": "snell", "tag": name, "server": ip, "server_port": int(port_val), "version": v_version, "psk": psk, "mode": v_mode})
                all_links.append(f"snell://{psk}@{ip}:{port_val}?version={v_version}&mode={v_mode}#{urllib.parse.quote(name)}")

            elif node_type == "shadowquic":
                name = parts.get("NAME", "shadowquic-node").replace("-in-", "-out-")
                ip, port_val, username, password = parts.get("IP"), parts.get("PORT"), parts.get("USER"), parts.get("PASS")
                jls_addr = parts.get("JLS", "download.nvidia.com:443")
                sni_domain = jls_addr.split(":")[0] if ":" in jls_addr else jls_addr
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: shadowquic
    server: {ip}
    port: {port_val}
    username: {username}
    password: {password}
    sni: {sni_domain}
    alpn:
      - h3
    quic-versions:
      - v1
    congestion-controller: bbr""")
                all_links.append(f"sq://{username}:{password}@{ip}:{port_val}?sni={sni_domain}&udp_mode=datagram&congestion=bbr#{urllib.parse.quote(name)}")

            elif node_type == "anytls":
                name = parts.get("NAME", "anytls-node").replace("-in-", "-out-")
                mode = parts.get("MODE", "standard")
                ip, port_val, username, password = parts.get("IP"), parts.get("PORT"), parts.get("USER"), parts.get("PASS")
                dest_raw = parts.get("DEST", "")
                domain = dest_raw.split(":")[0] if ":" in dest_raw else dest_raw
                mi_node_names.append(name)
                if mode == "standard":
                    mi_proxies.append(f"""  - name: "{name}"
    type: anytls
    server: {ip}
    port: {port_val}
    password: "{password}"
    skip-cert-verify: true
    udp: true""")
                    box_node_names.append(name)
                    box_outbounds.append({"type": "anytls", "tag": name, "server": ip, "server_port": int(port_val), "password": password, "tls": {"enabled": True, "insecure": True}})
                    all_links.append(f"anytls://{password}@{ip}:{port_val}?insecure=1&security=tls&type=tcp&headerType=none#{urllib.parse.quote(name)}")
                elif mode == "shadowtls":
                    mi_proxies.append(f"""  - name: "{name}"
    type: anytls
    server: {ip}
    port: {port_val}
    password: "{password}"
    sni: "{domain}"
    udp: true
    shadow-tls-opts:
      version: 3
      password: "{password}" """)
                elif mode == "restls":
                    mi_proxies.append(f"""  - name: "{name}"
    type: anytls
    server: {ip}
    port: {port_val}
    password: "{password}"
    sni: "{domain}"
    udp: true
    restls-opts:
      password: "{password}"
      version-hint: "tls13" """)
                elif mode == "jls":
                    mi_proxies.append(f"""  - name: "{name}"
    type: anytls
    server: {ip}
    port: {port_val}
    password: "{password}"
    sni: "{domain}"
    udp: true
    jls-opts:
      username: "{username}"
      password: "{password}" """)

            elif node_type == "xhttp-reality":
                name = parts.get("NAME", "xhttp-reality-node").replace("-in-", "-out-")
                ip, port_val, uuid, pub, shortid, domain = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PUB"), parts.get("SHORTID"), parts.get("DOMAIN", "gateway.icloud.com")
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: xhttp
    tls: true
    udp: true
    client-fingerprint: chrome
    servername: {domain}
    xhttp-opts:
      path: "/yindun-xr"
      host: "{domain}"
      mode: "stream-up"
    reality-opts:
      public-key: {pub}
      short-id: {shortid}
      support-x25519mlkem768: false""")
                all_links.append(f"vless://{uuid}@{ip}:{port_val}?encryption=none&security=reality&sni={domain}&fp=chrome&pbk={pub}&sid={shortid}&type=xhttp&host={domain}&path=%2Fyindun-xr&mode=stream-up#{urllib.parse.quote(name)}")
            elif node_type == "xhttp-shadowtls":
                name = parts.get("NAME", "xhttp-stls-node").replace("-in-", "-out-")
                ip, port_val, uuid, password = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PASS")
                dest_raw = parts.get("DEST", "download.nvidia.com:443")
                domain = dest_raw.split(":")[0] if ":" in dest_raw else dest_raw
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: xhttp
    tls: true
    udp: true
    client-fingerprint: chrome
    servername: {domain}
    xhttp-opts:
      path: "/yindun-xst"
      host: "{domain}"
      mode: "stream-up"
    shadow-tls-opts:
      version: 3
      password: "{password}"
      servername: "{domain}" """)
            elif node_type == "xhttp-restls":
                name = parts.get("NAME", "xhttp-rtls-node").replace("-in-", "-out-")
                ip, port_val, uuid, password = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PASS")
                dest_raw = parts.get("DEST", "cdn.akamai.steamstatic.com:443")
                domain = dest_raw.split(":")[0] if ":" in dest_raw else dest_raw
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: xhttp
    tls: true
    udp: true
    servername: {domain}
    xhttp-opts:
      path: "/yindun-xrt"
      host: "{domain}"
      mode: "stream-up"
    restls-opts:
      password: "{password}"
      version-hint: "tls13" """)
            elif node_type == "xhttp-jls":
                name = parts.get("NAME", "xhttp-jls-node").replace("-in-", "-out-")
                ip, port_val, uuid, password = parts.get("IP"), parts.get("PORT"), parts.get("UUID"), parts.get("PASS")
                dest_raw = parts.get("DEST", "update.code.visualstudio.com:443")
                domain = dest_raw.split(":")[0] if ":" in dest_raw else dest_raw
                mi_node_names.append(name)
                mi_proxies.append(f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: xhttp
    tls: true
    udp: true
    servername: {domain}
    xhttp-opts:
      path: "/yindun-xj"
      host: "{domain}"
      mode: "stream-up"
    jls-opts:
      username: "1"
      password: "{password}" """)

            elif node_type == "argo-wstls":
                base_name = parts.get("NAME", "argo-node").replace("-in-", "-out-")
                domain = parts.get("DOMAIN")
                uuid = parts.get("UUID")
                path = parts.get("PATH", "/yindun-argo-wstls")
                port = 443
                is_tls = True
                
                if domain and uuid:
                    main_name = f"{base_name}-(443端口主节点)"
                    mi_node_names.append(main_name)
                    box_node_names.append(main_name)
                    
                    mi_proxies.append(f"""  - name: "{main_name}"
    type: vless
    server: {domain}
    port: {port}
    uuid: {uuid}
    network: ws
    tls: true
    udp: true
    servername: {domain}
    ws-opts:
      path: "{path}" """)
                    
                    box_outbounds.append({
                        "type": "vless", "tag": main_name, "server": domain, "server_port": port, "uuid": uuid, "network": "ws",
                        "tls": {"enabled": is_tls, "server_name": domain}, "transport": {"type": "ws", "path": path}
                    })
                    all_links.append(f"vless://{uuid}@{domain}:{port}?encryption=none&security=tls&type=ws&host={domain}&path={urllib.parse.quote(path)}&sni={domain}#{urllib.parse.quote(main_name)}")

                    for pref in PREFERRED_CF_IPS:
                        pref_tag = pref["tag"]
                        pref_addr = pref["addr"]
                        is_v6 = pref["is_v6"]
                        
                        node_label = f"{base_name}-(443端口-{pref_tag})"
                        mi_node_names.append(node_label)
                        box_node_names.append(node_label)
                        
                        link_server_addr = f"[{pref_addr}]" if is_v6 else pref_addr
                        
                        mi_proxies.append(f"""  - name: "{node_label}"
    type: vless
    server: {pref_addr}
    port: {port}
    uuid: {uuid}
    network: ws
    tls: true
    udp: true
    servername: {domain}
    skip-cert-verify: true
    ws-opts:
      path: "{path}"
      headers:
        Host: {domain}""")
                        
                        box_outbounds.append({
                            "type": "vless", "tag": node_label, "server": pref_addr, "server_port": port, "uuid": uuid, "network": "ws",
                            "tls": {"enabled": is_tls, "server_name": domain, "insecure": True},
                            "transport": {"type": "ws", "path": path, "headers": {"Host": domain}}
                        })
                        all_links.append(f"vless://{uuid}@{link_server_addr}:{port}?encryption=none&security=tls&type=ws&host={domain}&path={urllib.parse.quote(path)}&sni={domain}#{urllib.parse.quote(node_label)}")

mi_proxies_list_6 = "\n".join([f'      - "{n}"' for n in mi_node_names]) if mi_node_names else '      - "DIRECT"'

mihomo_full_config = f"""port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true 
  listen: "0.0.0.0:1053"
  ipv6: true
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: "arc"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  default-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver:
    - "https://1.1.1.1/dns-query"
    - "https://8.8.8.8/dns-query"
  proxy-server-nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"

proxies:
""" + ("\n\n".join(mi_proxies) if mi_proxies else "") + f"""

proxy-groups:
  - name: 负载均衡
    type: load-balance
    url: https://www.gstatic.com/generate_204
    interval: 300
    strategy: round-robin
    proxies:
{mi_proxies_list_6}

  - name: 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
{mi_proxies_list_6}

  - name: 🌍选择代理节点
    type: select
    proxies:
      - 负载均衡
      - 自动选择
      - DIRECT
{mi_proxies_list_6}

rules:
  - GEOIP,LAN,DIRECT
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
"""

with open(mi_links_path, "w", encoding="utf-8") as f: f.write(mihomo_full_config)

selector_outbounds = ["auto"] + box_node_names if box_node_names else ["direct"]
auto_outbounds = box_node_names if box_node_names else ["direct"]

singbox_full_config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"]}],
    "outbounds": [
        {"type": "selector", "tag": "proxy", "default": "auto", "outbounds": selector_outbounds},
        {"type": "urltest", "tag": "auto", "outbounds": auto_outbounds, "url": "https://www.gstatic.com/generate_204"},
        {"type": "direct", "tag": "direct"}
    ] + box_outbounds,
    "route": {"final": "proxy"}
}

with open(box_links_path, "w", encoding="utf-8") as f: json.dump(singbox_full_config, f, indent=2, ensure_ascii=False)
with open(all_links_path, "w", encoding="utf-8") as f: f.write("\n".join(all_links) + "\n")
EOF
}

prepare_python_server() {
    cat << 'EOF' > "$PYTHON_SERVER_FILE"
import http.server, urllib.parse, sys, os, base64

port, token, config_dir = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class MultiSubHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        if params.get("token", [""])[0] != token:
            self.send_response(403); self.end_headers(); self.wfile.write(b"Access Denied"); return

        if parsed.path in ["/", "/all"]:
            self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
            f_path = os.path.join(config_dir, "all_links.txt")
            if os.path.exists(f_path):
                with open(f_path, "rb") as f: self.wfile.write(base64.b64encode(f.read()))
        elif parsed.path == "/raw":
            self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
            f_path = os.path.join(config_dir, "all_links.txt")
            if os.path.exists(f_path):
                with open(f_path, "rb") as f: self.wfile.write(f.read())
        elif parsed.path == "/box":
            self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8"); self.end_headers()
            f_path = os.path.join(config_dir, "box_links.json")
            if os.path.exists(f_path):
                with open(f_path, "rb") as f: self.wfile.write(f.read())
        elif parsed.path == "/mi":
            self.send_response(200); self.send_header("Content-Type", "text/yaml; charset=utf-8"); self.end_headers()
            f_path = os.path.join(config_dir, "mi_links.yaml")
            if os.path.exists(f_path):
                with open(f_path, "rb") as f: self.wfile.write(f.read())
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b"Not Found")

    def log_message(self, format, *args): pass

http.server.HTTPServer(("0.0.0.0", port), MultiSubHandler).serve_forever()
EOF
}

start_daemon() {
    local config_script="$(dirname "${BASH_SOURCE[0]}")/config.sh"
    [ ! -f "$config_script" ] && config_script="${CONFIG_DIR}/config.sh"
    if [ -f "$config_script" ]; then
        echo -e "${CYAN}[INFO] 正在自动触发底层 config.sh 刷新 Argo 443 隧道与域名...${NC}"
        bash "$config_script" reload-argo
    fi

    [ ! -f "$NODES_DB" ] && touch "$NODES_DB"
    stop_daemon
    [ ! -f "$TOKEN_FILE" ] && openssl rand -hex 32 > "$TOKEN_FILE"

    local web_port=$(get_web_port)
    SUB_TOKEN=$(cat "$TOKEN_FILE")

    prepare_subscription_generator
    python3 "$SUBSCRIPTION_GENERATOR"
    prepare_python_server
    manage_firewall_port "add" "$web_port" "tcp" "YinDun-Sub-${web_port}"
    local server_ip=$(get_public_ip)

    cd "${CONFIG_DIR}" || exit
    nohup python3 sub_server.py "$web_port" "$SUB_TOKEN" "${CONFIG_DIR}" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}  YinDun 客户端订阅守护进程已成功启动并生成节点矩阵！${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo -e "1. Base64 聚合订阅 (通用/Clash): ${CYAN}http://${server_ip}:${web_port}/?token=${SUB_TOKEN}${NC}"
    echo -e "2. 明文链接列表 (Raw Links)   : ${CYAN}http://${server_ip}:${web_port}/raw?token=${SUB_TOKEN}${NC}"
    echo -e "3. Mihomo 原生完整 YAML 配置  : ${CYAN}http://${server_ip}:${web_port}/mi?token=${SUB_TOKEN}${NC}"
    echo -e "4. Sing-box 客户端 JSON 配置  : ${CYAN}http://${server_ip}:${web_port}/box?token=${SUB_TOKEN}${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_daemon
fi
