#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It sets up SMTP authentication for use with Nodemailer and integrates amavisd-new for spam and virus filtering.

# Exit immediately if a command exits with a non-zero status
set -e

# Install necessary tools
sudo apt-get update
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
}

# Get public IP and reverse DNS
get_public_ip
get_rdns

# Prompt for hostname
if [ -n "$RDNS" ]; then
    # If RDNS is found, use it as the default and enforce matching if the user chooses to use the default
    while true; do
        read -e -p "Enter the hostname [${RDNS}]: " HOSTNAME
        HOSTNAME=${HOSTNAME:-$RDNS}
        if [ "$HOSTNAME" = "$RDNS" ]; then
            break
        else
            # Optional: Allow the user to proceed with a different hostname
            read -p "The entered hostname does not match the reverse DNS of the server's public IP ($RDNS). Do you want to proceed with this hostname? (yes/no) [no]: " PROCEED
            PROCEED=${PROCEED,,} # Convert to lowercase
            PROCEED=${PROCEED:-no}
            case "$PROCEED" in
                yes)
                    break
                    ;;
                no)
                    echo "Please enter a hostname that matches the reverse DNS or choose to proceed without matching."
                    ;;
                *)
                    echo "Please answer yes or no."
                    ;;
            esac
        fi
    done
else
    # If RDNS is not found, prompt the user to input the hostname manually without any default
    while true; do
        read -p "Reverse DNS not found. Please enter the hostname manually: " HOSTNAME
        if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            break
        else
            echo "Invalid hostname format. Please enter a valid fully qualified domain name (e.g., mail.yourdomain.com)."
        fi
    done
fi

# Prompt for SMTP address preference
while true; do
    read -p "Set smtp_address_preference (ipv6, ipv4, any) [ipv4]: " SMTP_PREF
    SMTP_PREF=${SMTP_PREF:-ipv4}
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

# Prompt for password with confirmation (Hidden Input for Security)
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

# Install Postfix and necessary packages
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix sasl2-bin libsasl2-modules

# Stop postfix service during configuration
sudo systemctl stop postfix

# Configure postfix main.cf
sudo postconf -e "smtpd_banner = \$myhostname ESMTP"
sudo postconf -e "myhostname = $HOSTNAME"
sudo postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
sudo postconf -e "relayhost ="
sudo postconf -e "inet_interfaces = all"
sudo postconf -e "inet_protocols = $SMTP_PREF"
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
sudo systemctl restart saslauthd
sudo systemctl restart postfix

# Configure UFW Firewall (Optional but recommended)
# Allow SMTP ports
sudo ufw allow 25/tcp
sudo ufw allow 587/tcp
sudo ufw allow 465/tcp
sudo ufw reload

# ============================================
# Begin amavisd-new Integration
# ============================================

echo
echo "Starting amavisd-new installation and configuration..."

# Install amavisd-new and dependencies
sudo apt-get install -y amavisd-new spamassassin clamav clamav-daemon

# Enable and start ClamAV
sudo systemctl enable clamav-daemon
sudo systemctl start clamav-daemon

# Update ClamAV database
sudo freshclam

# Enable and configure SpamAssassin
sudo systemctl enable spamassassin
sudo systemctl start spamassassin
sudo sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/spamassassin
sudo sed -i 's/^OPTIONS=.*/OPTIONS="--create-prefs --max-children 5 --helper-home-dir --username spamd"/' /etc/default/spamassassin

# Configure amavisd-new
sudo postconf -e "content_filter = smtp-amavis:[127.0.0.1]:10024"

# Backup existing amavisd.conf if it exists
if [ -f /etc/amavis/conf.d/50-user ]; then
    sudo cp /etc/amavis/conf.d/50-user /etc/amavis/conf.d/50-user.bak
fi

# Configure amavisd-new settings
sudo tee /etc/amavis/conf.d/50-user > /dev/null <<EOL
# Content scanning
use strict;
use warnings;

@bypass_virus_checks_maps = (
    \%bypass_virus_checks, \@bypass_virus_checks_acl, \@bypass_virus_checks_re);

@bypass_spam_checks_maps = (
    \%bypass_spam_checks, \@bypass_spam_checks_acl, \@bypass_spam_checks_re);

$sa_tag_level_deflt  = -999;  # avoid spamassassin marking
$sa_tag2_level_deflt = 5;     # add header "Spam: Yes" if at or above this level
$sa_kill_level_deflt = 10;    # trigger spam evasions (quarantine, etc.)

$virus_quarantine_to = 'virus-quarantine@yourdomain.com'; # Change as needed
$sa_quarantine_to    = 'spam-quarantine@yourdomain.com';  # Change as needed

# Enable virus scanning
@av_scanners = (
    ['ClamAV-clamscan', \&ask_daemon, ["CONTSCAN {}\n", "/var/run/clamav/clamd.ctl"], qr/\bOK$/, qr/\bFOUND$/]
);

# Enable spam scanning
$enable_dcc     = 0;
$enable_bayes   = 1;
$bayes_auto_learn = 1;

EOL

# Replace 'yourdomain.com' with actual domain
sudo sed -i "s/yourdomain\.com/$HOSTNAME/g" /etc/amavis/conf.d/50-user

# Integrate amavisd-new with Postfix via master.cf
# Add amavis service
echo "127.0.0.1:10024 inet n  -       n       -       -       smtp
    -o content_filter=
    -o receive_override_options=no_header_body_checks,no_unknown_recipient_checks
    -o smtpd_helo_restrictions=
    -o smtpd_client_restrictions=
    -o smtpd_sender_restrictions=
    -o smtpd_recipient_restrictions=permit_mynetworks, permit_sasl_authenticated, reject
    -o smtpd_bind_address=127.0.0.1
    -o smtpd_tls_security_level=none
    -o smtpd_sasl_auth_enable=no
    -o smtpd_relay_restrictions=permit_mynetworks, permit_sasl_authenticated, reject
    -o mynetworks=127.0.0.0/8" | sudo tee -a /etc/postfix/master.cf

echo "127.0.0.1:10025 inet n  -       n       -       -       smtpd
    -o content_filter=
    -o receive_override_options=no_header_body_checks
    -o smtpd_helo_restrictions=
    -o smtpd_client_restrictions=
    -o smtpd_sender_restrictions=
    -o smtpd_recipient_restrictions=permit_mynetworks, permit_sasl_authenticated, reject
    -o smtpd_bind_address=127.0.0.1
    -o smtpd_tls_security_level=none
    -o smtpd_sasl_auth_enable=no
    -o mynetworks=127.0.0.0/8" | sudo tee -a /etc/postfix/master.cf

# Restart Postfix and amavisd-new
sudo systemctl restart amavis
sudo systemctl restart postfix

# Add amavis user to postfix group
sudo usermod -aG postfix amavis

# Configure SpamAssassin to work with amavisd-new
sudo sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/spamassassin
sudo systemctl restart spamassassin

# Configure mail flow
sudo postconf -e "receive_override_options = no_address_mappings"

# Reload Postfix to apply all changes
sudo systemctl reload postfix

# ============================================
# End amavisd-new Integration
# ============================================

# Display the SMTP credentials
echo
echo "Postfix and amavisd-new have been installed and configured."
echo
echo "SMTP Credentials:"
echo "Host: $HOSTNAME"
echo "Port: 587"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo
echo "You can now use these SMTP details in Nodemailer."
echo
echo "Note: Ensure that your DNS records (MX, SPF, DKIM, DMARC) are properly configured to enhance deliverability."
