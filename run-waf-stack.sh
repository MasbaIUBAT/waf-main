#!/bin/bash
set -e

# ================= CONFIG =================
BACKEND_IP="13.232.105.75"   # destination server
BASE_DIR="/root/waf-stack"
# ==========================================

echo "====================================="
echo " WAF STACK DEPLOYMENT"
echo " Backend: $BACKEND_IP"
echo "====================================="

# Cleanup
docker rm -f nginx-proxy apache-waf 2>/dev/null || true
rm -rf $BASE_DIR

# Create directories
mkdir -p \
  $BASE_DIR/nginx \
  $BASE_DIR/apache \
  $BASE_DIR/logs/apache \
  $BASE_DIR/logs/modsecurity

# Permissions for ModSecurity (important)
chown -R 33:33 $BASE_DIR/logs/modsecurity
chmod -R 777 $BASE_DIR/logs/modsecurity

# ================= docker-compose.yml =================
cat > $BASE_DIR/docker-compose.yml <<EOF
services:
  apache-waf:
    image: masbaaxiler/apache-waf:latest
    container_name: apache-waf
    volumes:
      - ./apache/000-default.conf:/etc/apache2/sites-enabled/000-default.conf:ro
      - ./logs/apache:/var/log/apache2
      - ./logs/modsecurity:/var/log/modsecurity
    networks:
      - wafnet

  nginx:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - apache-waf
    networks:
      - wafnet

networks:
  wafnet:
    driver: bridge
EOF

# ================= nginx.conf =================
cat > $BASE_DIR/nginx/nginx.conf <<EOF
events {}

http {
  server {
    listen 80;

    location / {
      proxy_pass http://apache-waf:80;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
  }
}
EOF

# ================= Apache WAF vhost =================
cat > $BASE_DIR/apache/000-default.conf <<EOF
<VirtualHost *:80>
    ServerName waf

    ProxyPreserveHost On
    ProxyPass        / http://$BACKEND_IP/
    ProxyPassReverse / http://$BACKEND_IP/

    # ---- ModSecurity ----
    SecRuleEngine On
    SecAuditEngine RelevantOnly
    SecAuditLogRelevantStatus "^(?:5|4(?!04))"
    SecAuditLogParts ABIJDEFHZ
    SecAuditLogType Serial
    SecAuditLog /var/log/modsecurity/audit.log

    Include /etc/modsecurity/modsecurity.conf
    Include /etc/modsecurity/crs/crs-setup.conf
    Include /etc/modsecurity/crs/rules/*.conf

    ErrorLog  /var/log/apache2/error.log
    CustomLog /var/log/apache2/access.log combined
</VirtualHost>
EOF

# ================= Start stack =================
cd $BASE_DIR
docker compose up -d

echo ""
echo "====================================="
echo " STACK IS UP"
echo "====================================="
echo "Normal test:"
echo "  curl http://<WAF_PUBLIC_IP>/"
echo ""
echo "Attack test:"
echo "  curl -v \"http://<WAF_PUBLIC_IP>/?id=1%27%20OR%20%271%27=%271\""
echo ""
echo "Logs:"
echo "  Apache access  : $BASE_DIR/logs/apache/access.log"
echo "  Apache error   : $BASE_DIR/logs/apache/error.log"
echo "  ModSecurity    : $BASE_DIR/logs/modsecurity/audit.log"

