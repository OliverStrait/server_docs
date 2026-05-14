#!/bin/bash
### Server setup for Debian/Ubuntu based linux
set -e
DEFAULT_NAME="client_app"
APP_USER="www-data"
APP_GROUP="www-data"
## $APP_USER:$APP_GROUP
echo "Python flask server installation using nginx and Gunigorn"
echo "You can either setup new application or/and update system and packets"

read -p "Update system and dependencies (y/n). : " update
if [[ "$update" =~ ^(yes|y)$ ]]; then
    echo "System updates:"
    sudo apt update && echo "OK"
    sudo apt upgrade -y && echo "OK"
    sudo apt install -y python3 python3-pip python3-venv nginx mysql-server git && echo "OK- Python"
    sudo systemctl enable mysql --now && echo "OK Started mysql"
    sudo systemctl enable nginx --now && echo "OK Started nginx"
    ## Build tools for Python mysql-client dependency
    sudo apt-get install -y python3-dev default-libmysqlclient-dev build-essential pkg-config && echo "OK"
    read -p "Continue with app installation? (y/n): " continue
    if [[ "$continue" =~ ^(yes|y)$ ]]; then
        echo ""
    else
        echo "No app installed";exit 0
    fi
else
    echo "Skiped updates"
fi

read -p "Flask application name (default: $DEFAULT_NAME):" app_name
read -p "APP port:" app_port
read -p "App path in port (/, /api, etc.):" app_path
if [ -z "$app_name" ]; then
  app_name="$DEFAULT_NAME"
  echo "Using default app-name:$app_name"
fi

### APP FOLDER
app_folder=/opt/$app_name
echo "Creating application path to: $app_folder"
sudo mkdir -p $app_folder || true $$ echo "OK - app base folder"
cd $app_folder
sudo mkdir logs config app || true $$ echo "OK - subfolders"

sudo chown -R "$APP_USER":"$APP_GROUP"  $app_folder

## socket run dir
run_dir="/run/$app_name"
## Socket dir
socket_dir="$run_dir/$app_name.sock"
## socket  url
socket_url=unix:$socket_dir

## socket
echo "Create unix-socket paths:" 
sudo mkdir -p $run_dir || true && echo "rundir created: $run_dir"
sudo chown -R $APP_USER:$APP_GROUP $run_dir $socket_dir || true && echo "socket created: $socket_dir"
sudo cmod -R 
## app path

# Python Venv
echo "Python enviroment:"
python3 -m venv venv && echo "OK"

echo "Entering into python virtual env, install python dependencies"
source venv/bin/activate
pip install flask flask-mysqldb gunicorn python-dotenv && echo "OK"

echo "Creating Mockup application: app/app.py"
sudo cat <<EOF > app/app.py
from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello_world():
    return 'Hello, World! I am application: $app_name'
    
if __name__ == '__main__':
    app.run(host="0.0.0.0", port=5000, debug=True)
EOF

echo "APP Folder content: "
sudo ls || true

gunigorn_accesslog="$app_folder/logs/access.log"
gunicorn_errorlog="$app_folder/logs/error.log"
gunicorn_config_file="$app_folder/config/gunicorn_config.py"
### Gunicorn
echo -e "\n\n## Gunicorn setup ##"
echo "Config file, config/gunicorn_config.py:"
sudo tee "$gunicorn_config_file" > /dev/null <<EOF
bind = "$socket_url"
workers = 3
worker_class = "sync"
accesslog = "$gunigorn_accesslog"
errorlog = "$gunicorn_errorlog"
user = "$APP_USER"
group = "$APP_GROUP"
EOF

### systemd service
echo -e "\n\nCreating systemd service: $app_service"
app_service="$app_name.service"
gunicorn_service_conf="/etc/systemd/system/$app_service"

sudo tee "$gunicorn_service_conf" > /dev/null <<EOF
[Unit]
Description=gunicorn daemon for [$app_name]
After=network.target mysql.service

[Service]
User=$APP_USER
Group=$APP_GROUP
Environment="PATH=$app_folder/venv/bin"
RuntimeDirectory=$app_name
RuntimeDirectoryMode=0755

WorkingDirectory=$app_folder/app
ExecStart=$app_folder/venv/bin/gunicorn -c $app_folder/config/gunicorn_config.py app:app

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n\nStarting the service: "
sudo systemctl daemon-reload
sudo systemctl enable $app_service --now && echo "OK"

### Nginx reverse proxy
nginx_site="/etc/nginx/sites-available/$app_name"
echo "Nginx setup:"
sudo tee "$nginx_site" > /dev/null <<EOF
server {
listen $app_port;
server_name _;
location $app_path {
        include proxy_params;
        proxy_pass http://$socket_url:/;
        }
}
EOF
echo "Activate nginx app site:"
sudo ln -s $nginx_site /etc/nginx/sites-enabled/ || true && echo "App Site activated"
sudo rm /etc/nginx/sites-enabled/default || true && echo "Nginx default removed"
sudo nginx -t
sudo systemctl restart nginx

echo "DO you want to install local firewall? (y/n):"
echo "(Skip this is you have external control, cloud, etc.)"
read firewall

if [[ "$firewall" =~ ^(yes|y)$ ]]; then
    sudo ufw allow OpenSSH
    sudo ufw allow 80/tcp
    sudo ufw enable
    sudo ufw status numbered
    firewall="True"
else
    echo "No local firewall"
    firewall="False"
fi

echo "#######  Defined Variables  #######"
echo "App Name: $app_name"
echo "Local firewall:: $firewall"
echo "Application Folder: $app_folder"
echo "Socket run Directory: $run_dir"
echo "Socket Directory: $socket_dir"
echo "Socket URL: $socket_url"

echo "Nginx::"
echo "  Site-config: $nginx_site"
echo "Gunicorn::"
echo "  Service file: $gunicorn_service_conf"
echo "  Config = $gunicorn_config_file"
echo "  Accesslog = "$gunigorn_accesslog"
echo "  Errorlog = "$gunicorn_errorlog"

echo "!! Configure the mysql database: sudo mysql_secure_installation"
