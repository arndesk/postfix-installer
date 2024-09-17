#!/bin/bash

# This script installs and configures Exim as an SMTP server with authentication on port 587.
# It sets up SMTP authentication for use with Nodemailer.

# Prompt for hostname
read -p "Enter the hostname (e.g., mail.example.com): " HOSTNAME

# Prompt for domain name
read -p "Enter the domain name (e.g., example.com): " DOMAIN

# Prompt for username
read -p "Enter the username for SMTP authentication: " USERNAME

# Prompt for password with confirmation
while true; do
    read -s -p "Enter the password for SMTP authentication: " PASSWORD1
    echo
    read -s -p "Confirm the password: " PASSWORD2
    echo
    if [ "$PASSWORD1" = "$PASSWORD2" ]; then
        PASSWORD="$PASSWORD1"
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

# Update system packages
sudo apt-get update

# Install Exim4 and necessary packages
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y exim4

# Stop Exim service during configuration
sudo service exim4 stop

# Set the hostname
sudo hostnamectl set-hostname $HOSTNAME

# Configure Exim
sudo cp /etc/exim4/update-exim4.conf.conf /etc/exim4/update-exim4.conf.conf.backup

sudo sed -i "s/dc_eximconfig_configtype='.*'/dc_eximconfig_configtype='internet'/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_other_hostnames='.*'/dc_other_hostnames='$HOSTNAME'/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_local_interfaces='.*'/dc_local_interfaces='0.0.0.0 ; ::0'/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_readhost='.*'/dc_readhost=''/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_relay_domains='.*'/dc_relay_domains=''/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_minimaldns='.*'/dc_minimaldns='false'/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_relay_nets='.*'/dc_relay_nets=''/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/dc_smarthost='.*'/dc_smarthost=''/g" /etc/exim4/update-exim4.conf.conf
sudo sed -i "s/CFILEMODE='.*'/CFILEMODE='644'/g" /etc/exim4/update-exim4.conf.conf

# Enable TLS
sudo mkdir /etc/exim4/ssl
sudo openssl req -new -x509 -days 3650 -nodes -out /etc/exim4/ssl/exim.crt -keyout /etc/exim4/ssl/exim.key -subj "/CN=$HOSTNAME"
sudo chmod 600 /etc/exim4/ssl/exim.key
sudo chown root:Debian-exim /etc/exim4/ssl/exim.key

# Create Exim password file
echo "${USERNAME}:${PASSWORD}" | sudo tee /etc/exim4/passwd

# Set permissions for the password file
sudo chown root:Debian-exim /etc/exim4/passwd
sudo chmod 640 /etc/exim4/passwd

# Configure Exim authentication
sudo bash -c 'cat > /etc/exim4/conf.d/auth/00_exim4-config-auth' <<EOF
plain_login:
  driver = plaintext
  public_name = LOGIN
  server_prompts = "Username:: : Password::"
  server_condition = "${if crypteq{$auth2}{${lookup{$auth1}lsearch{/etc/exim4/passwd}{$value}{*}}}{yes}{no}}"
  server_set_id = $auth1
EOF

# Configure Exim to listen on port 587
sudo sed -i '/daemon_smtp_ports = /d' /etc/exim4/exim4.conf.template
echo "daemon_smtp_ports = 25 : 587" | sudo tee -a /etc/exim4/exim4.conf.template

# Enable TLS in Exim
sudo bash -c 'cat > /etc/exim4/conf.d/main/03_exim4-config_tlsoptions' <<EOF
tls_certificate = /etc/exim4/ssl/exim.crt
tls_privatekey = /etc/exim4/ssl/exim.key
EOF

# Update Exim configuration
sudo update-exim4.conf

# Start Exim service
sudo service exim4 restart

# Display the SMTP credentials
echo
echo "Exim has been installed and configured."
echo
echo "SMTP Credentials:"
echo "Host: $HOSTNAME"
echo "Port: 587"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo
echo "You can now use these SMTP details in Nodemailer."
