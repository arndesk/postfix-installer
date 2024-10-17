#!/usr/bin/env bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Ensure the script uses bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash. Please run it using bash."
    exit 1
fi

# Function to preconfigure Postfix to prevent interactive prompts
preconfigure_postfix() {
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    echo "postfix postfix/mailname string $mail_hostname" | debconf-set-selections
}

# Function to install rsyslog if not installed
install_rsyslog() {
    if ! dpkg -l | grep -qw rsyslog; then
        echo "Installing rsyslog..."
        apt update
        apt install -y rsyslog
        systemctl enable rsyslog
        systemctl start rsyslog
    else
        echo "rsyslog is already installed."
    fi
}

# Function to update virtual_alias_maps to include both hash and regexp maps
update_virtual_alias_maps() {
    current_maps=$(postconf -h virtual_alias_maps | tr -d ' ')
    # Ensure that both hash and regexp maps are included
    new_maps=""
    if [[ "$current_maps" == *"hash:/etc/postfix/virtual"* ]]; then
        new_maps="$current_maps"
    else
        if [ -z "$current_maps" ]; then
            new_maps="hash:/etc/postfix/virtual"
        else
            new_maps="$current_maps,hash:/etc/postfix/virtual"
        fi
    fi
    if [[ "$current_maps" == *"regexp:/etc/postfix/virtual_regexp"* ]]; then
        # Already includes regexp map
        :
    else
        new_maps="$new_maps,regexp:/etc/postfix/virtual_regexp"
    fi
    # Remove leading commas
    new_maps=$(echo "$new_maps" | sed 's/^,\s*//')
    # Remove duplicate commas
    new_maps=$(echo "$new_maps" | sed 's/,\s*/,/g')
    # Update virtual_alias_maps
    postconf -e "virtual_alias_maps = $new_maps"
}

# Initial setup check
if ! dpkg -l | grep -qw postfix; then
    # Prompt for hostname during installation
    read -p "Enter the hostname for your mail server (e.g., mail.example.com): " mail_hostname
    hostnamectl set-hostname "$mail_hostname"

    # Preconfigure Postfix before installation
    preconfigure_postfix

    # Install rsyslog
    install_rsyslog

    # Update package list
    apt update

    # Install necessary packages without prompts
    DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-imapd dovecot-pop3d

    # Initialize files if they don't exist
    touch /etc/postfix/virtual
    touch /etc/postfix/virtual_domains
    touch /etc/postfix/vmailbox
    touch /etc/dovecot/users
    touch /etc/postfix/virtual_regexp

    # Postfix configuration
    postconf -e "virtual_mailbox_domains ="
    postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
    postconf -e "virtual_alias_domains = hash:/etc/postfix/virtual_domains"
    postconf -e "virtual_mailbox_base = /var/mail/vhosts"
    postconf -e "virtual_uid_maps = static:5000"
    postconf -e "virtual_gid_maps = static:5000"
    postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual, regexp:/etc/postfix/virtual_regexp"

    # Generate initial database files
    postmap /etc/postfix/virtual
    postmap /etc/postfix/virtual_domains
    postmap /etc/postfix/vmailbox

    # Dovecot configuration
    sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^auth_mechanisms =.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's!^#mail_location =.*!mail_location = maildir:/var/mail/vhosts/%d/%n!' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's/^mail_privileged_group =.*/mail_privileged_group = mail/' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's/^#mail_plugins =.*/mail_plugins = quota/' /etc/dovecot/conf.d/10-mail.conf

    # Protocols configuration
    sed -i '/^protocol imap {/,/^}/ s/^  #mail_plugins =.*/  mail_plugins = \$mail_plugins imap_quota/' /etc/dovecot/conf.d/20-imap.conf

    # Quota configuration
    cat <<EOT > /etc/dovecot/conf.d/90-quota.conf
plugin {
  quota = maildir:User quota
}
EOT

    # Authentication configuration
    cat <<EOT > /etc/dovecot/conf.d/auth-passwdfile.conf.ext
passdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
}

userdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
}
EOT

    sed -i '/!include auth-system.conf.ext/ a !include auth-passwdfile.conf.ext' /etc/dovecot/conf.d/10-auth.conf

    # Set permissions for mail directories
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 vmail -d /var/mail
    mkdir -p /var/mail/vhosts
    chown -R vmail:vmail /var/mail
    chmod -R 700 /var/mail

    # Restart services
    systemctl restart postfix
    systemctl restart dovecot

    echo "Mail server setup is complete."
else
    # Install rsyslog
    install_rsyslog

    # Update Postfix configuration
    postconf -e "virtual_mailbox_base = /var/mail/vhosts"
    postconf -e "virtual_uid_maps = static:5000"
    postconf -e "virtual_gid_maps = static:5000"
    postconf -e "virtual_alias_domains = hash:/etc/postfix/virtual_domains"

    # Update virtual_alias_maps to include both hash and regexp maps
    update_virtual_alias_maps

    # Generate hash maps
    postmap /etc/postfix/virtual
    postmap /etc/postfix/virtual_domains

    # Restart Postfix to apply changes
    systemctl restart postfix

    echo "Postfix is already installed. Updated configurations."
fi

# Function to add multiple redirect domains
add_multiple_redirect_domains() {
    echo "Enter the redirect domains you want to add, one per line."
    echo "When done, enter an empty line to finish:"
    domains=()
    while true; do
        read domain
        if [ -z "$domain" ]; then
            break
        fi
        domains+=("$domain")
    done

    if [ ${#domains[@]} -eq 0 ]; then
        echo "No domains entered."
        return
    fi

    # Remove duplicates
    domains=($(printf "%s\n" "${domains[@]}" | sort -u))

    # List existing mailboxes
    echo "Available mailboxes to redirect to:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
    select forward_to in $mailboxes; do
        if [ -n "$forward_to" ]; then
            break
        else
            echo "Invalid selection."
        fi
    done

    # Get main domains
    main_domains=$(postconf -h virtual_mailbox_domains | tr -d ' ' | tr ',' '\n')

    for redirect_domain in "${domains[@]}"; do
        # Check if domain is in main domains
        if echo "$main_domains" | grep -qw "$redirect_domain"; then
            echo "Domain $redirect_domain is already a main domain. Skipping."
            continue
        fi

        # Check for wildcard domain
        if [[ "$redirect_domain" == *"*"* ]]; then
            echo "Adding wildcard domain: $redirect_domain"
            # Update virtual_alias_maps to include regexp map
            update_virtual_alias_maps
            touch /etc/postfix/virtual_regexp

            # Convert wildcard domain to regex pattern
            pattern=$(echo "$redirect_domain" | sed 's/\./\\./g' | sed 's/\*/.*/g')

            # Check if pattern already exists
            if grep -qE "^$pattern[[:space:]]" /etc/postfix/virtual_regexp; then
                # Update the forwarding address
                sed -i "s|^$pattern\s.*|$pattern    $forward_to|" /etc/postfix/virtual_regexp
                echo "Updated wildcard domain $redirect_domain to forward to $forward_to."
            else
                echo "$pattern    $forward_to" >> /etc/postfix/virtual_regexp
                echo "Added wildcard domain $redirect_domain to forward to $forward_to."
            fi
        else
            # Non-wildcard domain
            # Check if domain already exists in virtual_domains
            if grep -q "^$redirect_domain\s" /etc/postfix/virtual_domains; then
                echo "Redirect domain $redirect_domain already exists. Updating forwarding address."
            else
                echo "$redirect_domain    anything" >> /etc/postfix/virtual_domains
                postmap /etc/postfix/virtual_domains
            fi

            # Update forwarding address
            if grep -q "^@$redirect_domain\s" /etc/postfix/virtual; then
                sed -i "s|^@$redirect_domain\s.*|@$redirect_domain    $forward_to|" /etc/postfix/virtual
            else
                echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual
            fi
            postmap /etc/postfix/virtual
            echo "Redirect domain $redirect_domain added/updated to forward to $forward_to."
        fi
    done

    # Restart Postfix to apply changes
    systemctl restart postfix
}

# Function to add a main domain and mailboxes
add_main_domain() {
    read -p "Enter the main domain you want to add: " main_domain

    # Check if domain is in redirect domains
    redirect_domains=$(awk '{print $1}' /etc/postfix/virtual_domains)
    if [ -f /etc/postfix/virtual_regexp ]; then
        wildcard_domains=$(awk '{print $1}' /etc/postfix/virtual_regexp | sed 's/\\\././g' | sed 's/\.\*/\*/g')
        redirect_domains="$redirect_domains"$'\n'"$wildcard_domains"
    fi

    if echo "$redirect_domains" | grep -qw "$main_domain"; then
        echo "Domain $main_domain is already a redirect domain. Please remove it from redirect domains first."
        return
    fi

    # Check if domain already exists in virtual_mailbox_domains
    if postconf -n | grep -q "virtual_mailbox_domains.*$main_domain"; then
        echo "Domain $main_domain already exists."
    else
        # Add domain to virtual_mailbox_domains
        existing_domains=$(postconf -h virtual_mailbox_domains)
        if [ -z "$existing_domains" ]; then
            postconf -e "virtual_mailbox_domains = $main_domain"
        else
            postconf -e "virtual_mailbox_domains = $existing_domains, $main_domain"
        fi
    fi

    mkdir -p /var/mail/vhosts/"$main_domain"
    chown -R vmail:vmail /var/mail/vhosts/"$main_domain"

    while true; do
        read -p "Do you want to add a mailbox to $main_domain? (y/n): " yn
        case $yn in
            [Yy]* )
                read -p "Enter the email address (e.g., user@$main_domain): " email_address
                username=$(echo "$email_address" | cut -d'@' -f1)
                domain=$(echo "$email_address" | cut -d'@' -f2)
                if [ "$domain" != "$main_domain" ]; then
                    echo "The domain part of the email address does not match the main domain."
                    continue
                fi
                read -s -p "Enter the password for $email_address: " password
                echo
                # Hash the password
                hashed_password=$(doveadm pw -s SHA512-CRYPT -u "$email_address" -p "$password")
                # Check if user already exists
                if grep -q "^$email_address:" /etc/dovecot/users; then
                    echo "User $email_address already exists."
                else
                    # Add to Dovecot user database with default quota
                    echo "$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$main_domain/$username::userdb_quota_rule=*:storage=2048M" >> /etc/dovecot/users
                    # Add to Postfix vmailbox file
                    echo "$email_address    $main_domain/$username/" >> /etc/postfix/vmailbox
                    postmap /etc/postfix/vmailbox
                    mkdir -p /var/mail/vhosts/"$main_domain"/"$username"
                    chown -R vmail:vmail /var/mail/vhosts/"$main_domain"/"$username"
                    chmod -R 700 /var/mail/vhosts/"$main_domain"/"$username"
                    echo "Mailbox $email_address added with default quota of 2048M."
                fi
                ;;
            [Nn]* ) break;;
            * ) echo "Please answer yes or no.";;
        esac
    done

    # Restart Postfix and Dovecot to apply changes
    systemctl restart postfix
    systemctl restart dovecot
}

# Function to add a redirect domain
add_redirect_domain() {
    read -p "Enter the redirect domain you want to add: " redirect_domain

    # Check if domain is in main domains
    main_domains=$(postconf -h virtual_mailbox_domains | tr -d ' ' | tr ',' '\n')
    if echo "$main_domains" | grep -qw "$redirect_domain"; then
        echo "Domain $redirect_domain is already a main domain. Cannot add it as a redirect domain."
        return
    fi

    # Check if domain already exists in virtual_domains
    if grep -q "^$redirect_domain\s" /etc/postfix/virtual_domains; then
        echo "Redirect domain $redirect_domain already exists."
    else
        echo "$redirect_domain    anything" >> /etc/postfix/virtual_domains
        postmap /etc/postfix/virtual_domains
    fi

    # List existing mailboxes
    echo "Available mailboxes to redirect to:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
    select forward_to in $mailboxes; do
        if [ -n "$forward_to" ]; then
            # Update forwarding address
            if grep -q "^@$redirect_domain\s" /etc/postfix/virtual; then
                sed -i "s|^@$redirect_domain\s.*|@$redirect_domain    $forward_to|" /etc/postfix/virtual
            else
                echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual
            fi
            postmap /etc/postfix/virtual
            echo "Redirect domain $redirect_domain added/updated to forward to $forward_to."
            break
        else
            echo "Invalid selection."
        fi
    done

    # Restart Postfix to apply changes
    systemctl restart postfix
}

# Function to edit/delete a mailbox
edit_delete_mailbox() {
    echo "Existing domains:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    select domain in $domains; do
        if [ -n "$domain" ]; then
            echo "Selected domain: $domain"
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
                            hashed_password=$(doveadm pw -s SHA512-CRYPT -u "$email_address" -p "$password")
                            # Extract username and domain
                            username=$(echo "$email_address" | cut -d'@' -f1)
                            domain=$(echo "$email_address" | cut -d'@' -f2)
                            # Update the user's password
                            # Preserve existing quota setting
                            quota_rule=$(grep "^$email_address:" /etc/dovecot/users | awk -F'userdb_quota_rule=' '{print $2}')
                            sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::userdb_quota_rule=$quota_rule|" /etc/dovecot/users
                            echo "Password updated for $email_address."
                            ;;
                        2)
                            # Check if any redirect domains are associated
                            if grep -q "$email_address" /etc/postfix/virtual; then
                                echo "Cannot delete mailbox $email_address because it is associated with redirect domains."
                                echo "Please remove or update the associated entries first."
                            else
                                # Extract username and domain
                                username=$(echo "$email_address" | cut -d'@' -f1)
                                domain=$(echo "$email_address" | cut -d'@' -f2)
                                # Remove user's line from Dovecot user database
                                sed -i "/^$email_address:/d" /etc/dovecot/users
                                # Remove user's line from Postfix vmailbox file
                                sed -i "/^$email_address\s/d" /etc/postfix/vmailbox
                                postmap /etc/postfix/vmailbox
                                # Remove user's mailbox directory and all data
                                rm -rf /var/mail/vhosts/"$domain"/"$username"
                                echo "Mailbox $email_address and all associated data deleted."
                                # Restart Postfix and Dovecot to apply changes
                                systemctl restart postfix
                                systemctl restart dovecot
                            fi
                            ;;
                        *)
                            echo "Invalid option."
                            ;;
                    esac
                    break 2
                else
                    echo "Invalid selection."
                fi
            done
        else
            echo "Invalid selection."
        fi
    done
}

# Function to edit/delete a redirect domain
edit_delete_redirect_domain() {
    # Updated to handle wildcard domains
    echo "Existing redirect domains:"
    awk '{print $1}' /etc/postfix/virtual_domains
    if [ -f /etc/postfix/virtual_regexp ]; then
        echo "Wildcard redirect domains:"
        awk '{print $1}' /etc/postfix/virtual_regexp | sed 's/\\\././g' | sed 's/\.*/\*/g'
    fi
    read -p "Enter the redirect domain you want to edit/delete: " redirect_domain
    if [[ "$redirect_domain" == *"*"* ]]; then
        # Handle wildcard domain
        pattern=$(echo "$redirect_domain" | sed 's/\./\\./g' | sed 's/\*/.*/g')
        if grep -qE "^$pattern[[:space:]]" /etc/postfix/virtual_regexp; then
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
                            sed -i "s|^$pattern\s.*|$pattern    $forward_to|" /etc/postfix/virtual_regexp
                            echo "Wildcard redirect domain $redirect_domain updated to forward to $forward_to."
                            break
                        else
                            echo "Invalid selection."
                        fi
                    done
                    ;;
                2)
                    sed -i "/^$pattern\s.*/d" /etc/postfix/virtual_regexp
                    echo "Wildcard redirect domain $redirect_domain deleted."
                    ;;
                *)
                    echo "Invalid option."
                    ;;
            esac
            # Restart Postfix to apply changes
            systemctl restart postfix
        else
            echo "Wildcard redirect domain $redirect_domain does not exist."
        fi
    else
        # Non-wildcard domain
        if grep -q "^$redirect_domain" /etc/postfix/virtual_domains; then
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
                            sed -i "s|^@$redirect_domain.*|@$redirect_domain    $forward_to|" /etc/postfix/virtual
                            postmap /etc/postfix/virtual
                            echo "Redirect domain $redirect_domain updated to forward to $forward_to."
                            break
                        else
                            echo "Invalid selection."
                        fi
                    done
                    ;;
                2)
                    # Remove redirect domain from virtual_domains
                    sed -i "/^$redirect_domain/d" /etc/postfix/virtual_domains
                    # Remove forwarding entry from virtual
                    sed -i "/^@$redirect_domain/d" /etc/postfix/virtual
                    postmap /etc/postfix/virtual_domains
                    postmap /etc/postfix/virtual
                    echo "Redirect domain $redirect_domain deleted."
                    ;;
                *)
                    echo "Invalid option."
                    ;;
            esac
            # Restart Postfix to apply changes
            systemctl restart postfix
        else
            echo "Redirect domain $redirect_domain does not exist."
        fi
    fi
}

# Function to change mailbox password
change_mailbox_password() {
    echo "Existing domains:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    select domain in $domains; do
        if [ -n "$domain" ]; then
            echo "Selected domain: $domain"
            mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
            echo "Select mailbox:"
            select email_address in $mailboxes; do
                if [ -n "$email_address" ]; then
                    read -s -p "Enter the new password for $email_address: " password
                    echo
                    # Hash the password
                    hashed_password=$(doveadm pw -s SHA512-CRYPT -u "$email_address" -p "$password")
                    # Extract username and domain
                    username=$(echo "$email_address" | cut -d'@' -f1)
                    domain=$(echo "$email_address" | cut -d'@' -f2)
                    # Update the user's password
                    # Preserve existing quota setting
                    quota_rule=$(grep "^$email_address:" /etc/dovecot/users | awk -F'userdb_quota_rule=' '{print $2}')
                    sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::userdb_quota_rule=$quota_rule|" /etc/dovecot/users
                    echo "Password updated for $email_address."
                    break 2
                else
                    echo "Invalid selection."
                fi
            done
        else
            echo "Invalid selection."
        fi
    done
}

# Function to change mailbox quota
change_mailbox_quota() {
    echo "Existing domains:"
    domains=$(awk -F':' '{print $1}' /etc/dovecot/users | cut -d'@' -f2 | sort | uniq)
    select domain in $domains; do
        if [ -n "$domain" ]; then
            echo "Selected domain: $domain"
            mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$domain")
            echo "Select mailbox to change quota:"
            select email_address in $mailboxes; do
                if [ -n "$email_address" ]; then
                    while true; do
                        read -p "Enter the new quota in MB for $email_address (e.g., 1024 for 1GB): " quota
                        # Validate that quota is a positive integer
                        if [[ "$quota" =~ ^[0-9]+$ ]]; then
                            break
                        else
                            echo "Invalid input. Please enter a positive integer."
                        fi
                    done
                    # Convert quota to MB format for Dovecot
                    quota_mb="${quota}M"
                    # Extract username and domain
                    username=$(echo "$email_address" | cut -d'@' -f1)
                    domain=$(echo "$email_address" | cut -d'@' -f2)
                    # Update the user's quota
                    sed -i "s|\(^$email_address:.*userdb_quota_rule=\)\(.*\)|\1*:storage=${quota_mb}|" /etc/dovecot/users
                    echo "Quota updated to ${quota_mb} for $email_address."
                    # Restart Dovecot to apply changes
                    systemctl restart dovecot
                    break 2
                else
                    echo "Invalid selection."
                fi
            done
        else
            echo "Invalid selection."
        fi
    done
}

# Function to edit hostname
edit_hostname() {
    read -p "Enter the new hostname for your mail server (e.g., mail.example.com): " new_hostname
    hostnamectl set-hostname "$new_hostname"
    echo "Hostname updated to $new_hostname."
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

# Function to show redirect domains and where they redirect
show_redirect_domains() {
    echo "Redirect domains and their targets:"
    if [ -f /etc/postfix/virtual_domains ]; then
        while read -r line; do
            redirect_domain=$(echo "$line" | awk '{print $1}')
            target=$(grep "^@$redirect_domain" /etc/postfix/virtual | awk '{print $2}')
            echo "Redirect domain: $redirect_domain -> $target"
        done < /etc/postfix/virtual_domains
    fi
    if [ -f /etc/postfix/virtual_regexp ]; then
        echo "Wildcard redirect domains:"
        while read -r line; do
            pattern=$(echo "$line" | awk '{print $1}' | sed 's/\\\././g' | sed 's/\.\*/\*/g')
            target=$(echo "$line" | awk '{print $2}')
            echo "Pattern: $pattern -> $target"
        done < /etc/postfix/virtual_regexp
    else
        echo "No redirect domains found."
    fi
}

# Function to show mailbox usage
show_mailbox_usage() {
    echo "Mailbox usage:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
    for mailbox in $mailboxes; do
        # Get quota and usage using doveadm
        quota_info=$(doveadm quota get -u "$mailbox")
        if [ -n "$quota_info" ]; then
            # Parse the output
            storage_line=$(echo "$quota_info" | grep 'STORAGE')
            used_kB=$(echo "$storage_line" | awk '{print $3}')
            limit_kB=$(echo "$storage_line" | awk '{print $4}')
            # Convert to MB
            used_MB=$((used_kB / 1024))
            if [ "$limit_kB" -eq -1 ]; then
                limit_display="Unlimited"
            else
                limit_MB=$((limit_kB / 1024))
                limit_display="${limit_MB}MB"
            fi
            echo "$mailbox: Used ${used_MB}MB, Quota ${limit_display}"
        else
            echo "$mailbox: Could not retrieve quota information."
        fi
    done
}

# Main menu
while true; do
    echo "Select an option:"
    echo "1) Add a main domain and mailboxes"
    echo "2) Add a redirect domain"
    echo "3) Add multiple redirect domains"
    echo "4) Edit/Delete a mailbox"
    echo "5) Edit/Delete a redirect domain"
    echo "6) Change mailbox password"
    echo "7) Change mailbox quota"
    echo "8) Edit hostname"
    echo "9) Show main domains and mailboxes"
    echo "10) Show redirect domains"
    echo "11) Show mailbox usage"
    echo "12) Exit"
    read -p "Enter your choice [1-12]: " choice
    case $choice in
        1) add_main_domain;;
        2) add_redirect_domain;;
        3) add_multiple_redirect_domains;;
        4) edit_delete_mailbox;;
        5) edit_delete_redirect_domain;;
        6) change_mailbox_password;;
        7) change_mailbox_quota;;
        8) edit_hostname;;
        9) show_main_domains_and_mailboxes;;
        10) show_redirect_domains;;
        11) show_mailbox_usage;;
        12) break;;
        *) echo "Invalid option.";;
    esac
done
