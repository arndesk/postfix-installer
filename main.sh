#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It sets up SMTP authentication for use with Nodemailer and integrates Amavisd-new for spam and virus filtering.

set -e

# Function to display messages in color
function echo_info {
    echo -e "\\033[1;34m[INFO]\\033[0m $1"
}

function echo_error {
    echo -e "\\033[1;31m[ERROR]\\033[0m $1" >&2
}

# Install necessary tools
echo_info "Installing necessary tools..."
sudo apt-get update
sudo apt-get install -y dnsutils curl

# Function to get the server's public IP
get_public_ip() {
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [ -z "$PUBLIC_IP" ]; then
        echo_error "Could not retrieve public IP address."
        exit 1
    fi
    echo_info "Public IP Address: $PUBLIC_IP"
}

# Function to get reverse DNS of the public IP
get_rdns() {
    RDNS=$(dig -x "$PUBLIC_IP" +short | sed 's/\.$//')
    if [ -z "$RDNS" ]; then
        echo_error "Could not retrieve reverse DNS of the public IP."
        RDNS_FOUND=false
    else
        echo_info "Reverse DNS (RDNS): $RDNS"
        RDNS_FOUND=true
    fi
}

# Get public IP and reverse DNS
get_public_ip
get_rdns

# Prompt for hostname
if [ "$RDNS_FOUND" = true ]; then
    while true; do
        read -p "Enter the hostname (e.g., $RDNS): " HOSTNAME
        if [ "$HOSTNAME" = "$RDNS" ]; then
            break
        else
            echo_error "The entered hostname does not match the reverse DNS of the server's public IP ($RDNS)."
            read -p "Do you want to continue with a different hostname? (y/n): " yn
            case $yn in
                [Yy]* ) break;;
                [Nn]* ) echo_error "Hostname must match RDNS. Exiting."; exit 1;;
                * ) echo "Please answer yes or no.";;
            esac
        fi
    done
else
    while true; do
        read -p "Enter the hostname for the SMTP server: " HOSTNAME
        if [ -n "$HOSTNAME" ]; then
            break
        else
            echo_error "Hostname cannot be empty. Please enter a valid hostname."
        fi
    done
fi

# Prompt for username
while true; do
    read -p "Enter the username for SMTP authentication: " USERNAME
    if [[ "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        break
    else
        echo_error "Username contains invalid characters. Please use only letters, numbers, dots, underscores, or hyphens."
    fi
done

# Prompt for password with confirmation
while true; do
    read -s -p "Enter the password for SMTP authentication: " PASSWORD1
    echo
    read -s -p "Confirm the password: " PASSWORD2
    echo
    if [ "$PASSWORD1" = "$PASSWORD2" ]; then
        if [ -n "$PASSWORD1" ]; then
            PASSWORD="$PASSWORD1"
            break
        else
            echo_error "Password cannot be empty. Please try again."
        fi
    else
        echo_error "Passwords do not match. Please try again."
    fi
done

# Update system packages
echo_info "Updating system packages..."
sudo apt-get update

# Install Postfix and necessary packages
echo_info "Installing Postfix and related packages..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix sasl2-bin libsasl2-modules

# Install Amavisd-new and its dependencies
echo_info "Installing Amavisd-new and related packages..."
sudo apt-get install -y amavisd-new spamassassin clamav clamav-daemon

# Stop Postfix service during configuration
echo_info "Stopping Postfix service for configuration..."
sudo systemctl stop postfix

# Configure Postfix main.cf
echo_info "Configuring Postfix..."
sudo postconf -e "smtpd_banner = \$myhostname ESMTP"
sudo postconf -e "myhostname = $HOSTNAME"
sudo postconf -e "mydomain = $(echo $HOSTNAME | awk -F. '{print $(NF-1)"."$NF}')"
sudo postconf -e "myorigin = /etc/mailname"
sudo postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
sudo postconf -e "relayhost ="
sudo postconf -e "inet_interfaces = all"
sudo postconf -e "inet_protocols = all"
sudo postconf -e "smtpd_sasl_auth_enable = yes"
sudo postconf -e "smtpd_sasl_security_options = noanonymous"
sudo postconf -e "smtpd_sasl_local_domain = \$myhostname"
sudo postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
sudo postconf -e "broken_sasl_auth_clients = yes"
sudo postconf -e "smtpd_tls_security_level = may"
sudo postconf -e "smtp_tls_security_level = may"
sudo postconf -e "smtp_tls_note_starttls_offer = yes"
sudo postconf -e "smtpd_tls_auth_only = no"
sudo postconf -e "smtpd_sasl_type = cyrus"
sudo postconf -e "smtpd_sasl_path = smtpd"
sudo postconf -e "content_filter = amavis:[127.0.0.1]:10024"

# Configure Postfix to listen on port 587
echo_info "Configuring Postfix to listen on port 587..."
# Remove existing submission configurations to prevent duplication
sudo sed -i '/^submission inet n.*smtpd$/,/^$/d' /etc/postfix/master.cf

# Add the submission configuration
sudo tee -a /etc/postfix/master.cf > /dev/null <<EOL
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOL

# Enable and configure Cyrus SASL
echo_info "Configuring Cyrus SASL..."
sudo sed -i 's/^START=no/START=yes/' /etc/default/saslauthd
sudo sed -i 's/^MECHANISMS=".*"/MECHANISMS="sasldb"/' /etc/default/saslauthd
sudo sed -i 's|^OPTIONS="\(.*\)"|OPTIONS="\1 -m /var/spool/postfix/var/run/saslauthd"|' /etc/default/saslauthd

# Setup SASL authentication directories
echo_info "Setting up SASL authentication directories..."
sudo mkdir -p /var/spool/postfix/var/run/saslauthd
sudo rm -rf /var/run/saslauthd
sudo ln -s /var/spool/postfix/var/run/saslauthd /var/run/saslauthd
sudo chown -R sasl:sasld /var/spool/postfix/var/run/saslauthd

# Add Postfix user to the SASL group
sudo adduser postfix sasl || true

# Create the user in sasldb2
echo_info "Creating SMTP authentication user..."
echo "$PASSWORD" | sudo saslpasswd2 -c "$USERNAME" -p
sudo chown postfix:postfix /etc/sasldb2
sudo chmod 660 /etc/sasldb2

# Enable services to start on boot
echo_info "Enabling services to start on boot..."
sudo systemctl enable saslauthd
sudo systemctl enable postfix
sudo systemctl enable amavis
sudo systemctl enable clamav-daemon
sudo systemctl enable spamassassin

# Configure Amavisd-new
echo_info "Configuring Amavisd-new..."
sudo postconf -e "content_filter = amavis:[127.0.0.1]:10024"
sudo postconf -e "receive_override_options = no_address_mappings"

# Allow Postfix to communicate with Amavis
sudo sed -i 's/^@bypass_virus_checks_maps.*/@bypass_virus_checks_maps = (1);\n@bypass_spam_checks_maps = (1);/' /etc/amavis/conf.d/15-content_filter_mode

# Restart and start services
echo_info "Restarting and starting services..."
sudo systemctl restart saslauthd
sudo systemctl restart postfix
sudo systemctl restart amavis
sudo systemctl restart clamav-daemon
sudo systemctl restart spamassassin

# Display the SMTP credentials
echo
echo -e "\\033[1;32mPostfix has been installed and configured successfully!\\033[0m"
echo
echo "SMTP Credentials:"
echo "Host: $HOSTNAME"
echo "Port: 587"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo
echo "You can now use these SMTP details in Nodemailer."
echo
echo "Additionally, Amavisd-new has been installed and configured for spam and virus filtering."

# End of script
