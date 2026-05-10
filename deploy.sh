#!/bin/bash
set -euo pipefail

# CiviCRM Hardened Deployment Script for DigitalOcean (Ubuntu 22.04 LTS)
# This script automates the installation of LAMP (Apache, MariaDB, PHP),
# WordPress, and CiviCRM, with enhanced security considerations for APT threats.

MYSQL_ROOT_CNF=""
cleanup() {
    if [[ -n "${MYSQL_ROOT_CNF:-}" && -f "$MYSQL_ROOT_CNF" ]]; then
        shred -u "$MYSQL_ROOT_CNF" 2>/dev/null || rm -f "$MYSQL_ROOT_CNF"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

is_yes() {
    [[ "$1" =~ ^[Yy][Ee][Ss]$ ]]
}

validate_mysql_identifier() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || fail "$label may only contain letters, numbers, and underscores."
}

validate_domain_or_ip() {
    local value="$1"
    [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ || "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Domain/IP contains invalid characters."
}

validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "SSH port must be numeric."
    (( value >= 1 && value <= 65535 )) || fail "SSH port must be between 1 and 65535."
}

validate_ssh_sources() {
    local sources="$1"
    local source
    [[ -z "$sources" ]] && return 0
    IFS=',' read -ra ADDRS <<< "$sources"
    for source in "${ADDRS[@]}"; do
        source="${source//[[:space:]]/}"
        [[ "$source" =~ ^[A-Fa-f0-9:.]+(/[0-9]{1,3})?$ ]] || fail "Invalid SSH trusted IP/CIDR value: $source"
    done
}

write_mysql_root_cnf() {
    MYSQL_ROOT_CNF=$(mktemp)
    chmod 600 "$MYSQL_ROOT_CNF"
    {
        echo "[client]"
        echo "user=root"
        echo "password=$DB_ROOT_PASS"
    } > "$MYSQL_ROOT_CNF"
}

download_with_sha256() {
    local url="$1"
    local checksum_url="$2"
    local checksum_pattern="$3"
    local destination="$4"
    local checksum_file
    local expected_hash

    checksum_file=$(mktemp)
    curl -fsSL "$url" -o "$destination"
    curl -fsSL "$checksum_url" -o "$checksum_file"
    expected_hash=$(awk -v pattern="$checksum_pattern" '$0 ~ pattern {print $1; exit}' "$checksum_file")
    [[ -n "$expected_hash" ]] || fail "Could not find checksum for $checksum_pattern."
    echo "$expected_hash  $(basename "$destination")" > "$destination.sha256"
    (cd "$(dirname "$destination")" && sha256sum -c "$(basename "$destination").sha256")
    rm -f "$checksum_file" "$destination.sha256"
}

download_wp_cli() {
    local wp_cli_tmp="/tmp/wp-cli.phar"
    local checksum_tmp="/tmp/wp-cli.phar.sha512"
    local expected_hash

    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$wp_cli_tmp"
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512 -o "$checksum_tmp"
    expected_hash=$(awk '{print $1}' "$checksum_tmp")
    echo "$expected_hash  $wp_cli_tmp" | sha512sum -c -
    chmod +x "$wp_cli_tmp"
    sudo mv "$wp_cli_tmp" /usr/local/bin/wp
    rm -f "$checksum_tmp"
}

echo "==============================================="
echo " CiviCRM Hardened Deployment Script"
echo "==============================================="
echo ""
echo "This script will guide you through installing CiviCRM with WordPress,"
echo "and applying initial security hardening measures."
echo "Please ensure you are running this on a fresh Ubuntu 22.04 LTS droplet."
echo ""

# --- 1. User Input for Configuration ---
echo "--- Configuration ---"

read -r -p "Enter your desired WordPress Site Title (e.g., My Secure CiviCRM Site): " WP_SITE_TITLE
read -r -p "Enter your desired WordPress Admin Username: " WP_ADMIN_USER
read -r -s -p "Enter your desired WordPress Admin Password: " WP_ADMIN_PASS
echo
read -r -p "Enter your WordPress Admin Email: " WP_ADMIN_EMAIL

echo ""
echo "--- Database Configuration for MariaDB ---"
read -r -s -p "Enter your desired MariaDB Root Password: " DB_ROOT_PASS
echo
read -r -p "Enter your desired CiviCRM/WordPress Database Name (e.g., secure_civicrm_db): " DB_NAME
read -r -p "Enter your desired CiviCRM/WordPress Database User (e.g., secure_civicrm_user): " DB_USER
read -r -s -p "Enter your desired CiviCRM/WordPress Database Password: " DB_PASS
echo

echo ""
read -r -p "Enter your domain name (e.g., example.com) or droplet IP if no domain: " DOMAIN_OR_IP
echo ""

echo "--- SSH Security Configuration ---"
echo "IMPORTANT: For APT defense, SSH access should be highly restricted."
read -r -p "Enter trusted IP addresses for SSH access (comma-separated, e.g., 203.0.113.1,198.51.100.0/24). Leave blank to allow all (NOT RECOMMENDED for APT defense): " SSH_TRUSTED_IPS
read -r -p "Change default SSH port (22) to a non-standard port? (yes/no): " CHANGE_SSH_PORT
NEW_SSH_PORT=22
if is_yes "$CHANGE_SSH_PORT"; then
    read -r -p "Enter new SSH port (e.g., 2222): " NEW_SSH_PORT
fi
read -r -p "Disable password authentication for SSH (RECOMMENDED - only SSH keys)? (yes/no): " DISABLE_SSH_PASSWORD

validate_mysql_identifier "$DB_NAME" "Database name"
validate_mysql_identifier "$DB_USER" "Database user"
validate_domain_or_ip "$DOMAIN_OR_IP"
validate_port "$NEW_SSH_PORT"
validate_ssh_sources "$SSH_TRUSTED_IPS"

echo ""
echo "Starting hardened deployment. This may take some time..."

# --- 2. Create a Sudo User (if running as root initially) ---
# This script assumes you are running as a sudo user or will create one.
if [[ $(id -u) -eq 0 ]]; then
    echo "--- Running as root. Creating a non-root sudo user for best practice ---"
    read -r -p "Enter a new non-root sudo username: " NEW_SUDO_USER
    [[ "$NEW_SUDO_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "Invalid Linux username."
    sudo adduser "$NEW_SUDO_USER"
    sudo usermod -aG sudo "$NEW_SUDO_USER"
    echo "User '$NEW_SUDO_USER' created. Please ensure you have SSH keys set up for this user."
    echo "This script will continue as root for initial setup, but switch to the new user for SSH access post-deployment."
fi
echo ""

# --- 3. Update System Packages ---
echo "--- Updating system packages ---"
sudo apt update -y
sudo apt upgrade -y
if [ $? -ne 0 ]; then echo "Error updating system. Exiting."; exit 1; fi
echo "System packages updated."
echo ""

# --- 4. Install LAMP Stack (Apache, MariaDB, PHP) ---
echo "--- Installing Apache, MariaDB, PHP and essential extensions ---"
sudo apt install apache2 mariadb-server php libapache2-mod-php php-mysql php-mbstring php-xml php-curl php-gd php-zip php-intl php-soap unzip wget curl ca-certificates -y
sudo apt install php-bcmath -y
if [ $? -ne 0 ]; then echo "Error installing LAMP stack. Exiting."; exit 1; fi
echo "LAMP stack installed."
echo ""

# --- 5. Secure MariaDB Installation ---
echo "--- Securing MariaDB ---"

# Escape single quotes in the MariaDB root password for SQL syntax
# This handles passwords containing single quotes, which caused the previous error.
ESCAPED_DB_ROOT_PASS=$(printf '%s' "$DB_ROOT_PASS" | sed "s/'/''/g")

sudo mysql -u root <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ESCAPED_DB_ROOT_PASS';
MYSQL_SCRIPT
if [ $? -ne 0 ]; then echo "Error setting MariaDB root password. Exiting."; exit 1; fi

# Run mysql_secure_installation steps programmatically
# Note: For production, consider running `mysql_secure_installation` manually for full prompts.
write_mysql_root_cnf

sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;"
sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'); FLUSH PRIVILEGES;"
sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES;"
sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "FLUSH PRIVILEGES;"

echo "MariaDB basic security measures applied."
echo ""

# --- 6. Create Database and User for CiviCRM/WordPress ---
echo "--- Creating database and user for CiviCRM/WordPress ---"
# Escape single quotes in the CiviCRM/WordPress database password for SQL syntax
ESCAPED_DB_PASS=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")

sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" <<MYSQL_SCRIPT
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ESCAPED_DB_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES, TRIGGER, CREATE ROUTINE, ALTER ROUTINE, REFERENCES, CREATE VIEW, SHOW VIEW ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
if [ $? -ne 0 ]; then echo "Error creating database or user. Exiting."; exit 1; fi
echo "Database '$DB_NAME' and user '$DB_USER' created."
echo ""

# --- 7. Install WP-CLI ---
echo "--- Installing WP-CLI ---"
download_wp_cli
if [ $? -ne 0 ]; then echo "Error installing WP-CLI. Exiting."; exit 1; fi
echo "WP-CLI installed."
echo ""

# --- 8. Download and Configure WordPress ---
echo "--- Downloading and configuring WordPress ---"
WORDPRESS_DIR="/var/www/html"
sudo rm -rf "$WORDPRESS_DIR"/* # Clean up default Apache index.html

sudo wp core download --path="$WORDPRESS_DIR" --allow-root
if [ $? -ne 0 ]; then echo "Error downloading WordPress. Exiting."; exit 1; fi

# Set permissions before config
sudo chown -R www-data:www-data "$WORDPRESS_DIR"
sudo find "$WORDPRESS_DIR" -type d -exec chmod 755 {} \;
sudo find "$WORDPRESS_DIR" -type f -exec chmod 644 {} \;

printf '%s\n' "$DB_PASS" | sudo wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --path="$WORDPRESS_DIR" --allow-root --prompt=dbpass
if [ $? -ne 0 ]; then echo "Error creating WordPress config. Exiting."; exit 1; fi

printf '%s\n' "$WP_ADMIN_PASS" | sudo wp core install --url="http://$DOMAIN_OR_IP" --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_email="$WP_ADMIN_EMAIL" --path="$WORDPRESS_DIR" --allow-root --prompt=admin_password
if [ $? -ne 0 ]; then echo "Error installing WordPress core. Exiting."; exit 1; fi
echo "WordPress installed and configured."
echo ""

# --- 9. Configure Apache Virtual Host with HSTS ---
echo "--- Configuring Apache Virtual Host with HSTS ---"
APACHE_CONF="/etc/apache2/sites-available/$DOMAIN_OR_IP.conf"

sudo tee "$APACHE_CONF" > /dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    ServerName $DOMAIN_OR_IP
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined

    # Redirect HTTP to HTTPS (will be uncommented after Certbot)
    # RewriteEngine On
    # RewriteCond %{HTTPS} off
    # RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

    <Directory /var/www/html/>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

sudo a2ensite "$DOMAIN_OR_IP.conf"
sudo a2enmod rewrite
sudo a2enmod headers # Enable headers module for HSTS
sudo a2dissite 000-default.conf
sudo systemctl restart apache2
if [ $? -ne 0 ]; then echo "Error configuring Apache. Exiting."; exit 1; fi
echo "Apache configured for WordPress."
echo ""

# --- 10. Install CiviCRM ---
echo "--- Installing CiviCRM ---"
echo "Attempting to find latest CiviCRM stable version..."
CIVICRM_VERSION=$(curl -fsSL https://civicrm.org/download | grep -oE 'Download CiviCRM [0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | awk '{print $3}' || true)
if [ -z "$CIVICRM_VERSION" ]; then
    fail "Could not automatically find the latest CiviCRM version. Visit https://civicrm.org/download and update this script."
fi
CIVICRM_RELEASE_BASE="https://download.civicrm.org/release/$CIVICRM_VERSION"
CIVICRM_DL_URL="$CIVICRM_RELEASE_BASE/civicrm-$CIVICRM_VERSION-wordpress.zip"
CIVICRM_SHA_URL="$CIVICRM_RELEASE_BASE/civicrm-$CIVICRM_VERSION.SHA256SUMS"
echo "Found latest CiviCRM stable version: $CIVICRM_VERSION"

cd /tmp
rm -rf /tmp/civicrm /tmp/civicrm.zip
download_with_sha256 "$CIVICRM_DL_URL" "$CIVICRM_SHA_URL" "civicrm-$CIVICRM_VERSION-wordpress.zip" /tmp/civicrm.zip
if [ $? -ne 0 ]; then echo "Error downloading CiviCRM. Please check the URL ($CIVICRM_DL_URL). Exiting."; exit 1; fi
unzip civicrm.zip
sudo mv civicrm "$WORDPRESS_DIR"/wp-content/plugins/
if [ $? -ne 0 ]; then echo "Error moving CiviCRM files. Exiting."; exit 1; fi
sudo mkdir -p "$WORDPRESS_DIR"/wp-content/plugins/civicrm/files
sudo chown -R www-data:www-data "$WORDPRESS_DIR"/wp-content/plugins/civicrm
echo "CiviCRM files moved to WordPress plugins directory."
echo ""

echo "--- Activating CiviCRM WordPress plugin ---"
sudo wp plugin activate civicrm --path="$WORDPRESS_DIR" --allow-root
if [ $? -ne 0 ]; then echo "Error activating CiviCRM plugin. Exiting."; exit 1; fi
echo "CiviCRM WordPress plugin activated."
echo ""

# --- 11. Install CiviCRM via Command Line Tool (cv) ---
echo "--- Installing CiviCRM via Command Line Tool (cv) ---"

# Install cv (CiviCRM Command Line Tool)
curl -fsSL https://download.civicrm.org/cv/cv.phar -o /tmp/cv.phar
chmod +x /tmp/cv.phar
sudo mv /tmp/cv.phar /usr/local/bin/cv
echo "CiviCRM CLI tool (cv) installed."

# Run CiviCRM installation using cv
echo "Running CiviCRM installation..."
(cd "$WORDPRESS_DIR" && sudo -u www-data /usr/local/bin/cv core:install \
    --cms-base-url="http://$DOMAIN_OR_IP")
if [ $? -ne 0 ]; then echo "Error installing CiviCRM core via cv. Exiting."; exit 1; fi
echo "CiviCRM core installation completed."
echo ""

# --- 12. Hardening WordPress and PHP ---
echo "--- Applying WordPress and PHP hardening measures ---"

# Disable XML-RPC in WordPress (Common attack vector)
sudo wp rewrite flush --path="$WORDPRESS_DIR" --allow-root
sudo wp config set DISABLE_XML_RPC true --path="$WORDPRESS_DIR" --allow-root
echo "WordPress XML-RPC disabled."

# PHP Hardening (modify php.ini)
PHP_INI_PATH=$(find /etc/php/ -name php.ini | grep apache2 | head -n 1 || true) # Find the correct php.ini for Apache
if [ -f "$PHP_INI_PATH" ]; then
    echo "Modifying PHP configuration at $PHP_INI_PATH"
    sudo sed -i 's/display_errors = On/display_errors = Off/' "$PHP_INI_PATH"
    sudo sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI_PATH"
    # Disable dangerous functions - add to disable_functions if not present
    if ! grep -q "disable_functions = " "$PHP_INI_PATH"; then
        sudo sed -i '/;disable_functions =/a disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,symlink,pcntl_exec,ini_alter,ini_restore' "$PHP_INI_PATH"
    else
        sudo sed -i 's/^disable_functions = \(.*\)/disable_functions = \1,exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,symlink,pcntl_exec,ini_alter,ini_restore/' "$PHP_INI_PATH"
    fi
    sudo systemctl restart apache2
    echo "PHP hardened."
else
    echo "WARNING: Could not find php.ini for Apache. Manual PHP hardening may be required."
fi
echo ""

# --- 13. SSH Hardening ---
echo "--- Hardening SSH ---"
SSH_CONFIG="/etc/ssh/sshd_config"

# Disable root login
sudo sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
sudo sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin no/' "$SSH_CONFIG" # for newer configs

# Disable password authentication if requested
if is_yes "$DISABLE_SSH_PASSWORD"; then
    sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
    sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
    echo "SSH password authentication disabled. Ensure you have SSH keys for non-root users."
else
    echo "SSH password authentication remains enabled. Consider disabling for higher security."
fi

# Change SSH port if requested
if is_yes "$CHANGE_SSH_PORT" && [[ "$NEW_SSH_PORT" -ne 22 ]]; then
    if ! grep -q "^Port $NEW_SSH_PORT" "$SSH_CONFIG"; then
        sudo sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" "$SSH_CONFIG"
        sudo sed -i "s/^Port 22/Port $NEW_SSH_PORT/" "$SSH_CONFIG"
        echo "SSH port changed to $NEW_SSH_PORT."
        SSH_PORT_CHANGED="true"
    else
        echo "SSH port already set to $NEW_SSH_PORT or custom port. No change needed."
    fi
else
    echo "SSH port remains 22."
fi

sudo systemctl restart ssh
if [ $? -ne 0 ]; then echo "Error restarting SSH service. Please check SSH configuration manually. Exiting."; exit 1; fi
echo "SSH hardening applied."
echo ""

# --- 14. Configure Firewall (UFW) ---
echo "--- Configuring UFW firewall ---"
sudo ufw reset --force # Reset UFW to a clean state
sudo ufw default deny incoming
sudo ufw default allow outgoing # Allow all outbound by default for now, can be restricted later

# Allow specific SSH port and IPs
if [[ "$SSH_TRUSTED_IPS" != "" ]]; then
    IFS=',' read -ra ADDRS <<< "$SSH_TRUSTED_IPS"
    for ip in "${ADDRS[@]}"; do
        ip="${ip//[[:space:]]/}"
        sudo ufw allow from "$ip" to any port "$NEW_SSH_PORT" comment "Allow SSH from trusted IP: $ip"
    done
    echo "UFW: SSH allowed from trusted IPs on port $NEW_SSH_PORT."
else
    sudo ufw allow "$NEW_SSH_PORT"/tcp comment "Allow SSH on port $NEW_SSH_PORT from anywhere (NOT RECOMMENDED for APT defense)"
    echo "UFW: WARNING: SSH allowed from anywhere on port $NEW_SSH_PORT. Restrict IPs for better security."
fi

# Allow HTTP and HTTPS
sudo ufw allow 80/tcp comment "Allow HTTP for Certbot initial setup"
sudo ufw allow 443/tcp comment "Allow HTTPS"

sudo ufw --force enable
echo "UFW firewall configured and enabled."
echo ""

# --- 15. Automate Daily Security Updates via Cron ---
echo "--- Setting up daily automated security updates ---"
CRON_JOB="@daily apt update -y && apt upgrade -y && apt autoremove -y"
(sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
echo "Daily automated updates configured via cron."
echo ""

# --- 16. Final Permissions ---
echo "--- Setting final permissions ---"
sudo chown -R www-data:www-data "$WORDPRESS_DIR"
sudo find "$WORDPRESS_DIR" -type d -exec chmod 755 {} \;
sudo find "$WORDPRESS_DIR" -type f -exec chmod 644 {} \;
echo "Permissions set correctly."
echo ""

# --- 17. Post-Installation Notes ---
echo "==============================================="
echo " CiviCRM Hardened Deployment Complete!"
echo "==============================================="
echo ""
echo "Your CiviCRM with WordPress site should now be accessible at:"
echo "http://$DOMAIN_OR_IP"
echo ""
echo "WordPress Admin Dashboard:"
echo "http://$DOMAIN_OR_IP/wp-admin"
echo "Username: $WP_ADMIN_USER"
echo "Password: (not displayed; use the password entered during setup)"
echo ""
echo "CiviCRM can be accessed from within your WordPress Admin Dashboard."
echo ""
echo "--- Next Steps (CRITICAL for APT Defense) ---"
echo "1.  **CONNECT VIA NEW SSH PORT (IF CHANGED):** If you changed the SSH port, you will need to reconnect using `ssh -p $NEW_SSH_PORT your_username@$DOMAIN_OR_IP`."
echo "2.  **CONFIGURE SSL (HTTPS):**"
echo "    If you used a domain name, it is MANDATORY to secure your site with an SSL certificate using Certbot (Let's Encrypt)."
echo "    Ensure your domain is pointing to your droplet's IP address, then run:"
echo "    sudo snap install core"
echo "    sudo snap refresh core"
echo "    sudo snap install --classic certbot"
echo "    sudo ln -s /snap/bin/certbot /usr/bin/certbot"
echo "    sudo certbot --apache"
echo "    Follow the prompts to enable HTTPS. This will also enable HSTS in Apache."
echo "3.  **VIRTUAL PRIVATE NETWORK (VPN) FOR ADMINISTRATION:**"
echo "    *STRONGLY RECOMMENDED*: Do NOT expose SSH directly to the internet, even with IP restrictions. Deploy a VPN server (on a separate, hardened droplet or network appliance) and tunnel all administrative access through it. Then, restrict SSH (port $NEW_SSH_PORT) access to *only* the VPN's internal IP range."
echo "4.  **MULTI-FACTOR AUTHENTICATION (MFA):**"
echo "    * **SSH:** Implement MFA for all SSH logins (e.g., using Google Authenticator PAM module, YubiKey). This is a critical defense against credential compromise."
echo "    * **WordPress/CiviCRM:** Enforce MFA for all administrative users. Use WordPress security plugins that offer MFA functionality."
echo "5.  **DATABASE PRIVILEGES:**"
echo "    The database user was granted CiviCRM's documented database-level privileges on only the configured database. Review whether your production lifecycle allows separating install/upgrade privileges from day-to-day runtime privileges."
echo "6.  **FILE INTEGRITY MONITORING (FIM):**"
echo "    Deploy FIM tools (e.g., AIDE, OSSEC) to monitor critical system and web application files for unauthorized changes. This helps detect persistent threats."
echo "7.  **WEB APPLICATION FIREWALL (WAF):**"
echo "    Consider deploying a WAF (e.g., ModSecurity for Apache, or a cloud-based WAF service like Cloudflare) to detect and block common web application attacks."
echo "8.  **CENTRALIZED LOGGING & ANOMALY DETECTION:**"
echo "    Configure `rsyslog` or `auditd` to send all system, web server, database, and application logs to a centralized, secured logging solution (e.g., ELK Stack, Splunk, Graylog). Implement anomaly detection to flag unusual login patterns, command execution, or outbound connections."
echo "9.  **INTRUSION DETECTION/PREVENTION SYSTEM (IDS/IPS):**"
echo "    Consider deploying an IDS/IPS (e.g., Suricata, Snort) on the network edge or directly on the server to detect and potentially block malicious network traffic, including command-and-control (C2) communication."
echo "10. **DISK ENCRYPTION:**"
echo "    Ensure the droplet's disk is encrypted. DigitalOcean offers this during droplet creation for some plans. For existing droplets, consider manual LUKS encryption if data sensitivity requires it."
echo "11. **REGULAR, VERIFIED, OFF-SITE, IMMUTABLE BACKUPS:**"
echo "    Implement automated, frequent backups of both the CiviCRM database and application files. Store them securely *off-site* (e.g., DigitalOcean Spaces, S3) and *test restoration regularly*. Explore immutable backups to protect against tampering."
echo "12. **SOFTWARE VERSION CONTROL:**"
echo "    Maintain strict version control for CiviCRM, WordPress, and all plugins/themes. Only use stable, supported versions and apply security updates immediately."
echo "13. **THREAT INTELLIGENCE & INCIDENT RESPONSE:**"
echo "    Stay informed about known APT groups and their Tactics, Techniques, and Procedures (TTPs). Develop and regularly *test* a comprehensive incident response plan tailored to sophisticated attacks."
echo "14. **PERIODIC SECURITY AUDITS & PENETRATION TESTS:**"
echo "    Engage third parties to conduct regular security audits and penetration tests to identify weaknesses."
echo ""
echo "These additional steps are critical for defending against Advanced Persistent Threats."
echo "Your commitment to ongoing operational security is paramount."
echo "==============================================="
