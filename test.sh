#!/bin/bash

# This script installs and configures Exim4 as an SMTP server with authentication on port 587.
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
    CURRENT_SMTP_PREF=$(grep "^dc_ip_version" /etc/exim4/update-exim4.conf.conf 2>/dev/null | cut -d'"' -f2 || echo "ipv4")
    while true; do
        read -p "Set SMTP address preference (ipv6, ipv4, all) [${CURRENT_SMTP_PREF}]: " SMTP_PREF
        SMTP_PREF=${SMTP_PREF:-$CURRENT_SMTP_PREF}
        case "$SMTP_PREF" in
            ipv6|ipv4|all)
                break
                ;;
            *)
                echo "Invalid option. Please enter 'ipv6', 'ipv4', or 'all'."
                ;;
        esac
    done
}

# Function to prompt for removing Received header
prompt_remove_header() {
    CURRENT_REMOVE_HEADER=$(grep "received_header_text" /etc/exim4/exim4.conf.localmacros 2>/dev/null)
    if [ -n "$CURRENT_REMOVE_HEADER" ]; then
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
    # Restart services
    sudo service exim4 restart
}

# Function to configure Exim4
configure_exim4() {
    # Update system packages
    sudo apt-get update

    # Install Exim4 and necessary packages
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y exim4

    # Stop Exim4 service during configuration
    sudo service exim4 stop

    # Configure Exim4
    sudo cp /etc/exim4/update-exim4.conf.conf /etc/exim4/update-exim4.conf.conf.backup

    # Set the main configuration parameters
    sudo sed -i "s/^dc_eximconfig_configtype=.*/dc_eximconfig_configtype='internet'/g" /etc/exim4/update-exim4.conf.conf
    sudo sed -i "s/^dc_other_hostnames=.*/dc_other_hostnames='$HOSTNAME'/g" /etc/exim4/update-exim4.conf.conf
    sudo sed -i "s/^dc_local_interfaces=.*/dc_local_interfaces='127.0.0.1 ; ::1 ; 0.0.0.0 ; [::0]'/g" /etc/exim4/update-exim4.conf.conf

    # Set SMTP address preference
    sudo sed -i "s/^dc_ip_version=.*/dc_ip_version='$SMTP_PREF'/g" /etc/exim4/update-exim4.conf.conf

    # Configure Exim4 to listen on port 587
    echo "daemon_smtp_ports = 25 : 587" | sudo tee -a /etc/exim4/exim4.conf.localmacros

    # Enable TLS (Let's assume we want to support TLS)
    # For simplicity, we will generate a self-signed certificate
    sudo openssl req -new -x509 -nodes -days 365 -subj "/CN=$HOSTNAME" -out /etc/ssl/certs/exim.crt -keyout /etc/ssl/private/exim.key
    sudo chmod 640 /etc/ssl/private/exim.key
    sudo chown root:Debian-exim /etc/ssl/private/exim.key

    echo "MAIN_TLS_ENABLE = yes" | sudo tee -a /etc/exim4/exim4.conf.localmacros
    echo "tls_certificate = /etc/ssl/certs/exim.crt" | sudo tee -a /etc/exim4/exim4.conf.localmacros
    echo "tls_privatekey = /etc/ssl/private/exim.key" | sudo tee -a /etc/exim4/exim4.conf.localmacros

    # Enable SMTP authentication
    echo "AUTH_CLIENT_ALLOW_NOTLS_PASSWORDS = yes" | sudo tee -a /etc/exim4/exim4.conf.localmacros

    # Set up authentication
    # We will use a plaintext file for authentication (/etc/exim4/passwd)
    sudo touch /etc/exim4/passwd
    sudo chmod 640 /etc/exim4/passwd
    sudo chown root:Debian-exim /etc/exim4/passwd

    # Add the user to the passwd file
    echo "$USERNAME:$PASSWORD" | sudo tee -a /etc/exim4/passwd

    # Configure Exim to use the authentication file
    sudo tee /etc/exim4/conf.d/auth/30_exim4_config_local <<< '
plain_login:
  driver = plaintext
  public_name = LOGIN
  server_prompts = Username:: : Password::
  server_condition = "${if eq{$auth2}{${lookup{$auth1}lsearch{/etc/exim4/passwd}{$value}{*}}}{yes}{no}}"
  server_set_id = $auth1
'

    # Remove 'Received' headers if requested
    if [ "$REMOVE_HEADER" = "yes" ]; then
        echo "received_header_text = " | sudo tee -a /etc/exim4/exim4.conf.localmacros
    else
        # Ensure 'received_header_text' is not set
        sudo sed -i '/^received_header_text/d' /etc/exim4/exim4.conf.localmacros
    fi

    # Update Exim configuration
    sudo update-exim4.conf

    # Start Exim4 service
    sudo service exim4 start
}

# Function to display SMTP credentials
display_credentials() {
    echo
    echo "Exim4 has been installed and configured."
    echo
    echo "SMTP Credentials:"
    echo "Host: $HOSTNAME"
    echo "Port: 587"
    echo "Username: $USERNAME"
    echo "Password: $PASSWORD"
    echo
    echo "You can now use these SMTP details in Nodemailer."
}

# Function to check if Exim4 is already installed
check_exim_installed() {
    dpkg -s exim4 &> /dev/null
    if [ $? -eq 0 ]; then
        EXIM_INSTALLED="yes"
    else
        EXIM_INSTALLED="no"
    fi
}

# Function to display menu if Exim is already installed
display_menu() {
    while true; do
        echo
        echo "Exim4 is already installed. What would you like to do?"
        echo "1) Edit hostname (current: $(hostname))"
        echo "2) Add or edit SMTP users"
        CURRENT_SMTP_PREF=$(grep "^dc_ip_version" /etc/exim4/update-exim4.conf.conf | cut -d'"' -f2)
        echo "3) Edit SMTP address preference (current: ${CURRENT_SMTP_PREF})"
        CURRENT_HEADER_SETTING=$(grep "received_header_text" /etc/exim4/exim4.conf.localmacros 2>/dev/null)
        if [ -n "$CURRENT_HEADER_SETTING" ]; then
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
                sudo sed -i "s/^dc_other_hostnames=.*/dc_other_hostnames='$HOSTNAME'/g" /etc/exim4/update-exim4.conf.conf
                sudo update-exim4.conf
                ;;
            2)
                prompt_smtp_credentials
                # Create or update the user in passwd file
                sudo sed -i "/^$USERNAME:/d" /etc/exim4/passwd
                echo "$USERNAME:$PASSWORD" | sudo tee -a /etc/exim4/passwd
                ;;
            3)
                prompt_smtp_pref
                sudo sed -i "s/^dc_ip_version=.*/dc_ip_version='$SMTP_PREF'/g" /etc/exim4/update-exim4.conf.conf
                sudo update-exim4.conf
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
                    echo "received_header_text = " | sudo tee -a /etc/exim4/exim4.conf.localmacros
                else
                    sudo sed -i '/^received_header_text/d' /etc/exim4/exim4.conf.localmacros
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

check_exim_installed

if [ "$EXIM_INSTALLED" = "yes" ]; then
    display_menu
else
    # First-time installation
    prompt_hostname
    prompt_smtp_pref
    prompt_remove_header
    prompt_smtp_credentials

    configure_exim4

    restart_services
    display_credentials
fi
