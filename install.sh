#!/bin/bash

# This script installs and configures Postfix as an SMTP server with authentication on port 587.
# It also modifies the bounce message template to include the recipient's email in the subject.

# Prompt for hostname
read -p "Enter the hostname (e.g., mail.example.com): " HOSTNAME

# Prompt for username
read -p "Enter the username for SMTP authentication: " USERNAME

# Prompt for password with confirmation
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

# Remove any sending limits
sudo postconf -e "smtpd_client_connection_rate_limit = 0"
sudo postconf -e "smtpd_client_message_rate_limit = 0"
sudo postconf -e "smtpd_client_connection_count_limit = 0"
sudo postconf -e "smtpd_recipient_limit = 0"
sudo postconf -e "anvil_rate_time_unit = 60s"

# Configure Postfix to use custom bounce template
sudo postconf -e "bounce_template_file = /etc/postfix/bounce_templates"

# Configure Postfix to listen on port 587
sudo sed -i '/^#submission inet n - n - - smtpd$/s/^#//' /etc/postfix/master.cf

# Remove any existing submission configurations to prevent duplication
sudo sed -i '/^submission inet n.*smtpd$/,/^$/d' /etc/postfix/master.cf

# Add the submission configuration
echo "submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING" | sudo tee -a /etc/postfix/master.cf

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

# Create custom bounce template with proper variable escaping
sudo bash -c 'cat > /etc/postfix/bounce_templates << "EOF"
# Custom bounce message with recipient in subject

bounce_notice_template = <<END
Subject: Undelivered Mail Returned to Sender (Recipient: \${recipient})

This is the mail system at host \${hostname}.

I'm sorry to have to inform you that your message could not
be delivered to one or more recipients. It's attached below.

\${if >{\${server_notify_recipient}}{0}}
For further assistance, please send mail to postmaster.

If you do so, please include this problem report. You can
delete your own text from the attached returned message.
\${endif}

                        The mail system

\${failure_notice_recipient}
END
EOF'

# Set permissions for the bounce template file
sudo chown root:root /etc/postfix/bounce_templates
sudo chmod 644 /etc/postfix/bounce_templates

# Restart services
sudo service saslauthd restart
sudo service postfix restart

# Display the SMTP credentials
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
