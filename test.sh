#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It sets up multiple virtual MTAs with IPv6 addresses and hostnames.

# Install necessary tools
sudo apt-get install -y dnsutils curl

# Function to prompt for virtual MTA configuration
prompt_vmta_config() {
    echo "Enter the virtual MTA configurations in the following format:"
    echo "[mta_name]"
    echo "ip = IPv6_address"
    echo "host = hostname"
    echo "Enter an empty line when finished."

    VMTA_CONFIG=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        VMTA_CONFIG+="$line"$'\n'
    done

    # Save the configuration to a file
    echo "$VMTA_CONFIG" | sudo tee /etc/postfix/vmta_config
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
    read -p "Enter the username for SMTP authentication: " USERNAME

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
    sudo systemctl enable saslauthd
    sudo systemctl enable postfix
    sudo service saslauthd restart
    sudo service postfix restart
}

# Function to configure Postfix
configure_postfix() {
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix sasl2-bin libsasl2-modules

    sudo service postfix stop

    # Configure postfix main.cf
    sudo postconf -e "smtpd_banner = \$myhostname ESMTP"
    sudo postconf -e "mydestination = localhost"
    sudo postconf -e "relayhost ="
    sudo postconf -e "inet_interfaces = all"
    sudo postconf -e "inet_protocols = ipv6"
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

    # Configure virtual MTAs
    sudo postconf -e "sender_dependent_default_transport_maps = regexp:/etc/postfix/vmta_transport"
    sudo postconf -e "smtp_header_checks = regexp:/etc/postfix/vmta_header_checks"

    # Create vmta_transport file
    echo "/.+/ smtp:[127.0.0.1]:10001" | sudo tee /etc/postfix/vmta_transport

    # Create vmta_header_checks file
    echo '/^x-vmta:/i FILTER smtp:[127.0.0.1]:10001' | sudo tee /etc/postfix/vmta_header_checks

    # Configure Postfix to listen on port 587
    sudo sed -i '/^submission inet n.*smtpd$/,/^$/d' /etc/postfix/master.cf

    echo "submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject" | sudo tee -a /etc/postfix/master.cf

    # Add virtual MTA configurations to master.cf
    while IFS= read -r line; do
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            mta_name="${BASH_REMATCH[1]}"
            read -r ip_line
            read -r host_line
            ip=$(echo "$ip_line" | cut -d'=' -f2 | tr -d '[:space:]')
            host=$(echo "$host_line" | cut -d'=' -f2 | tr -d '[:space:]')

            echo "${mta_name} unix  -       -       n       -       -       smtp
    -o smtp_bind_address6=${ip}
    -o smtp_helo_name=${host}" | sudo tee -a /etc/postfix/master.cf
        fi
    done < /etc/postfix/vmta_config

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
        sudo postconf -e "header_checks ="
        sudo rm -f /etc/postfix/header_checks
    fi
}

# Function to display SMTP credentials
display_credentials() {
    echo
    echo "Postfix has been installed and configured with virtual MTAs."
    echo
    echo "SMTP Credentials:"
    echo "Port: 587"
    echo "Username: $USERNAME"
    echo "Password: $PASSWORD"
    echo
    echo "Virtual MTA Configuration:"
    cat /etc/postfix/vmta_config
    echo
    echo "To use a specific virtual MTA, include the 'x-vmta' header in your email."
    echo "Example: x-vmta: mta_name_1"
    echo
    echo "You can now use these SMTP details in your email sending application."
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
        echo "1) Edit virtual MTA configuration"
        echo "2) Add or edit SMTP users"
        CURRENT_HEADER_SETTING=$(postconf -h header_checks 2>/dev/null)
        if [ "$CURRENT_HEADER_SETTING" = "regexp:/etc/postfix/header_checks" ]; then
            HEADER_STATUS="enabled"
        else
            HEADER_STATUS="disabled"
        fi
        echo "3) Toggle 'Received' header removal (currently: ${HEADER_STATUS})"
        echo "4) Quit"

        read -p "Enter your choice [1-4]: " CHOICE
        case "$CHOICE" in
            1)
                prompt_vmta_config
                configure_postfix
                ;;
            2)
                prompt_smtp_credentials
                echo "$PASSWORD" | sudo saslpasswd2 -c "$USERNAME" -p
                sudo chown postfix:postfix /etc/sasldb2
                sudo chmod 660 /etc/sasldb2
                ;;
            3)
                if [ "$HEADER_STATUS" = "enabled" ]; then
                    REMOVE_HEADER="no"
                else
                    REMOVE_HEADER="yes"
                fi
                prompt_remove_header
                if [ "$REMOVE_HEADER" = "yes" ]; then
                    sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
                    echo "/^Received:/     IGNORE" | sudo tee /etc/postfix/header_checks
                else
                    sudo postconf -e "header_checks ="
                    sudo rm -f /etc/postfix/header_checks
                fi
                ;;
            4)
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

check_postfix_installed

if [ "$POSTFIX_INSTALLED" = "yes" ]; then
    display_menu
else
    prompt_vmta_config
    prompt_remove_header
    prompt_smtp_credentials

    configure_postfix

    restart_services
    display_credentials
fi
