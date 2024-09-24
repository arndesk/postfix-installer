#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It sets up SMTP authentication for use with Nodemailer.

# Install necessary tools
sudo apt-get install -y dnsutils curl

# Function to get the server's public IP
get_public_ip() {
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [ -z "$PUBLIC_IP" ]; then
        echo "Could not retrieve public IP address."
        exit 1
    fi
}

# Function to get reverse DNS of the public IP
get_rdns() {
    RDNS=$(dig -x "$PUBLIC_IP" +short | sed 's/\.$//')
    if [ -z "$RDNS" ]; then
        echo "Could not retrieve reverse DNS of the public IP."
        exit 1
    fi
}

# Get public IP and reverse DNS
get_public_ip
get_rdns

# Prompt for hostname with auto-fill from RDNS and allow editing
while true; do
    read -e -p "Enter the hostname [${RDNS}]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$RDNS}
    if [ "$HOSTNAME" = "$RDNS" ]; then
        break
    else
        echo "The entered hostname does not match the reverse DNS of the server's public IP ($RDNS). Please enter a hostname that matches the reverse DNS."
    fi
done

# Prompt for SMTP address preference
while true; do
    read -p "Set smtp_address_preference (ipv6, ipv4, any) [ipv4]: " SMTP_PREF
    SMTP_PREF=${SMTP_PREF:-any}
    case "$SMTP_PREF" in
        ipv6|ipv4|any)
            break
            ;;
        *)
            echo "Invalid option. Please enter 'ipv6', 'ipv4', or 'any'."
            ;;
    esac
done

# Prompt for removing Received header
while true; do
    read -p "Do you want to remove the 'Received' header from outgoing emails? (yes/no) [no]: " REMOVE_HEADER
    REMOVE_HEADER=${REMOVE_HEADER,,} # Convert to lowercase
    REMOVE_HEADER=${REMOVE_HEADER:-no}
    case "$REMOVE_HEADER" in
        yes|no)
            break
            ;;
        *)
            echo "Please answer yes or no."
            ;;
    esac
done

# Prompt for username
read -p "Enter the username for SMTP authentication: " USERNAME

# Prompt for password with confirmation (Visible Input)
while true; do
    # Removed the '-s' option to make password input visible
    read -p "Enter the password for SMTP authentication: " PASSWORD1
    echo
    read -p "Confirm the password: " PASSWORD2
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
sudo postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
sudo postconf -e "broken_sasl_auth_clients = yes"
sudo postconf -e "smtpd_tls_security_level = may"
sudo postconf -e "smtp_tls_security_level = may"
sudo postconf -e "smtp_tls_note_starttls_offer = yes"
sudo postconf -e "smtpd_tls_auth_only = no"
sudo postconf -e "smtpd_sasl_type = cyrus"
sudo postconf -e "smtpd_sasl_path = smtpd"

# Set smtp_address_preference
sudo postconf -e "smtp_address_preference = $SMTP_PREF"

# Configure Postfix to listen on port 587
# Remove any existing submission configurations to prevent duplication
sudo sed -i '/^submission inet n.*smtpd$/,/^$/d' /etc/postfix/master.cf

# Add the submission configuration
echo "submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING" | sudo tee -a /etc/postfix/master.cf

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
sudo chmod 660 /etc/sasldb2

# Configure Received header removal if user opted in
if [ "$REMOVE_HEADER" = "yes" ]; then
    echo "Setting up to remove 'Received' headers from outgoing emails..."
    sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
    echo "/^Received:/     IGNORE" | sudo tee /etc/postfix/header_checks
else
    # Ensure header_checks is not set if user chooses not to remove headers
    sudo postconf -e "header_checks ="
    sudo rm -f /etc/postfix/header_checks
fi

# Enable services to start on boot
sudo systemctl enable saslauthd
sudo systemctl enable postfix

# Restart services
sudo service saslauthd restart
sudo service postfix restart

# Display the SMTP credentials
echo
echo "Postfix has been installed and configured."
echo
echo "SMTP Credentials:"
echo "Host: $HOSTNAME"
echo "Port: 587"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo
echo "You can now use these SMTP details in Nodemailer."
