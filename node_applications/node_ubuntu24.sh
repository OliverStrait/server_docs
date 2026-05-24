#!/bin/bash

## Node service installation and reverse proxy setup.
### LIMITS
### Ubuntu-version: MongoDB has binaries only for 24.04 LTS, latest 26 version is not yet supported

set -e

APP_ROOT_DIR="/opt/node_apps"
APP_NAME="my-node-app"
APP_USER="www-data"
APP_GROUP="www-data"

enable_service() {
    sudo systemctl daemon-reload
    sudo systemctl enable $1 --now
}

### Updates dependencies and system
update_dependencies() {
    echo "Updating system..."
    sudo apt update && sudo apt upgrade -y

    echo "Installing base packages..."
    sudo apt install -y curl wget gnupg2 ca-certificates lsb-release software-properties-common ufw

    # -----------------------------
    # MariaDB
    # -----------------------------
    echo "Installing Mysql..."
    sudo apt install -y mysql-server mysql-client
    enable_service mariadb 

    # -----------------------------
    # Node.js (LTS)
    # -----------------------------
    echo "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs build-essential

    # -----------------------------
    # MongoDB
    # https://www.mongodb.com/docs/v8.0/tutorial/install-mongodb-on-ubuntu/
    # FOR UBUNTU 24.04 LTS. for other systems, reference manual link ^^
    # -----------------------------
    echo "Installing MongoDB..."
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
    sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
    --dearmor

    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ]\
    https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" |\
    sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
    ### SYSTEM DEPENDENT CODE ENDED ###

    sudo apt-get update
    sudo apt install -y mongodb-org
    ## 
    sudo chown mongodb:mongodb /var/lib/mongodb /var/log/mongodb
    sudo systemctl daemon-reload
    enable_service mongod 

    # -----------------------------
    # Nginx
    # -----------------------------
    echo "Installing Nginx..."
    sudo apt install -y nginx
    enable_service nginx 

    # -----------------------------
    # Fail2Ban
    # -----------------------------
    echo "Installing Fail2Ban..."
    sudo apt install -y fail2ban
    enable_service fail2ban 
}


fail_to_ban_setup() {
    # Fail2Ban Basic jail config
    sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF

    sudo systemctl restart fail2ban

}

sample_program() {
    
    cat <<EOF > $1/backend/package.json
{
  "name": "myapp",
  "version": "1.0.0",
  "description": "Sample Node app",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  }
}
EOF

# Sample Node app
    cat <<EOF > $1/backend/index.js
const http = require('http');

const server = http.createServer((req, res) => {
    res.writeHead(200);
    res.end("✅ Node app running\\n");
});

server.listen($2, () => {
    console.log("Server running on port $2");
});
EOF

}


app_creation() {
    # -----------------------------
    # App directory
    # -----------------------------
    echo "Creating app directory..."
    
    # Ask for application name
    read -p "Enter application name: " APP_NAME
    # Ask for port
    read -p "Enter application port: " APP_PORT
    read -p "Enter application reverse proxy port: " APP_PROXY_PORT
    read -p "Enter application reverse proxy path (/, /app, /test): " APP_PROXY_PATH
    APP_DIR="$APP_ROOT_DIR/$APP_NAME"
    APP_URL="http://127.0.0.1:$APP_PORT"
    sudo mkdir -p $APP_DIR "$APP_DIR/backend"
    sudo chown -R $APP_USER:$APP_GROUP $APP_DIR
    sudo usermod -aG $APP_GROUP $USER
    sample_program $APP_DIR $APP_PORT 


    # -----------------------------
    # systemd service
    # -----------------------------
    APP_LOGS="/var/log/$APP_NAME.log"
    APP_ERR="/var/log/$APP_NAME.log"
    echo "Creating systemd service..."
    APP_SERVICE_DIR="/etc/systemd/system/$APP_NAME.service"
    sudo tee $APP_SERVICE_DIR > /dev/null <<EOF
[Unit]
Description=Node.js App
After=network.target mysql.service mongod.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR/backend
ExecStart=/usr/bin/npm run start
Restart=always
Environment=NODE_ENV=production

StandardOutput=append:$APP_LOGS
StandardError=append:$APP_ERR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable $APP_NAME
    sudo systemctl start $APP_NAME

}


# -----------------------------
# Nginx reverse proxy + rate limit
# -----------------------------
reverse_proxy() {
    nxing_proxy_page="/etc/nginx/sites-available/$APP_NAME"
    echo "Configuring Nginx..."
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo tee $nxing_proxy_page > /dev/null <<EOF
limit_req_zone \$binary_remote_addr zone=auth_limit:10m rate=5r/s;

server {
    listen $1;
    server_name _;

    location / {
        proxy_pass $APP_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
    }

    location /auth {
        limit_req zone=auth_limit burst=10 nodelay;

        proxy_pass $APP_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

    sudo ln -s $nxing_proxy_page /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl reload nginx
}

# -----------------------------
# Firewall
# -----------------------------
local_firewall_install() {

    echo "Configuring firewall..."
    sudo ufw allow OpenSSH
    sudo ufw allow 'Nginx Full'
    sudo ufw --force enable

}


# -----------------------------
# Setup mysql root password
# -----------------------------
set_Mysql_ROOT_PASS() {
    # SET PASSWORD (CHANGE THIS)
    read -p "Mysql root password: " password
    sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$password'; FLUSH PRIVILEGES;"
}


print_services_status() {
    echo "Services:"
    systemctl status mariadb --no-pager | head -n 2
    systemctl status mongod --no-pager | head -n 2
    systemctl status nginx --no-pager | head -n 2
    systemctl status $APP_NAME --no-pager | head -n 3
}

save_report() {
    echo "Saving setup report..."

    REPORT_FILE="$HOME/${APP_NAME}_setup_report.txt"

    cat <<EOF > "$REPORT_FILE"
===== NODE APP SETUP REPORT =====

Date: $(date)

App Name: $APP_NAME
App Directory: $APP_DIR
App Port: $APP_PORT
App URL: $APP_URL
Nginx settings: $nxing_proxy_page 

Systemd Service:
App seervice congig: $APP_SERVICE_DIR
App logs (stdout): $APP_LOGS
App errllogs (stderr):$APP_ERR

User running app: $APP_USER
Group: $APP_GROUP

Services:
- MariaDB: $(systemctl is-active mariadb)
- MongoDB: $(systemctl is-active mongod)
- Nginx: $(systemctl is-active nginx)
- Node App ($APP_NAME): $(systemctl is-active $APP_NAME)

Firewall:
$(sudo ufw status)

=================================
EOF

    echo "✅ Report saved to: $REPORT_FILE"
}


read -p "Update system and dependencies (y/n). : " update
if [[ "$update" =~ ^(yes|y)$ ]]; then
    update_dependencies
else    
    echo "System updates ignored"
fi

read -p "Continue with app installation? (y/n): " continue
if [[ "$continue" =~ ^(yes|y)$ ]]; then
    app_creation
    fail_to_ban_setup
    reverse_proxy $APP_PROXY_PORT $APP_PROXY_PATH
else
    echo "No app installed!!"
fi

read -p "Setup local firewall (not needed if external system does this)? (y/n): " continue
if [[ "$continue" =~ ^(yes|y)$ ]]; then
    local_firewall_install
fi

read -p "Setup mysql root password? (y/n): " continue
if [[ "$continue" =~ ^(yes|y)$ ]]; then
    set_Mysql_ROOT_PASS
fi
# -----------------------------
# Done
# -----------------------------
print_services_status
save_report
echo "✅ INSTALL COMPLETE"


