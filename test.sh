#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It also sets up multiple MTAs and routes emails based on the "X-VMTA" header.

set -e

# Function to install necessary tools
install_tools() {
    sudo apt-get update
    sudo apt-get install -y dnsutils curl postfix sasl2-bin libsasl2-modules
}

# Function to get the server's public IP
get_public_ip() {
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [ -z "$PUBLIC_IP" ]; then
        echo "Could not retrieve public IP address."
        exit 1
    fi
    echo "Public IP: $PUBLIC_IP"
}

# Function to get reverse DNS of the public IP
get_rdns() {
    RDNS=$(dig -x "$PUBLIC_IP" +short | sed 's/\.$//')
    if [ -z "$RDNS" ]; then
        echo "Could not retrieve reverse DNS of the public IP."
        RDNS=""
    else
        echo "Reverse DNS: $RDNS"
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
    echo "Hostname set to: $HOSTNAME"
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
    done
    echo "SMTP address preference set to: $SMTP_PREF"
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
    echo "'Received' header removal set to: $REMOVE_HEADER"
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
    echo "SMTP credentials set for user: $USERNAME"
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
        echo "3) Edit SMTP address preference (current: $(postconf -h smtp_address_preference))"
        echo "4) Toggle 'Received' header removal (currently: $( [ "$(postconf -h header_checks)" = "regexp:/etc/postfix/header_checks" ] && echo "enabled" || echo "disabled" ))"
        echo "5) Configure MTAs for X-VMTA routing"
        echo "6) Quit"

        read -p "Enter your choice [1-6]: " CHOICE
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
                if [ "$(postconf -h header_checks)" = "regexp:/etc/postfix/header_checks" ]; then
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
                configure_mt_map
                ;;
            6)
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

# Function to configure MTAs for X-VMTA routing
configure_mt_map() {
    echo "Configuring MTAs for X-VMTA routing..."

    # Prompt for number of MTAs
    while true; do
        read -p "Enter the number of MTAs you want to configure: " NUM_MTAS
        if [[ "$NUM_MTAS" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            echo "Please enter a valid positive integer."
        fi
    done

    # Initialize MTA configurations
    declare -A MTA_NAMES
    declare -A MTA_IPS
    declare -A MTA_HOSTS

    for ((i=1; i<=NUM_MTAS; i++)); do
        echo "Configuring MTA #$i:"
        while true; do
            read -p "Enter MTA name (e.g., mta_name_$i): " mta_name
            if [[ "$mta_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                break
            else
                echo "Invalid MTA name. Use only letters, numbers, underscores, or hyphens."
            fi
        done
        read -p "Enter IP for $mta_name: " mta_ip
        read -p "Enter hostname for $mta_name: " mta_host
        MTA_NAMES["$mta_name"]="$mta_name"
        MTA_IPS["$mta_name"]="$mta_ip"
        MTA_HOSTS["$mta_name"]="$mta_host"
    done

    # Create transport map file
    TRANSPORT_FILE="/etc/postfix/transport_xvmta"
    sudo touch $TRANSPORT_FILE
    sudo chmod 644 $TRANSPORT_FILE
    sudo rm -f $TRANSPORT_FILE
    sudo touch $TRANSPORT_FILE
    sudo chmod 644 $TRANSPORT_FILE

    echo "Configuring transport maps for each MTA..."

    # Append transport entries based on X-VMTA header
    for mta in "${!MTA_NAMES[@]}"; do
        transport_name="xvmta_$mta"
        # Define the transport with the specific relayhost
        sudo postconf -e "transport_maps = hash:$TRANSPORT_FILE"

        # Append transport definitions in master.cf
        if ! grep -q "^$transport_name " /etc/postfix/master.cf; then
            sudo bash -c "cat >> /etc/postfix/master.cf" <<EOL

$transport_name unix -       -       n       -       -       smtp
  -o smtp_bind_address=${MTA_IPS[$mta]}
  -o smtp_helo_name=${MTA_HOSTS[$mta]}
  -o relayhost=${MTA_HOSTS[$mta]}
EOL
        fi

        # Add header_checks rule
        echo "/^X-VMTA:\s*$mta\$/ FILTER $transport_name:" | sudo tee -a $TRANSPORT_FILE > /dev/null
    done

    # Compile transport map
    sudo postmap $TRANSPORT_FILE

    # Configure header_checks to use the transport map
    sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks_xvmta"

    # Create header_checks_xvmta
    HEADER_CHECKS_XVMTA="/etc/postfix/header_checks_xvmta"
    sudo bash -c "cat > $HEADER_CHECKS_XVMTA" <<EOL
/^X-VMTA:\s*(.+)$/ FILTER \${1}:
EOL

    sudo postconf -e "transport_maps = hash:$TRANSPORT_FILE"
    echo "MTAs configured successfully."
}

# Function to prompt for and configure MTAs
prompt_and_configure_mt_map() {
    configure_mt_map
    echo "Restarting services to apply MTA configurations..."
    restart_services
}

# Main script execution

check_postfix_installed

if [ "$POSTFIX_INSTALLED" = "yes" ]; then
    echo "Postfix is already installed."
    display_menu
else
    # First-time installation
    install_tools
    get_public_ip
    get_rdns
    prompt_hostname
    prompt_smtp_pref
    prompt_remove_header
    prompt_smtp_credentials

    configure_postfix

    # Prompt to configure MTAs
    echo
    read -p "Do you want to configure MTAs for X-VMTA routing? (yes/no) [yes]: " CONFIGURE_MTA
    CONFIGURE_MTA=${CONFIGURE_MTA,,}
    CONFIGURE_MTA=${CONFIGURE_MTA:-yes}
    if [ "$CONFIGURE_MTA" = "yes" ]; then
        prompt_and_configure_mt_map
    fi

    restart_services
    display_credentials
fi
