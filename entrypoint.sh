#!/bin/bash
. venv/bin/activate

set -euo pipefail

# Validate environment variables

MISSING=""

[ -z "${DOMAIN}" ] && MISSING="${MISSING} DOMAIN"
[ -z "${UPSTREAM}" ] && MISSING="${MISSING} UPSTREAM"
[ -z "${EMAIL}" ] && MISSING="${MISSING} EMAIL"

if [ "${MISSING}" != "" ]; then
  echo "Missing required environment variables:" >&2
  echo " ${MISSING}" >&2
  exit 1
fi

# Default other parameters

SERVER=""
[ -n "${STAGING:-}" ] && SERVER="--server https://acme-staging.api.letsencrypt.org/directory"

# Generate strong DH parameters for nginx, if they don't already exist.
[ -f /etc/ssl/dhparams.pem ] || openssl dhparam -out /etc/ssl/dhparams.pem 2048

# Template an nginx.conf
cat <<EOF >/etc/nginx/nginx.conf
user nginx;
worker_processes 2;

events {
  worker_connections 1024;
}

http {
  include mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;

  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;

  server {
    listen 443 ssl http2;
	listen [::]:443 ssl http2;
    server_name "${DOMAIN}";

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_dhparam /etc/ssl/dhparams.pem;

    ssl_ciphers "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA";
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    root /etc/letsencrypt/webrootauth;

    location / {
      proxy_pass http://${UPSTREAM};
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$remote_addr;
    }

    location /.well-known/acme-challenge {
      alias /etc/letsencrypt/webrootauth/.well-known/acme-challenge;
      location ~ /.well-known/acme-challenge/(.*) {
        add_header Content-Type application/jose+json;
      }
    }
  }

  # Redirect from port 80 to port 443
  server {
    listen 80;
    server_name "${DOMAIN}";
    return 301 https://\$server_name\$request_uri;
  }
}
EOF

# Initial certificate request
letsencrypt certonly \
  --domain ${DOMAIN} \
  --authenticator standalone \
  ${SERVER} \
  --email "${EMAIL}" --agree-tos

# Template a cronjob to reissue the certificate with the webroot authenticator
mkdir -p /etc/cron.monthly
cat <<EOF >/etc/cron.monthly/reissue
#!/bin/bash

. venv/bin/activate

set -euo pipefail

# Certificate reissue
letsencrypt certonly --renew-by-default \
  --domain "${DOMAIN}" \
  --authenticator webroot \
  --webroot-path /etc/letsencrypt/webrootauth/ ${SERVER} \
  --email "${EMAIL}" --agree-tos

# Reload nginx configuration to pick up the reissued certificates
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/cron.monthly/reissue

# Launch nginx in the foreground
/usr/sbin/nginx -g "daemon off;"
