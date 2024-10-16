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

# Update package list
apt update

# Install necessary packages
apt install -y postfix dovecot-imapd mutt

# Prompt for hostname
read -p "Enter the hostname for your mail server (e.g., mail.example.com): " mail_hostname
hostnamectl set-hostname "$mail_hostname"
postconf -e "myhostname = $mail_hostname"

# Initialize files if they don't exist
touch /etc/postfix/virtual
touch /etc/postfix/virtual_domains
touch /etc/dovecot/users

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

# Function to add a redirect domain
add_redirect_domain() {
    read -p "Enter the redirect domain you want to add: " redirect_domain
    # Check if domain already exists
    if grep -q "^$redirect_domain" /etc/postfix/virtual_domains; then
        echo "Redirect domain $redirect_domain already exists."
    else
        echo "$redirect_domain    anything" >> /etc/postfix/virtual_domains
    fi

    # List existing mailboxes as suggestions
    echo "Available mailboxes to redirect to:"
    awk -F':' '{print $1}' /etc/dovecot/users
    read -p "Enter the main domain mailbox to forward to (e.g., user@maindomain.com): " forward_to

    echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual

    postmap /etc/postfix/virtual
    echo "Redirect domain $redirect_domain added to forward to $forward_to."
}

# Function to edit/delete a mailbox
edit_delete_mailbox() {
    echo "Existing mailboxes:"
    awk -F':' '{print $1}' /etc/dovecot/users
    read -p "Enter the email address of the mailbox you want to edit/delete: " email_address
    if grep -q "^$email_address:" /etc/dovecot/users; then
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
                # Check if any redirect domains are associated
                if grep -q "$email_address" /etc/postfix/virtual; then
                    echo "Cannot delete mailbox $email_address because redirect domains are associated with it."
                    echo "Please remove or update the associated redirect domains first."
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
    else
        echo "Mailbox $email_address does not exist."
    fi
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
                # List existing mailboxes as suggestions
                echo "Available mailboxes to redirect to:"
                awk -F':' '{print $1}' /etc/dovecot/users
                read -p "Enter the new main domain mailbox to forward to (e.g., user@maindomain.com): " forward_to
                # Update forwarding address in virtual file
                sed -i "s|^@$redirect_domain.*|@$redirect_domain    $forward_to|" /etc/postfix/virtual
                postmap /etc/postfix/virtual
                echo "Redirect domain $redirect_domain updated to forward to $forward_to."
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

# Function to change mailbox password
change_mailbox_password() {
    echo "Existing mailboxes:"
    awk -F':' '{print $1}' /etc/dovecot/users
    read -p "Enter the email address of the mailbox to change password: " email_address
    if grep -q "^$email_address:" /etc/dovecot/users; then
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
    else
        echo "Mailbox $email_address does not exist."
    fi
}

# Main menu
while true; do
    echo "Select an option:"
    echo "1) Add a main domain and mailboxes"
    echo "2) Add a redirect domain"
    echo "3) Edit/Delete a mailbox"
    echo "4) Edit/Delete a redirect domain"
    echo "5) Change mailbox password"
    echo "6) Exit"
    read -p "Enter your choice [1-6]: " choice
    case $choice in
        1) add_main_domain;;
        2) add_redirect_domain;;
        3) edit_delete_mailbox;;
        4) edit_delete_redirect_domain;;
        5) change_mailbox_password;;
        6) break;;
        *) echo "Invalid option.";;
    esac
done

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
