
#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Update package list
apt update

# Install necessary packages
apt install -y postfix dovecot-imapd mutt

# Function to add a main domain and mailboxes
add_main_domain() {
    read -p "Enter the main domain you want to add: " main_domain
    echo "virtual_alias_domains = $main_domain" >> /etc/postfix/main.cf

    mkdir -p /var/mail/vhosts/$main_domain
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 vmail -d /var/mail

    chown -R vmail:vmail /var/mail

    while true; do
        read -p "Do you want to add a mailbox to $main_domain? (y/n): " yn
        case $yn in
            [Yy]* ) 
                read -p "Enter the mailbox username (e.g., user): " username
                read -s -p "Enter the password for $username@$main_domain: " password
                echo
                # Hash the password
                hashed_password=$(doveadm pw -s SHA512-CRYPT -u $username@$main_domain -p $password)
                # Add to Dovecot user database
                echo "$username@$main_domain:$hashed_password:5000:5000::/var/mail/vhosts/$main_domain/$username::" >> /etc/dovecot/users
                mkdir -p /var/mail/vhosts/$main_domain/$username
                chown -R vmail:vmail /var/mail/vhosts/$main_domain/$username
                ;;
            [Nn]* ) break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Function to add a redirect domain
add_redirect_domain() {
    read -p "Enter the redirect domain you want to add: " redirect_domain
    echo "$redirect_domain    anything" >> /etc/postfix/virtual_domains

    read -p "Enter the main domain mailbox to forward to (e.g., user@maindomain.com): " forward_to

    echo "@$redirect_domain    $forward_to" >> /etc/postfix/virtual

    postmap /etc/postfix/virtual
}

# Main menu
while true; do
    echo "Select an option:"
    echo "1) Add a main domain and mailboxes"
    echo "2) Add a redirect domain"
    echo "3) Exit"
    read -p "Enter your choice [1-3]: " choice
    case $choice in
        1) add_main_domain;;
        2) add_redirect_domain;;
        3) break;;
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
