#!/bin/bash

# Function to install necessary packages and configure postfix
install_postfix() {
  # Ask for the hostname, relay username, and password
  read -p "Enter your hostname (e.g., mail.example.com): " HOSTNAME
  read -p "Enter your relay email username: " RELAY_USER
  read -s -p "Enter your relay email password: " RELAY_PASS
  echo ""
  
  # Update and install Postfix
  echo "Installing Postfix..."
  sudo apt update
  sudo apt install -y postfix libsasl2-modules mailutils
  
  # Set the hostname
  echo "Setting hostname to $HOSTNAME..."
  sudo hostnamectl set-hostname $HOSTNAME
  echo "127.0.0.1   $HOSTNAME" | sudo tee -a /etc/hosts

  # Configure Postfix
  echo "Configuring Postfix for relaying through external SMTP..."
  sudo postconf -e "relayhost = [$HOSTNAME]:587"
  sudo postconf -e "smtp_use_tls = yes"
  sudo postconf -e "smtp_sasl_auth_enable = yes"
  sudo postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
  sudo postconf -e "smtp_sasl_security_options = noanonymous"
  sudo postconf -e "smtp_tls_security_level = may"
  sudo postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
  
  # Set relay credentials
  echo "[$HOSTNAME]:587 $RELAY_USER:$RELAY_PASS" | sudo tee /etc/postfix/sasl_passwd
  sudo postmap /etc/postfix/sasl_passwd
  sudo chmod 600 /etc/postfix/sasl_passwd
  sudo chown root:root /etc/postfix/sasl_passwd
  
  # Restart Postfix to apply the changes
  echo "Restarting Postfix..."
  sudo systemctl restart postfix

  echo "Postfix installation and configuration is complete."
}

# Function to add custom header for bounced emails
setup_bounce_processing() {
  echo "Configuring Postfix to handle bounced emails with a custom header..."
  
  # Create a custom bounce filter
  sudo tee /etc/postfix/header_checks > /dev/null <<EOL
/^Received:.*$/ IGNORE
/^X-Bounce-Status:/ IGNORE
/^To:.*$/ PREPEND X-Bounced: true
EOL

  # Apply the new filter in Postfix
  sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
  
  # Reload Postfix configuration
  sudo systemctl reload postfix
  
  echo "Custom bounce header setup complete."
}

# Main function to run the script
main() {
  install_postfix
  setup_bounce_processing
  echo "Postfix is now set up with a bounce handling header for Nodemailer."
}

# Start the script
main
