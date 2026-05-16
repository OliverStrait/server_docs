## Certbot installation bash script.
## check latest from 
## This instruction is/was based: https://certbot.eff.org/instructions?ws=nginx&os=pip
## Generic: https://certbot.eff.org/instructions


echo "Certbot installation for nginx"

## System update
read -p "Update system and dependencies (y/n). : " update
if [[ "$update" =~ ^(yes|y)$ ]]; then
    sudo apt update
    sudo apt install -y python3 python3-dev python3-venv libaugeas-dev gcc

    sudo apt update
    sudo apt install -y python3 python3-dev python3-venv libaugeas-dev gcc
else
    echo "Updates has been skipped"
fi

read -p "Install certbot or only update: (i/u):" certbot_update
if [[ "$certbot_update" =~ ^(u|update)$ ]]; then
    sudo /opt/certbot/bin/pip install --upgrade certbot certbot-nginx
    exit 0
fi

echo "Python enviroment for certbot: /opt/certbot/"
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip

echo "Install dependencies"
sudo /opt/certbot/bin/pip install certbot certbot-nginx

echo "Creating symlink: /opt/certbot/bin/certbot /usr/local/bin/certbot"
sudo ln -s /opt/certbot/bin/certbot /usr/local/bin/certbot

## Setup nginx
echo "Installing certbot for nginx"

if ! sudo certbot --nginx; then
    echo "Installation failed"
    exit 0

fi
## Add CRON JOB TO UPDATE
echo "Installing cronjob"
echo "0 0,12 * * * root /opt/certbot/bin/python -c 'import random; import time; time.sleep(random.random() * 3600)' && sudo certbot renew -q" \
| sudo tee -a /etc/crontab > /dev/ && echo "OK"

