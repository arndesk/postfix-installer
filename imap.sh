#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   log "This script must be run as root."
   exit 1
fi

# Ensure the script uses bash
if [ -z "$BASH_VERSION" ]; then
    log "This script requires bash. Please run it using bash."
    exit 1
fi

# Function to preconfigure Postfix to prevent interactive prompts
preconfigure_postfix() {
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    echo "postfix postfix/mailname string $mail_hostname" | debconf-set-selections
}

# Function to install and configure rsyslog
install_rsyslog() {
    if ! dpkg -l | grep -qw rsyslog; then
        log "Installing rsyslog..."
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y rsyslog
    else
        log "rsyslog is already installed."
    fi

    log "Enabling and starting rsyslog service..."
    systemctl enable rsyslog
    systemctl start rsyslog

    # Configure rsyslog to capture mail logs
    RSYSLOG_CONF="/etc/rsyslog.d/50-mail.conf"
    if [ ! -f "$RSYSLOG_CONF" ]; then
        cat <<EOL > "$RSYSLOG_CONF"
# Mail logs
mail.*                          /var/log/mail.log
mail.info                       /var/log/mail.info
mail.warn                       /var/log/mail.warn
mail.err                        /var/log/mail.err
EOL
        log "Configured rsyslog for mail logging."
        systemctl restart rsyslog
    fi
}

# Function to install and configure Postfix and Dovecot
install_mailserver() {
    if ! dpkg -l | grep -qw postfix; then
        # Prompt for hostname during installation
        read -p "Enter the hostname for your mail server (e.g., mail.example.com): " mail_hostname
        hostnamectl set-hostname "$mail_hostname"

        # Preconfigure Postfix before installation
        preconfigure_postfix

        # Update package list
        apt update

        # Install necessary packages without prompts
        log "Installing Postfix, Dovecot, and Rsyslog..."
        DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-imapd rsyslog

        # Enable and start rsyslog service
        install_rsyslog

        # Initialize necessary files
        touch /etc/postfix/virtual
        touch /etc/postfix/virtual_domains
        touch /etc/postfix/vmailbox
        touch /etc/dovecot/users

        # Postfix configuration
        log "Configuring Postfix..."

        postconf -e "myhostname = $mail_hostname"
        postconf -e "myorigin = /etc/mailname"
        postconf -e "mydestination = localhost"
        postconf -e "virtual_mailbox_domains ="
        postconf -e "virtual_mailbox_base = /var/mail/vhosts"
        postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
        postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"
        postconf -e "virtual_alias_domains ="
        postconf -e "smtpd_sasl_type = dovecot"
        postconf -e "smtpd_sasl_path = private/auth"
        postconf -e "smtpd_sasl_auth_enable = yes"
        postconf -e "smtpd_tls_auth_only = yes"
        postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
        postconf -e "smtpd_tls_security_level = may"
        postconf -e "smtpd_tls_loglevel = 1"
        postconf -e "smtp_tls_loglevel = 1"
        postconf -e "smtpd_use_tls = yes"
        postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
        postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key"

        # Generate initial database files
        postmap /etc/postfix/virtual
        postmap /etc/postfix/vmailbox

        # Configure Postfix to use submission port with SASL authentication
        log "Configuring Postfix submission service..."
        if ! grep -q "^submission " /etc/postfix/master.cf; then
            cat <<EOL >> /etc/postfix/master.cf

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_tls_auth_only=yes
EOL
            log "Added submission service to Postfix master.cf."
        else
            log "Submission service already configured in Postfix master.cf."
        fi

        # Dovecot configuration
        log "Configuring Dovecot..."
        cat <<EOL >> /etc/dovecot/conf.d/10-master.conf

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOL

        # Configure Dovecot authentication mechanisms
        sed -i '/^auth_mechanisms =/c\auth_mechanisms = plain login' /etc/dovecot/conf.d/10-auth.conf
        sed -i '/^disable_plaintext_auth =/c\disable_plaintext_auth = no' /etc/dovecot/conf.d/10-auth.conf
        sed -i '/^mail_location =/c\mail_location = maildir:/var/mail/vhosts/%d/%n' /etc/dovecot/conf.d/10-mail.conf

        # Configure Dovecot userdb and passdb
        if ! grep -q "driver = passwd-file" /etc/dovecot/conf.d/auth-passwdfile.conf.ext; then
            cat <<EOL >> /etc/dovecot/conf.d/auth-passwdfile.conf.ext
userdb {
    driver = passwd-file
    args = username_format=%u /etc/dovecot/users
}

passdb {
    driver = passwd-file
    args = username_format=%u /etc/dovecot/users
}
EOL
            log "Configured Dovecot userdb and passdb."
        fi

        # Include passwdfile authentication in Dovecot
        if ! grep -q "!include auth-passwdfile.conf.ext" /etc/dovecot/conf.d/10-auth.conf; then
            echo "!include auth-passwdfile.conf.ext" >> /etc/dovecot/conf.d/10-auth.conf
            log "Included auth-passwdfile.conf.ext in Dovecot configuration."
        fi

        # Create and set permissions for mail directories
        if ! id -u vmail >/dev/null 2>&1; then
            log "Creating vmail user and group..."
            groupadd -g 5000 vmail
            useradd -g vmail -u 5000 vmail -d /var/mail -s /sbin/nologin
        else
            log "vmail user already exists."
        fi

        mkdir -p /var/mail/vhosts
        chown -R vmail:vmail /var/mail
        chmod -R 700 /var/mail

        # Restart services
        log "Restarting Postfix and Dovecot..."
        systemctl restart postfix
        systemctl restart dovecot

        # Open necessary firewall ports
        log "Configuring firewall..."
        ufw allow 25/tcp    # SMTP
        ufw allow 587/tcp   # Submission
        ufw allow 993/tcp   # IMAPS
        ufw reload
    else
        log "Postfix is already installed. Skipping initial setup."
    fi
}

# Function to add a main domain and mailboxes
add_main_domain() {
    read -p "Enter the main domain you want to add (e.g., example.com): " main_domain
    # Validate domain format
    if [[ ! "$main_domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log "Invalid domain format."
        return
    fi

    # Check if domain already exists in virtual_mailbox_domains
    if postconf -n | grep -qw "virtual_mailbox_domains.*$main_domain"; then
        log "Domain $main_domain already exists."
    else
        # Add domain to virtual_mailbox_domains
        existing_domains=$(postconf -h virtual_mailbox_domains)
        if [ -z "$existing_domains" ]; then
            postconf -e "virtual_mailbox_domains = $main_domain"
        else
            postconf -e "virtual_mailbox_domains = $existing_domains, $main_domain"
        fi
        log "Added $main_domain to virtual_mailbox_domains."
    fi

    mkdir -p /var/mail/vhosts/"$main_domain"
    chown -R vmail:vmail /var/mail/vhosts/"$main_domain"

    while true; do
        read -p "Do you want to add a mailbox to $main_domain? (y/n): " yn
        case $yn in
            [Yy]* )
                read -p "Enter the email address (e.g., user@$main_domain): " email_address
                # Validate email format
                if [[ ! "$email_address" =~ ^[A-Za-z0-9._%+-]+@"$main_domain"$ ]]; then
                    log "Invalid email address format."
                    continue
                fi
                username=$(echo "$email_address" | cut -d'@' -f1)
                read -s -p "Enter the password for $email_address: " password
                echo
                # Hash the password
                hashed_password=$(doveadm pw -s SHA512-CRYPT -p "$password")
                # Check if user already exists
                if grep -q "^$email_address:" /etc/dovecot/users; then
                    log "User $email_address already exists."
                else
                    # Add to Dovecot user database
                    echo "$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$main_domain/$username::" >> /etc/dovecot/users
                    # Add to Postfix vmailbox file
                    echo "$email_address    $main_domain/$username/" >> /etc/postfix/vmailbox
                    postmap /etc/postfix/vmailbox
                    mkdir -p /var/mail/vhosts/"$main_domain"/"$username"
                    chown -R vmail:vmail /var/mail/vhosts/"$main_domain"/"$username"
                    chmod -R 700 /var/mail/vhosts/"$main_domain"/"$username"
                    log "Mailbox $email_address added."
                fi
                ;;
            [Nn]* ) break;;
            * ) log "Please answer yes or no.";;
        esac
    done

    # Restart Postfix to apply changes
    log "Restarting Postfix..."
    systemctl restart postfix
}

# Function to add a redirect domain
add_redirect_domain() {
    read -p "Enter the redirect domain you want to add (e.g., redirect.com): " redirect_domain
    # Validate domain format
    if [[ ! "$redirect_domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log "Invalid domain format."
        return
    fi

    # Check if redirect domain already exists
    if grep -qw "^$redirect_domain" /etc/postfix/virtual_domains; then
        log "Redirect domain $redirect_domain already exists."
    else
        echo "$redirect_domain" >> /etc/postfix/virtual_domains
        # Update virtual_alias_domains
        existing_alias_domains=$(postconf -h virtual_alias_domains)
        if [ -z "$existing_alias_domains" ]; then
            postconf -e "virtual_alias_domains = $redirect_domain"
        else
            postconf -e "virtual_alias_domains = $existing_alias_domains, $redirect_domain"
        fi
        log "Added $redirect_domain to virtual_alias_domains."
    fi

    # List existing mailboxes
    echo "Available mailboxes to redirect to:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
    select forward_to in $mailboxes; do
        if [ -n "$forward_to" ]; then
            echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual
            postmap /etc/postfix/virtual
            log "Redirect domain $redirect_domain added to forward to $forward_to."
            break
        else
            log "Invalid selection."
        fi
    done

    # Restart Postfix to apply changes
    log "Restarting Postfix..."
    systemctl restart postfix
}

# Function to edit/delete a mailbox
edit_delete_mailbox() {
    echo "Existing domains:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    select domain in $domains; do
        if [ -n "$domain" ]; then
            log "Selected domain: $domain"
            mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
            echo "Select mailbox:"
            select email_address in $mailboxes; do
                if [ -n "$email_address" ]; then
                    echo "What would you like to do?"
                    echo "1) Change password"
                    echo "2) Delete mailbox"
                    read -p "Enter your choice [1-2]: " choice
                    case $choice in
                        1)
                            read -s -p "Enter the new password for $email_address: " password
                            echo
                            # Hash the password
                            hashed_password=$(doveadm pw -s SHA512-CRYPT -p "$password")
                            # Extract username and domain
                            username=$(echo "$email_address" | cut -d'@' -f1)
                            domain=$(echo "$email_address" | cut -d'@' -f2)
                            # Update the user's password
                            sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::|" /etc/dovecot/users
                            log "Password updated for $email_address."
                            ;;
                        2)
                            # Check if any redirect domains are associated
                            if grep -qw "$email_address" /etc/postfix/virtual; then
                                log "Cannot delete mailbox $email_address because it is associated with redirect domains."
                                log "Please remove or update the associated entries first."
                            else
                                # Extract username and domain
                                username=$(echo "$email_address" | cut -d'@' -f1)
                                domain=$(echo "$email_address" | cut -d'@' -f2)
                                # Remove user's line from Dovecot user database
                                sed -i "/^$email_address:/d" /etc/dovecot/users
                                # Remove user's line from Postfix vmailbox file
                                sed -i "/^$email_address\s/d" /etc/postfix/vmailbox
                                postmap /etc/postfix/vmailbox
                                # Remove user's mailbox directory
                                rm -rf /var/mail/vhosts/"$domain"/"$username"
                                log "Mailbox $email_address deleted."
                            fi
                            ;;
                        *)
                            log "Invalid option."
                            ;;
                    esac
                    break 2
                else
                    log "Invalid selection."
                fi
            done
        else
            log "Invalid selection."
        fi
    done
}

# Function to edit/delete a redirect domain
edit_delete_redirect_domain() {
    echo "Existing redirect domains:"
    awk '{print $1}' /etc/postfix/virtual_domains
    read -p "Enter the redirect domain you want to edit/delete: " redirect_domain
    # Check if redirect domain exists
    if grep -qw "^$redirect_domain" /etc/postfix/virtual_domains; then
        echo "What would you like to do?"
        echo "1) Change forwarding address"
        echo "2) Delete redirect domain"
        read -p "Enter your choice [1-2]: " choice
        case $choice in
            1)
                # List existing mailboxes
                echo "Available mailboxes to redirect to:"
                mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
                select forward_to in $mailboxes; do
                    if [ -n "$forward_to" ]; then
                        # Update the forwarding address in virtual file
                        sed -i "s|^@$redirect_domain\s\+.*|@$redirect_domain    $forward_to|" /etc/postfix/virtual
                        postmap /etc/postfix/virtual
                        log "Redirect domain $redirect_domain updated to forward to $forward_to."
                        break
                    else
                        log "Invalid selection."
                    fi
                done
                ;;
            2)
                # Remove redirect domain from virtual_domains
                sed -i "/^$redirect_domain/d" /etc/postfix/virtual_domains
                # Remove forwarding entry from virtual
                sed -i "/^@$redirect_domain/d" /etc/postfix/virtual
                postmap /etc/postfix/virtual
                # Update virtual_alias_domains
                existing_alias_domains=$(postconf -h virtual_alias_domains | sed "s/, $redirect_domain//g; s/$redirect_domain, //g; s/^$redirect_domain$//")
                postconf -e "virtual_alias_domains = $existing_alias_domains"
                log "Redirect domain $redirect_domain deleted."
                ;;
            *)
                log "Invalid option."
                ;;
        esac
        # Restart Postfix to apply changes
        log "Restarting Postfix..."
        systemctl restart postfix
    else
        log "Redirect domain $redirect_domain does not exist."
    fi
}

# Function to change mailbox password
change_mailbox_password() {
    echo "Existing domains:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    select domain in $domains; do
        if [ -n "$domain" ]; then
            log "Selected domain: $domain"
            mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
            echo "Select mailbox:"
            select email_address in $mailboxes; do
                if [ -n "$email_address" ]; then
                    read -s -p "Enter the new password for $email_address: " password
                    echo
                    # Hash the password
                    hashed_password=$(doveadm pw -s SHA512-CRYPT -p "$password")
                    # Extract username and domain
                    username=$(echo "$email_address" | cut -d'@' -f1)
                    domain=$(echo "$email_address" | cut -d'@' -f2)
                    # Update the user's password
                    sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::|" /etc/dovecot/users
                    log "Password updated for $email_address."
                    break 2
                else
                    log "Invalid selection."
                fi
            done
        else
            log "Invalid selection."
        fi
    done
}

# Function to edit hostname
edit_hostname() {
    read -p "Enter the new hostname for your mail server (e.g., mail.example.com): " new_hostname
    # Validate hostname format
    if [[ ! "$new_hostname" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log "Invalid hostname format."
        return
    fi
    hostnamectl set-hostname "$new_hostname"
    postconf -e "myhostname = $new_hostname"
    # Update mailname
    echo "$new_hostname" > /etc/mailname
    log "Hostname updated to $new_hostname."
    # Restart services to apply changes
    systemctl restart postfix
    systemctl restart dovecot
}

# Function to show all main domains and mailboxes
show_main_domains_and_mailboxes() {
    echo "Main domains and their mailboxes:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    for domain in $domains; do
        echo "Domain: $domain"
        mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
        for mailbox in $mailboxes; do
            echo "  - $mailbox"
        done
    done
}

# Function to show redirect domains and their targets
show_redirect_domains() {
    echo "Redirect domains and their targets:"
    if [ -f /etc/postfix/virtual_domains ]; then
        while read -r line; do
            redirect_domain=$(echo "$line" | awk '{print $1}')
            target=$(grep "^@$redirect_domain" /etc/postfix/virtual | awk '{print $2}')
            echo "Redirect domain: $redirect_domain -> $target"
        done < /etc/postfix/virtual_domains
    else
        echo "No redirect domains found."
    fi
}

# Function to show mailbox usage
show_mailbox_usage() {
    echo "Mailbox usage:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    for domain in $domains; do
        mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
        for mailbox in $mailboxes; do
            username=$(echo "$mailbox" | cut -d'@' -f1)
            maildir="/var/mail/vhosts/$domain/$username"
            if [ -d "$maildir" ]; then
                size=$(du -sh "$maildir" | cut -f1)
                echo "$mailbox: $size"
            else
                echo "$mailbox: Maildir not found."
            fi
        done
    done
}

# Function to ensure Postfix and Dovecot are running
ensure_services_running() {
    log "Ensuring Postfix and Dovecot services are running..."
    systemctl enable postfix
    systemctl start postfix
    systemctl enable dovecot
    systemctl start dovecot
    systemctl enable rsyslog
    systemctl start rsyslog
}

# Function to test email sending and receiving
test_mail_server() {
    log "Testing mail server functionality..."
    # Note: Automated testing would require sending an email via SMTP and checking delivery.
    # This is typically done manually or using external tools/scripts.
    log "Please send a test email to a mailbox and verify its reception."
}

# Main menu
main_menu() {
    while true; do
        echo ""
        echo "===== Mail Server Management Menu ====="
        echo "1) Add a main domain and mailboxes"
        echo "2) Add a redirect domain"
        echo "3) Edit/Delete a mailbox"
        echo "4) Edit/Delete a redirect domain"
        echo "5) Change mailbox password"
        echo "6) Edit hostname"
        echo "7) Show main domains and mailboxes"
        echo "8) Show redirect domains"
        echo "9) Show mailbox usage"
        echo "10) Test mail server functionality"
        echo "11) Exit"
        echo "======================================="
        read -p "Enter your choice [1-11]: " choice
        case $choice in
            1) add_main_domain;;
            2) add_redirect_domain;;
            3) edit_delete_mailbox;;
            4) edit_delete_redirect_domain;;
            5) change_mailbox_password;;
            6) edit_hostname;;
            7) show_main_domains_and_mailboxes;;
            8) show_redirect_domains;;
            9) show_mailbox_usage;;
            10) test_mail_server;;
            11) log "Exiting script."; exit 0;;
            *) log "Invalid option. Please choose between 1 and 11.";;
        esac
    done
}

# Execute functions
install_mailserver
ensure_services_running
main_menu
