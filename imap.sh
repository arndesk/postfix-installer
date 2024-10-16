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

# Initial setup check
if ! dpkg -l | grep -qw postfix; then
    # Prompt for hostname during installation
    read -p "Enter the hostname for your mail server (e.g., mail.example.com): " mail_hostname
    hostnamectl set-hostname "$mail_hostname"

    # Preconfigure Postfix before installation
    preconfigure_postfix

    # Update package list
    apt update

    # Install necessary packages without prompts
    DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-imapd mutt

    # Initialize files if they don't exist
    touch /etc/postfix/virtual
    touch /etc/postfix/virtual_domains
    touch /etc/dovecot/users

    # Postfix configuration
    postconf -e 'virtual_mailbox_domains = proxy:mysql:/etc/postfix/mysql-virtual-mailbox-domains.cf'
    postconf -e 'virtual_mailbox_maps = proxy:mysql:/etc/postfix/mysql-virtual-mailbox-maps.cf'
    postconf -e 'virtual_alias_maps = hash:/etc/postfix/virtual'

    # Dovecot configuration
    echo "auth_mechanisms = plain login" >> /etc/dovecot/conf.d/10-auth.conf
    echo "disable_plaintext_auth = no" >> /etc/dovecot/conf.d/10-auth.conf
    echo "mail_location = maildir:/var/mail/vhosts/%d/%n" >> /etc/dovecot/conf.d/10-mail.conf
    echo "userdb {
        driver = passwd-file
        args = username_format=%u /etc/dovecot/users
    }" >> /etc/dovecot/conf.d/auth-passwdfile.conf.ext

    echo "passdb {
        driver = passwd-file
        args = username_format=%u /etc/dovecot/users
    }" >> /etc/dovecot/conf.d/auth-passwdfile.conf.ext

    echo "!include auth-passwdfile.conf.ext" >> /etc/dovecot/conf.d/10-auth.conf

    # Restart services
    systemctl restart postfix
    systemctl restart dovecot

    echo "Mail server setup is complete."
else
    echo "Postfix is already installed. Skipping initial setup."
fi

# Function to add a main domain and mailboxes
add_main_domain() {
    read -p "Enter the main domain you want to add: " main_domain
    # Check if domain already exists
    if grep -q "$main_domain" /etc/postfix/main.cf; then
        echo "Domain $main_domain already exists."
    else
        # Add domain to virtual_mailbox_domains
        postconf -e "virtual_mailbox_domains = \$virtual_mailbox_domains, $main_domain"
        mkdir -p /var/mail/vhosts/"$main_domain"
        # Ensure vmail user and group exist
        if ! id -u vmail >/dev/null 2>&1; then
            groupadd -g 5000 vmail
            useradd -g vmail -u 5000 vmail -d /var/mail
        fi
        chown -R vmail:vmail /var/mail
    fi

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
                    # Add to Dovecot user database
                    echo "$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$main_domain/$username::" >> /etc/dovecot/users
                    mkdir -p /var/mail/vhosts/"$main_domain"/"$username"
                    chown -R vmail:vmail /var/mail/vhosts/"$main_domain"/"$username"
                    echo "Mailbox $email_address added."
                fi
                ;;
            [Nn]* ) break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Function to add a catch-all mailbox for a main domain
add_catchall_mailbox() {
    read -p "Enter the main domain for the catch-all mailbox: " main_domain
    # Check if domain exists
    if ! grep -q "$main_domain" /etc/postfix/main.cf; then
        echo "Domain $main_domain does not exist. Please add it first."
        return
    fi

    # List existing mailboxes
    echo "Available mailboxes to redirect to:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$main_domain")
    select catchall_email in $mailboxes; do
        if [ -n "$catchall_email" ]; then
            # Add catch-all entry
            echo "@$main_domain    $catchall_email" >> /etc/postfix/virtual
            postmap /etc/postfix/virtual
            echo "Catch-all mailbox for $main_domain set to $catchall_email."
            break
        else
            echo "Invalid selection."
        fi
    done
}

# Function to delete a catch-all mailbox
delete_catchall_mailbox() {
    read -p "Enter the main domain for which you want to delete the catch-all mailbox: " main_domain
    if grep -q "^@$main_domain" /etc/postfix/virtual; then
        sed -i "/^@$main_domain/d" /etc/postfix/virtual
        postmap /etc/postfix/virtual
        echo "Catch-all mailbox for $main_domain has been deleted."
    else
        echo "No catch-all mailbox found for $main_domain."
    fi
}

# Function to edit a catch-all mailbox
edit_catchall_mailbox() {
    read -p "Enter the main domain for which you want to edit the catch-all mailbox: " main_domain
    if grep -q "^@$main_domain" /etc/postfix/virtual; then
        # List existing mailboxes
        echo "Available mailboxes to redirect to:"
        mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users | grep "@$main_domain")
        select new_catchall_email in $mailboxes; do
            if [ -n "$new_catchall_email" ]; then
                sed -i "s|^@$main_domain.*|@$main_domain    $new_catchall_email|" /etc/postfix/virtual
                postmap /etc/postfix/virtual
                echo "Catch-all mailbox for $main_domain updated to $new_catchall_email."
                break
            else
                echo "Invalid selection."
            fi
        done
    else
        echo "No catch-all mailbox found for $main_domain."
    fi
}

# Function to add a redirect domain
add_redirect_domain() {
    read -p "Enter the redirect domain you want to add: " redirect_domain
    # Check if domain already exists
    if grep -q "^$redirect_domain" /etc/postfix/virtual_domains; then
        echo "Redirect domain $redirect_domain already exists."
    else
        echo "$redirect_domain    anything" >> /etc/postfix/virtual_domains
    fi

    # List existing mailboxes
    echo "Available mailboxes to redirect to:"
    mailboxes=$(awk -F':' '{print $1}' /etc/dovecot/users)
    select forward_to in $mailboxes; do
        if [ -n "$forward_to" ]; then
            echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual
            postmap /etc/postfix/virtual
            echo "Redirect domain $redirect_domain added to forward to $forward_to."
            break
        else
            echo "Invalid selection."
        fi
    done
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
                            sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::|" /etc/dovecot/users
                            echo "Password updated for $email_address."
                            ;;
                        2)
                            # Check if any redirect domains or catch-all are associated
                            if grep -q "$email_address" /etc/postfix/virtual; then
                                echo "Cannot delete mailbox $email_address because it is associated with redirect domains or catch-all addresses."
                                echo "Please remove or update the associated entries first."
                            else
                                # Extract username and domain
                                username=$(echo "$email_address" | cut -d'@' -f1)
                                domain=$(echo "$email_address" | cut -d'@' -f2)
                                # Remove user's line from Dovecot user database
                                sed -i "/^$email_address:/d" /etc/dovecot/users
                                # Remove user's mailbox directory
                                rm -rf /var/mail/vhosts/"$domain"/"$username"
                                echo "Mailbox $email_address deleted."
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
    echo "Existing redirect domains:"
    awk '{print $1}' /etc/postfix/virtual_domains
    read -p "Enter the redirect domain you want to edit/delete: " redirect_domain
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
                postmap /etc/postfix/virtual
                echo "Redirect domain $redirect_domain deleted."
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    else
        echo "Redirect domain $redirect_domain does not exist."
    fi
}

# Function to manage catch-all mailboxes
manage_catchall_mailbox() {
    echo "Catch-all Mailbox Management:"
    echo "1) Add a catch-all mailbox"
    echo "2) Edit a catch-all mailbox"
    echo "3) Delete a catch-all mailbox"
    read -p "Enter your choice [1-3]: " choice
    case $choice in
        1) add_catchall_mailbox;;
        2) edit_catchall_mailbox;;
        3) delete_catchall_mailbox;;
        *) echo "Invalid option.";;
    esac
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
                    sed -i "s|^$email_address:.*|$email_address:$hashed_password:5000:5000::/var/mail/vhosts/$domain/$username::|" /etc/dovecot/users
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

# Main menu
while true; do
    echo "Select an option:"
    echo "1) Add a main domain and mailboxes"
    echo "2) Manage catch-all mailboxes"
    echo "3) Add a redirect domain"
    echo "4) Edit/Delete a mailbox"
    echo "5) Edit/Delete a redirect domain"
    echo "6) Change mailbox password"
    echo "7) Edit hostname"
    echo "8) Show main domains and mailboxes"
    echo "9) Show redirect domains"
    echo "10) Show mailbox usage"
    echo "11) Exit"
    read -p "Enter your choice [1-11]: " choice
    case $choice in
        1) add_main_domain;;
        2) manage_catchall_mailbox;;
        3) add_redirect_domain;;
        4) edit_delete_mailbox;;
        5) edit_delete_redirect_domain;;
        6) change_mailbox_password;;
        7) edit_hostname;;
        8) show_main_domains_and_mailboxes;;
        9) show_redirect_domains;;
        10) show_mailbox_usage;;
        11) break;;
        *) echo "Invalid option.";;
    esac
done
