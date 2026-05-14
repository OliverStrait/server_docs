#!/bin/bash
declare -a security_issues=()

# Päivitä linuxin kerneli
security_issue() {
    local description="$1"
    security_issues+=("$description")
    echo "Security issue: $description"
}
sudo dnf update -y
## Vaadittavat ohjelmat
## Apuohjelmia kuten c-kääntäjiä ja openssl.
sudo dnf install -y git wget which ca-certificates tar xz openssl-devel
## C ja c++ kääntäjiin liittyviä ohjelmia
sudo dnf install -y gcc gcc-c++ make zlib-devel libtool libpq-devel bzip2-devel freetype-devel libffi-devel
## Systeemikohtaisia riippuvuuksia.
sudo dnf install -y redhat-rpm-config openldap-devel
## Pythoniin ja odoon liittyviä ohjelmia/lisäosia
sudo dnf install -y python3-devel python3-pip libxslt-devel libxml2-devel libjpeg-turbo-devel

# Node.js ja npm frontend komponentteja varten
sudo dnf install -y nodejs npm
## Asennetaan tarvittavat paketit globaalina nodeen
sudo npm install -g less less-plugin-clean-css


sudo dnf install -y postgresql16 postgresql16-server
## Jos komento ei toimi, pudota versionumero 16 lopusta
## intit komento voidaan onnistuessaan suorittaa vain kerran.
sudo /usr/bin/postgresql-setup --initdb 16
#tietokannan automaattinen käynnistys
sudo systemctl enable --now postgresql


## Luodaan odoo käyttäjä tietokantaan käyttäen posgres-käyttäjää -iu
sudo -iu postgres createuser --createdb odoo

read -p "Enter a strong password for the Odoo user: " odoo_db_pass
## Korvaa strong_db_pass omalla salasanalla
if [ -n $odoo_db_pass ]; then 
    sudo -iu postgres psql -c "ALTER USER odoo WITH ENCRYPTED PASSWORD '$odoo_db_pass';"
else
    security_issue "POSGRE DATABASE: odoo user has no password"
    odoo_db_pass="False"
fi
## -m -d /opt/odoo luo kustomoitu kotikansio, minne odoo asennetaan.
## -U nimen mukainen ryhmä -s systeemi-käyttäjä -s /bin/bash antaa käyttäjälle luvan suorittaa komentoja.

sudo useradd -m -d /opt/odoo -U -r -s /bin/bash odoo
## Lukitsee salasana kirjautumisen käyttäjälle. (Lisätty turvallisuus)
sudo passwd -l odoo
# Luo odoon kansiot ja kustomimoduulien kansio.
sudo mkdir -p /var/log/odoo /opt/odoo/custom/addons

# Siirrä  kansion oikeudet odoo:lle. -R -rekursiivinen
sudo chown -R odoo:odoo /opt/odoo /opt/odoo/custom/addons
sudo chown odoo:odoo /var/log/odoo
# Rajoitetut oikeudet kansioihin
sudo chmod 750 /opt/odoo 

#lisätään ec2-user odoo-ryhmään
sudo usermod -aG odoo ec2-user
## Kustomi-moduulien kansiolle, ryhmälle suuremmat oikeudet, jotta sinne voidaan kirjoittaa sovelluksista.
sudo chmod 770 -R /opt/odoo/custom/addons


# kloonaa versio 18.0 haara kansioon /opt/odoo/odoo
sudo -u odoo git clone --depth 1 --branch 18.0 https://github.com/odoo/odoo /opt/odoo/odoo
## Odoo vaatii Python verion 3.10 tai uudemman
sudo dnf install -y python3.11 python3.11-devel
# Asentaa python virtuaaliympäristön
sudo -u odoo python3.11 -m venv /opt/odoo/venv
## Päivitää venv pip-ohjelman komponentteja
sudo -u odoo /opt/odoo/venv/bin/python -m pip install --upgrade pip wheel setuptools
## Luetaan ja asennetaan Odoo paketin riippuvuudet ja asennetaan ne VENV-ympäristöön.
sudo -u odoo /opt/odoo/venv/bin/pip install -r /opt/odoo/odoo/requirements.txt

sudo -u odoo /opt/odoo/venv/bin/pip install phonenumbers

#mene väliaikaishakemistoon /tmp
cd /tmp
# hae asennustiedot repositoriosta. tallenna se wk.rpm tiedostoon (tiedosto poistetaan uudellenkäynistyksessä)
wget "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox-0.12.6.1-3.almalinux9.x86_64.rpm" -O wk.rpm
## Asenna wkhtmltox-paketti
sudo dnf install -y ./wk.rpm
# Tarkista asennus ja että odoo käyttäjä pystyy ajamaan ohjelman
sudo -u odoo /usr/local/bin/wkhtmltopdf --version


# luo uusi kansio
sudo mkdir -p /etc/odoo
read -p "Enter Odoo admin password:" odoo_admin_pass
sudo cat > /etc/odoo/odoo.conf <<EOF  
[options]  
admin_passwd = $odoo_admin_pass 
db_host = False
db_port = False
db_user = odoo
db_password = $odoo_db_pass
addons_path = /opt/odoo/odoo/addons,/opt/odoo/custom/addons  
logfile = /var/log/odoo/odoo.log  
xmlrpc_port = 8069  
# Ensure wkhtmltopdf can fetch and load local assets:  
report.url = http://127.0.0.1:8069  
report.enable_local_file_access = True  
# When you put nginx/ALB in front, enable proxy_mode and set web.base.url to https://...  
# proxy_mode = True  
EOF

## Aseta odoo käyttäjälle omistus asetuksiin
sudo chown odoo:odoo /etc/odoo/odoo.conf
sudo chmod 640 /etc/odoo/odoo.conf


sudo tee /etc/systemd/system/odoo.service <<'EOF'
[Unit]
Description= Odoo ERP-system (python program)
After=network.target postgresql.service
[Service] 
Type=simple
User=odoo
Group=odoo
WorkingDirectory=/opt/odoo/odoo
Environment="PATH=/opt/odoo/venv/bin:/usr/local/bin:/usr/bin"
ExecStart=/opt/odoo/venv/bin/python /opt/odoo/odoo/odoo-bin -c /etc/odoo/odoo.conf
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

# Aseta rootille oikeudet uuteen tiedostoon
sudo chown root:root /etc/systemd/system/odoo.service
sudo chmod 644 /etc/systemd/system/odoo.service
# Uudellenlataa palveludaemonin asetukset, jotta uusi asetus ladataan muistiin.
sudo systemctl daemon-reload
# Aseta palvelu käynistymään automaattisesti ja käynistä se välittömästi.
sudo systemctl enable --now odoo
sudo systemctl status odoo


## Odoo-palvelu pitäisi kuunella porttia:
sudo ss -lntp | grep 8069
## Hakee etusivun
curl -v http://127.0.0.1:8069/


for issue in "${security_issues[@]}"; do
    echo "$issue"
done

