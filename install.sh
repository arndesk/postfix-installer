#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It also sets up SMTP authentication for use with Nodemailer.

# Prompt for hostname
read -p "Enter the hostname (e.g., mail.example.com): " HOSTNAME

# Prompt for username
read -p "Enter the username for SMTP authentication: " USERNAME

# Prompt for password
read -sp "Enter the password for SMTP authentication: " PASSWORD
echo

# Update system packages
sudo apt-get update

# Install postfix and necessary packages
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix sasl2-bin libsasl2-modules

# Stop postfix service during configuration
sudo service postfix stop

# Configure postfix main.cf
sudo postconf -e "smtpd_banner = \$myhostname ESMTP"
sudo postconf -e "myhostname = $HOSTNAME"
sudo postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
sudo postconf -e "relayhost ="
sudo postconf -e "inet_interfaces = all"
sudo postconf -e "inet_protocols = all"
sudo postconf -e "smtpd_sasl_auth_enable = yes"
sudo postconf -e "smtpd_sasl_security_options = noanonymous"
sudo postconf -e "smtpd_sasl_local_domain = \$myhostname"
sudo postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, reject_unauth_destination"
sudo postconf -e "broken_sasl_auth_clients = yes"
sudo postconf -e "smtpd_tls_security_level = may"
sudo postconf -e "smtp_tls_security_level = may"
sudo postconf -e "smtp_tls_note_starttls_offer = yes"
sudo postconf -e "smtpd_tls_auth_only = no"
sudo postconf -e "smtpd_sasl_type = cyrus"
sudo postconf -e "smtpd_sasl_path = smtpd"

# Configure Postfix to listen on port 587
sudo sed -i '/^#submission inet n - n - - smtpd$/s/^#//' /etc/postfix/master.cf
sudo sed -i '/^submission.*smtpd$/a \  -o syslog_name=postfix/submission\n  -o smtpd_tls_security_level=encrypt\n  -o smtpd_sasl_auth_enable=yes\n  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject\n  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject\n  -o milter_macro_daemon_name=ORIGINATING' /etc/postfix/master.cf

# Enable and configure Cyrus SASL
sudo sed -i 's/^START=no/START=yes/' /etc/default/saslauthd
sudo sed -i 's/^MECHANISMS=".*"/MECHANISMS="sasldb"/' /etc/default/saslauthd
sudo sed -i 's|^OPTIONS="-c"|OPTIONS="-c -m /var/spool/postfix/var/run/saslauthd"|' /etc/default/saslauthd

sudo mkdir -p /var/spool/postfix/var/run/saslauthd
sudo rm -rf /var/run/saslauthd
sudo ln -s /var/spool/postfix/var/run/saslauthd /var/run/saslauthd

sudo adduser postfix sasl

# Create the user in sasldb2
echo "$PASSWORD" | sudo saslpasswd2 -c "$USERNAME" -p
sudo chown postfix:postfix /etc/sasldb2

# Restart services
sudo service saslauthd restart
sudo service postfix restart

# Open port 587 in firewall
sudo ufw allow 587

echo "Postfix has been installed and configured."
echo "You can now use the following SMTP details in Nodemailer:"
echo "Host: $HOSTNAME"
echo "Port: 587"
echo "Username: $USERNAME"
echo "Password: [The password you entered]"

echo "Note: Adding a custom header to bounced emails requires additional configuration."
echo "You may need to set up a content filter or use Postfix's bounce templates."
echo "Please refer to Postfix documentation for more details."

