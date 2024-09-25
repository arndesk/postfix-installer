#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It sets up SMTP authentication for use with Nodemailer.
# If the script is run multiple times, it provides options to edit configurations.

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
        RDNS=""
    fi
}

# Function to prompt for hostname
prompt_hostname() {
    if [ -z "$RDNS" ]; then
        echo "Reverse DNS not found. Please enter the hostname."
        while true; do
            read -p "Enter the hostname: " HOSTNAME
            if [ -n "$HOSTNAME" ]; then
                break
            else
                echo "Hostname cannot be empty. Please enter a valid hostname."
            fi
        done
    else
        # Prompt for hostname with auto-fill from RDNS and allow editing
        read -e -p "Enter the hostname [${RDNS}]: " HOSTNAME
        HOSTNAME=${HOSTNAME:-$RDNS}
    fi
}

# Function to prompt for SMTP address preference
prompt_smtp_pref() {
    CURRENT_SMTP_PREF=$(postconf -h smtp_address_preference 2>/dev/null || echo "ipv4")
    while true; do
        read -p "Set smtp_address_preference (ipv6, ipv4, any) [${CURRENT_SMTP_PREF}]: " SMTP_PREF
        SMTP_PREF=${SMTP_PREF:-$CURRENT_SMTP_PREF}
        case "$SMTP_PREF" in
            ipv6|ipv4|any)
                break
                ;;
            *)
                echo "Invalid option. Please enter 'ipv6', 'ipv4', or 'any'."
                ;;
        esac
    fi
}

# Function to prompt for removing Received header
prompt_remove_header() {
    CURRENT_HEADER_SETTING=$(postconf -h header_checks 2>/dev/null)
    if [ "$CURRENT_HEADER_SETTING" = "regexp:/etc/postfix/header_checks" ]; then
        CURRENT_REMOVE_HEADER="yes"
    else
        CURRENT_REMOVE_HEADER="no"
    fi
    while true; do
        read -p "Do you want to remove the 'Received' header from outgoing emails? (yes/no) [${CURRENT_REMOVE_HEADER}]: " REMOVE_HEADER
        REMOVE_HEADER=${REMOVE_HEADER,,} # Convert to lowercase
        REMOVE_HEADER=${REMOVE_HEADER:-$CURRENT_REMOVE_HEADER}
        case "$REMOVE_HEADER" in
            yes|no)
                break
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

# Function to prompt for SMTP authentication credentials
prompt_smtp_credentials() {
    # Prompt for username
    read -p "Enter the username for SMTP authentication: " USERNAME

    # Prompt for password with confirmation (Visible Input)
    while true; do
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
}

# Function to restart services
restart_services() {
    # Enable services to start on boot
    sudo systemctl enable saslauthd
    sudo systemctl enable postfix

    # Restart services
    sudo service saslauthd restart
    sudo service postfix restart
}

# Function to configure Postfix
configure_postfix() {
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
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject" | sudo tee -a /etc/postfix/master.cf

    # Ensure no milters are configured
    sudo postconf -e "smtpd_milters ="
    sudo postconf -e "non_smtpd_milters ="

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
}

# Function to display SMTP credentials
display_credentials() {
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
}

# Function to check if Postfix is already installed
check_postfix_installed() {
    dpkg -s postfix &> /dev/null
    if [ $? -eq 0 ]; then
        POSTFIX_INSTALLED="yes"
    else
        POSTFIX_INSTALLED="no"
    fi
}

# Function to display menu if Postfix is already installed
display_menu() {
    while true; do
        echo
        echo "Postfix is already installed. What would you like to do?"
        echo "1) Edit hostname (current: $(postconf -h myhostname))"
        echo "2) Add or edit SMTP users"
        CURRENT_SMTP_PREF=$(postconf -h smtp_address_preference)
        echo "3) Edit SMTP address preference (current: ${CURRENT_SMTP_PREF})"
        CURRENT_HEADER_SETTING=$(postconf -h header_checks 2>/dev/null)
        if [ "$CURRENT_HEADER_SETTING" = "regexp:/etc/postfix/header_checks" ]; then
            HEADER_STATUS="enabled"
        else
            HEADER_STATUS="disabled"
        fi
        echo "4) Toggle 'Received' header removal (currently: ${HEADER_STATUS})"
        echo "5) Quit"

        read -p "Enter your choice [1-5]: " CHOICE
        case "$CHOICE" in
            1)
                prompt_hostname
                sudo postconf -e "myhostname = $HOSTNAME"
                ;;
            2)
                prompt_smtp_credentials
                # Create or update the user in sasldb2
                echo "$PASSWORD" | sudo saslpasswd2 -c "$USERNAME" -p
                sudo chown postfix:postfix /etc/sasldb2
                sudo chmod 660 /etc/sasldb2
                ;;
            3)
                prompt_smtp_pref
                sudo postconf -e "smtp_address_preference = $SMTP_PREF"
                ;;
            4)
                if [ "$HEADER_STATUS" = "enabled" ]; then
                    REMOVE_HEADER="no"
                else
                    REMOVE_HEADER="yes"
                fi
                prompt_remove_header
                # Reconfigure header removal
                if [ "$REMOVE_HEADER" = "yes" ]; then
                    sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
                    echo "/^Received:/     IGNORE" | sudo tee /etc/postfix/header_checks
                else
                    sudo postconf -e "header_checks ="
                    sudo rm -f /etc/postfix/header_checks
                fi
                ;;
            5)
                exit 0
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
        echo "Configuration updated. Restarting services..."
        restart_services
    done
}

# Main script execution

get_public_ip
get_rdns

check_postfix_installed

if [ "$POSTFIX_INSTALLED" = "yes" ]; then
    display_menu
else
    # First-time installation
    prompt_hostname
    prompt_smtp_pref
    prompt_remove_header
    prompt_smtp_credentials

    configure_postfix

    restart_services
    display_credentials
fi
