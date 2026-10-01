#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/jader702/strenning.git"
INSTALL_DIR="/opt/camera-streaming"
HLS_DIR="/var/www/cameras/hls"
WEB_DIR="/var/www/cameras"
DOMAIN="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Execute como root: sudo bash install.sh SEU_DOMINIO"
  exit 1
fi

if [ -z "$DOMAIN" ]; then
  echo "Uso: sudo bash install.sh SEU_DOMINIO"
  echo "Exemplo: sudo bash install.sh cameras.exemplo.com.br"
  exit 1
fi

echo "==> Instalando dependencias"
apt-get update -qq
apt-get install -y -qq git ffmpeg python3 python3-pip nginx certbot python3-certbot-nginx openssl

echo "==> Instalando Flask"
pip3 install -q flask

echo "==> Clonando repositorio"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull
else
  rm -rf "$INSTALL_DIR"
  git clone "$REPO" "$INSTALL_DIR"
fi

echo "==> Criando diretorios"
mkdir -p "$HLS_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/secrets" "$INSTALL_DIR/admin"

echo "==> Permissoes"
chown -R root:www-data "$INSTALL_DIR"
chmod -R 750 "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR/secrets"
chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true
chmod -R 755 "$WEB_DIR"

echo "==> Criando channels.env vazio (se nao existir)"
if [ ! -f "$INSTALL_DIR/config/channels.env" ]; then
  cat > "$INSTALL_DIR/config/channels.env" <<'ENV'
# Public camera channel metadata. Do not put RTSP URLs or passwords here.
CHANNELS=""
ENV
  chown root:root "$INSTALL_DIR/config/channels.env"
  chmod 644 "$INSTALL_DIR/config/channels.env"
fi

echo "==> Tornando scripts executaveis"
chmod +x "$INSTALL_DIR/bin/admin-api.py"
chmod +x "$INSTALL_DIR/bin/generate-status.sh"

echo "==> Atualizando dominio nos scripts"
sed -i "s/cameras\.radiowebcriativa\.com\.br/$DOMAIN/g" "$INSTALL_DIR/bin/generate-status.sh"

echo "==> Instalando status.json inicial"
echo '{"generated_at":null,"channels":[]}' > "$INSTALL_DIR/admin/status.json"
chown root:www-data "$INSTALL_DIR/admin/status.json"
chmod 640 "$INSTALL_DIR/admin/status.json"

echo "==> Copiando painel para webroot"
mkdir -p "$WEB_DIR/admin"
cp "$INSTALL_DIR/admin/index.html" "$WEB_DIR/admin/"
cp "$INSTALL_DIR/admin/app.js"    "$WEB_DIR/admin/"
cp "$INSTALL_DIR/admin/style.css" "$WEB_DIR/admin/"
cp "$INSTALL_DIR/admin/status.json" "$WEB_DIR/admin/"
chown -R www-data:www-data "$WEB_DIR/admin"

echo "==> Instalando systemd units"
cp "$INSTALL_DIR/systemd/camera-streaming-admin-api.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/camera-streaming-status.service"    /etc/systemd/system/
cp "$INSTALL_DIR/systemd/camera-streaming-status.timer"      /etc/systemd/system/
systemctl daemon-reload

echo "==> Configurando Nginx para $DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat > "$NGINX_CONF" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WEB_DIR;
    index index.html;

    location /admin/api/ {
        proxy_pass http://127.0.0.1:8092;
        proxy_set_header Host \$host;
        proxy_read_timeout 30s;
    }

    location /admin/ {
        auth_basic "Painel";
        auth_basic_user_file /etc/nginx/.cameras-htpasswd;
        alias $WEB_DIR/admin/;
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store, no-cache";
    }

    location /hls/ {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
        add_header Access-Control-Allow-Origin "*";
    }

    location / {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
        try_files \$uri \$uri/ =404;
    }
}
NGINX

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t

echo "==> Configurando senha do painel admin"
echo ""
echo "Digite a senha para acessar o painel /admin/:"
htpasswd -c /etc/nginx/.cameras-htpasswd admin
chmod 640 /etc/nginx/.cameras-htpasswd

echo "==> Iniciando servicos"
systemctl enable --now camera-streaming-admin-api
systemctl enable --now camera-streaming-status.timer
systemctl reload nginx

echo ""
echo "==> SSL com Let's Encrypt"
read -r -p "Configurar SSL automaticamente agora? (s/N): " ssl_resp
if [[ "${ssl_resp,,}" == "s" ]]; then
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
  systemctl reload nginx
fi

echo ""
echo "============================================"
echo " Instalacao concluida!"
echo " Site:   http://$DOMAIN/"
echo " Painel: http://$DOMAIN/admin/"
echo "============================================"
