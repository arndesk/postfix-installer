#!/bin/bash

# Enhanced Postfix Installation Script with Multiple MTA Support
# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It allows configuring multiple MTAs with custom headers and provides options to manage them.

# Exit immediately if a command exits with a non-zero status
set -e

# Variables
MTA_CONFIG_FILE="/etc/postfix/mtas.conf"
TRANSPORT_MAP_FILE="/etc/postfix/transport_mta"
SENDER_TRANSPORT_FILE="/etc/postfix/sender_transport"
HEADER_CHECKS_FILE="/etc/postfix/header_checks"

# Install necessary tools
install_tools() {
    echo "Installing necessary tools..."
    sudo apt-get update
    sudo apt-get install -y dnsutils curl postfix sasl2-bin libsasl2-modules
}

# Function to get the server's public IP
get_public_ip() {
    echo "Retrieving public IP address..."
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [ -z "$PUBLIC_IP" ]; then
        echo "Could not retrieve public IP address."
        exit 1
    fi
    echo "Public IP: $PUBLIC_IP"
}

# Function to get reverse DNS of the public IP
get_rdns() {
    echo "Retrieving reverse DNS..."
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
    CURRENT_HEADER_SETTING=$(postconf -h header_checks 2>/dev/null || echo "disabled")
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
    while true; do
        read -p "Enter the username for SMTP authentication: " USERNAME
        if [ -n "$USERNAME" ]; then
            break
        else
            echo "Username cannot be empty. Please enter a valid username."
        fi
    done

    # Prompt for password with confirmation (Visible Input)
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
    echo "SMTP credentials set."
}

# Function to load MTAs from configuration
load_mtas() {
    if [ ! -f "$MTA_CONFIG_FILE" ]; then
        echo "MTA configuration file not found. Creating a new one..."
        touch "$MTA_CONFIG_FILE"
    fi

    MTAS=()
    declare -A MTA_IPS
    declare -A MTA_HOSTS

    CURRENT_MTA=""
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            CURRENT_MTA=${BASH_REMATCH[1]}
            MTAS+=("$CURRENT_MTA")
        elif [[ $line =~ ^ip\ =\ (.*)$ ]]; then
            MTA_IPS["$CURRENT_MTA"]=${BASH_REMATCH[1]}
        elif [[ $line =~ ^host\ =\ (.*)$ ]]; then
            MTA_HOSTS["$CURRENT_MTA"]=${BASH_REMATCH[1]}
        fi
    done < "$MTA_CONFIG_FILE"
}

# Function to add or edit MTA configurations
manage_mtas() {
    echo "Managing MTAs..."
    load_mtas

    echo "Current MTAs:"
    if [ ${#MTAS[@]} -eq 0 ]; then
        echo "No MTAs configured yet."
    else
        for mta in "${MTAS[@]}"; do
            echo "[$mta]"
            echo "ip = ${MTA_IPS[$mta]}"
            echo "host = ${MTA_HOSTS[$mta]}"
            echo
        done
    fi

    while true; do
        echo "What would you like to do?"
        echo "1) Add a new MTA"
        echo "2) Edit an existing MTA"
        echo "3) Delete an MTA"
        echo "4) Return to main menu"

        read -p "Enter your choice [1-4]: " MTA_CHOICE
        case "$MTA_CHOICE" in
            1)
                add_mta
                ;;
            2)
                edit_mta
                ;;
            3)
                delete_mta
                ;;
            4)
                break
                ;;
            *)
                echo "Invalid option. Please choose between 1-4."
                ;;
        esac
    done
}

# Function to add a new MTA
add_mta() {
    echo "Adding a new MTA..."
    while true; do
        read -p "Enter MTA name (e.g., mta_name_11): " NEW_MTA
        if [[ ! " ${MTAS[@]} " =~ " ${NEW_MTA} " ]]; then
            if [[ $NEW_MTA =~ ^mta_name_[0-9]+$ ]]; then
                break
            else
                echo "Invalid MTA name format. It should be like 'mta_name_11'."
            fi
        else
            echo "MTA name already exists. Please choose a different name."
        fi
    done

    while true; do
        read -p "Enter IP for $NEW_MTA: " NEW_IP
        if [[ $NEW_IP =~ ^([0-9a-fA-F:]+)$ ]]; then
            break
        else
            echo "Invalid IPv6 address. Please enter a valid IPv6."
        fi
    done

    while true; do
        read -p "Enter host for $NEW_MTA: " NEW_HOST
        if [ -n "$NEW_HOST" ]; then
            break
        else
            echo "Host cannot be empty."
        fi
    done

    # Append to configuration file
    {
        echo "[$NEW_MTA]"
        echo "ip = $NEW_IP"
        echo "host = $NEW_HOST"
        echo
    } >> "$MTA_CONFIG_FILE"

    echo "MTA $NEW_MTA added successfully."
    load_mtas
}

# Function to edit an existing MTA
edit_mta() {
    if [ ${#MTAS[@]} -eq 0 ]; then
        echo "No MTAs to edit."
        return
    fi

    echo "Select the MTA you want to edit:"
    select SELECTED_MTA in "${MTAS[@]}" "Cancel"; do
        if [ "$REPLY" -le "${#MTAS[@]}" ] && [ "$REPLY" -ge 1 ]; then
            break
        elif [ "$SELECTED_MTA" = "Cancel" ]; then
            return
        else
            echo "Invalid selection."
        fi
    done

    echo "Editing $SELECTED_MTA..."

    # Prompt for new IP
    read -p "Enter new IP for $SELECTED_MTA [${MTA_IPS[$SELECTED_MTA]}]: " NEW_IP
    NEW_IP=${NEW_IP:-${MTA_IPS[$SELECTED_MTA]}}
    if [[ ! $NEW_IP =~ ^([0-9a-fA-F:]+)$ ]]; then
        echo "Invalid IPv6 address. Keeping the previous IP."
        NEW_IP=${MTA_IPS[$SELECTED_MTA]}
    fi

    # Prompt for new host
    read -p "Enter new host for $SELECTED_MTA [${MTA_HOSTS[$SELECTED_MTA]}]: " NEW_HOST
    NEW_HOST=${NEW_HOST:-${MTA_HOSTS[$SELECTED_MTA]}}
    if [ -z "$NEW_HOST" ]; then
        echo "Host cannot be empty. Keeping the previous host."
        NEW_HOST=${MTA_HOSTS[$SELECTED_MTA]}
    fi

    # Update the configuration file
    sudo cp "$MTA_CONFIG_FILE" "${MTA_CONFIG_FILE}.bak"
    awk -v mta="$SELECTED_MTA" -v ip="$NEW_IP" -v host="$NEW_HOST" '
    BEGIN {found=0}
    /^\[.*\]$/ {current=$0; gsub(/\[|\]/, "", current)}
    {
        if ($0 ~ /^\[.*\]$/) {
            if (current == mta) {found=1} else {found=0}
        }
        if (found && $1 == "ip") {
            print "ip = " ip
            next
        }
        if (found && $1 == "host") {
            print "host = " host
            next
        }
        print $0
    }
    ' "$MTA_CONFIG_FILE.bak" > "$MTA_CONFIG_FILE"
    rm "${MTA_CONFIG_FILE}.bak"

    echo "MTA $SELECTED_MTA updated successfully."
    load_mtas
}

# Function to delete an MTA
delete_mta() {
    if [ ${#MTAS[@]} -eq 0 ]; then
        echo "No MTAs to delete."
        return
    fi

    echo "Select the MTA you want to delete:"
    select SELECTED_MTA in "${MTAS[@]}" "Cancel"; do
        if [ "$REPLY" -le "${#MTAS[@]}" ] && [ "$REPLY" -ge 1 ]; then
            break
        elif [ "$SELECTED_MTA" = "Cancel" ]; then
            return
        else
            echo "Invalid selection."
        fi
    done

    echo "Are you sure you want to delete $SELECTED_MTA? This action cannot be undone."
    read -p "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
        sudo cp "$MTA_CONFIG_FILE" "${MTA_CONFIG_FILE}.bak"
        awk -v mta="$SELECTED_MTA" '
        BEGIN {skip=0}
        /^\[.*\]$/ {current=$0; gsub(/\[|\]/, "", current)}
        current == mta {skip=1; next}
        /^\[.*\]$/ {if (current == mta) {skip=1} else {skip=0}}
        { if (!skip) print }
        ' "$MTA_CONFIG_FILE.bak" > "$MTA_CONFIG_FILE"
        rm "${MTA_CONFIG_FILE}.bak"
        echo "MTA $SELECTED_MTA deleted successfully."
        load_mtas
    else
        echo "Deletion cancelled."
    fi
}

# Function to restart services
restart_services() {
    echo "Restarting services..."
    sudo systemctl enable saslauthd
    sudo systemctl enable postfix
    sudo systemctl restart saslauthd
    sudo systemctl restart postfix
    echo "Services restarted."
}

# Function to configure Postfix
configure_postfix() {
    echo "Configuring Postfix..."

    # Stop postfix service during configuration
    sudo service postfix stop

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

    # Configure Postfix to listen on port 587 (submission)
    # Remove any existing submission configurations to prevent duplication
    sudo sed -i '/^submission inet n.*smtpd$/,/^$/d' /etc/postfix/master.cf

    # Add the submission configuration
    sudo tee -a /etc/postfix/master.cf > /dev/null <<EOL
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
EOL

    # Ensure no milters are configured
    sudo postconf -e "smtpd_milters ="
    sudo postconf -e "non_smtpd_milters ="

    # Enable and configure Cyrus SASL
    sudo sed -i 's/^START=no/START=yes/' /etc/default/saslauthd
    sudo sed -i 's/^MECHANISMS=".*"/MECHANISMS="sasldb"/' /etc/default/saslauthd
    sudo sed -i 's|^OPTIONS="\(.*\)"|OPTIONS="\1 -m /var/spool/postfix/var/run/saslauthd"|' /etc/default/saslauthd

    sudo mkdir -p /var/spool/postfix/var/run/saslauthd
    sudo rm -rf /var/run/saslauthd
    sudo ln -s /var/spool/postfix/var/run/saslauthd /var/run/saslauthd

    sudo adduser postfix sasl

    # Create or update the user in sasldb2
    echo "$PASSWORD" | sudo saslpasswd2 -c "$USERNAME" -p
    sudo chown postfix:postfix /etc/sasldb2
    sudo chmod 660 /etc/sasldb2

    # Configure Received header removal if user opted in
    if [ "$REMOVE_HEADER" = "yes" ]; then
        echo "Setting up to remove 'Received' headers from outgoing emails..."
        sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
        echo "/^Received:/     IGNORE" | sudo tee "$HEADER_CHECKS_FILE"
    else
        # Ensure header_checks is not set if user chooses not to remove headers
        sudo postconf -e "header_checks ="
        sudo rm -f "$HEADER_CHECKS_FILE"
    fi

    # Configure transport maps for MTAs
    if [ -f "$MTA_CONFIG_FILE" ]; then
        echo "Configuring transport maps for MTAs..."
        > "$TRANSPORT_MAP_FILE" # Clear existing transport map

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ $line =~ ^\[(.*)\]$ ]]; then
                CURRENT_MTA=${BASH_REMATCH[1]}
            elif [[ $line =~ ^ip\ =\ (.*)$ ]]; then
                MTA_IP=${BASH_REMATCH[1]}
            elif [[ $line =~ ^host\ =\ (.*)$ ]]; then
                MTA_HOST=${BASH_REMATCH[1]}
                echo "$MTA_HOST smtp:[${MTA_IP}]" | sudo tee -a "$TRANSPORT_MAP_FILE" > /dev/null
            fi
        done < "$MTA_CONFIG_FILE"

        sudo postmap "$TRANSPORT_MAP_FILE"
        sudo postconf -e "transport_maps = hash:$TRANSPORT_MAP_FILE"
    else
        echo "No MTA configurations found."
    fi

    # Configure header_checks to handle X-MTA-Name if transport_maps are set
    if [ -f "$TRANSPORT_MAP_FILE" ]; then
        echo "Configuring header_checks for X-MTA-Name..."
        sudo tee "$HEADER_CHECKS_FILE" > /dev/null <<EOL
/^X-MTA-Name: (.+)/ FILTER smtp:[\1]
/^X-MTA-Name:/    IGNORE
EOL
        sudo postconf -e "header_checks = regexp:$HEADER_CHECKS_FILE"
    fi

    # Remove any existing X-MTA-Name headers from emails
    sudo postconf -e "always_add_missing_headers = yes"
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
    echo "Password: [HIDDEN]"
    echo
    echo "Use these credentials with your SMTP client (e.g., Nodemailer)."
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
        echo "4) Toggle 'Received' header removal (currently: $(postconf -h header_checks | grep -q "/etc/postfix/header_checks" && echo "enabled" || echo "disabled"))"
        echo "5) Manage MTAs"
        echo "6) Add sender-dependent transport"
        echo "7) Quit"

        read -p "Enter your choice [1-7]: " CHOICE
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
                if postconf -h header_checks | grep -q "/etc/postfix/header_checks"; then
                    HEADER_STATUS="enabled"
                else
                    HEADER_STATUS="disabled"
                fi
                echo "Current 'Received' header removal: $HEADER_STATUS"
                prompt_remove_header
                # Reconfigure header removal
                if [ "$REMOVE_HEADER" = "yes" ]; then
                    sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
                    echo "/^Received:/     IGNORE" | sudo tee "$HEADER_CHECKS_FILE"
                else
                    sudo postconf -e "header_checks ="
                    sudo rm -f "$HEADER_CHECKS_FILE"
                fi
                ;;
            5)
                manage_mtas
                configure_postfix
                ;;
            6)
                add_sender_transport
                ;;
            7)
                echo "Exiting..."
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

# Function to add sender-dependent transport
add_sender_transport() {
    echo "Adding sender-dependent transport..."
    read -p "Enter the sender email address: " SENDER_EMAIL
    echo "Available MTAs:"
    load_mtas
    select MTA in "${MTAS[@]}" "Cancel"; do
        if [[ " ${MTAS[@]} " =~ " ${MTA} " ]]; then
            break
        elif [ "$MTA" = "Cancel" ]; then
            echo "Operation cancelled."
            return
        else
            echo "Invalid selection."
        fi
    done
    MTA_IP=${MTA_IPS[$MTA]}
    echo "$SENDER_EMAIL smtp:[${MTA_IP}]" | sudo tee -a "$SENDER_TRANSPORT_FILE" > /dev/null
    sudo postmap "$SENDER_TRANSPORT_FILE"
    sudo postconf -e "sender_dependent_transport_maps = hash:$SENDER_TRANSPORT_FILE"
    echo "Sender-dependent transport added successfully."
}

# Main script execution
main() {
    check_postfix_installed

    if [ "$POSTFIX_INSTALLED" = "yes" ]; then
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

        # Initialize MTA configuration file if it doesn't exist
        if [ ! -f "$MTA_CONFIG_FILE" ]; then
            touch "$MTA_CONFIG_FILE"
        fi

        # Prompt user to input MTA configurations
        echo "Let's configure your MTAs."
        while true; do
            read -p "Do you want to add an MTA? (yes/no): " ADD_MTA
            ADD_MTA=${ADD_MTA,,} # Convert to lowercase
            if [ "$ADD_MTA" = "yes" ]; then
                manage_mtas
            elif [ "$ADD_MTA" = "no" ]; then
                break
            else
                echo "Please answer yes or no."
            fi
        done

        configure_postfix
        restart_services
        display_credentials
    fi
}

# Execute the main function
main
