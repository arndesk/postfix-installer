# Installation

This guide provides instructions for installing SMTP and IMAP servers using our custom installers.

## SMTP Server Installation

To download and run the SMTP installer, use the following command:

```bash
wget https://raw.githubusercontent.com/arndesk/postfix-installer/main/smtp.sh && sudo chmod +x smtp.sh && sudo ./smtp.sh
```
```bash
sudo ./smtp.sh
```


## IMAP Server Installation

To download and run the IMAP installer, use the following command:

```bash
wget https://raw.githubusercontent.com/arndesk/postfix-installer/main/imap.sh && sudo chmod +x imap.sh && sudo ./imap.sh
```
```bash
sudo ./smtp.sh
```

```bash
sudo tail -f /var/log/mail.log
```

**Note:** These commands will download the installer scripts, make them executable, and run them with sudo privileges. Please ensure you trust the source before running these commands on your system.
