#!/bin/bash
set -euo pipefail

# CiviCRM Cleanup Script for DigitalOcean (Ubuntu 22.04 LTS)
# This script removes CiviCRM, WordPress, LAMP stack components,
# and related configurations to allow for a fresh installation.

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

write_mysql_root_cnf() {
    MYSQL_ROOT_CNF=$(mktemp)
    chmod 600 "$MYSQL_ROOT_CNF"
    {
        echo "[client]"
        echo "user=root"
        echo "password=$DB_ROOT_PASS_FOR_CLEANUP"
    } > "$MYSQL_ROOT_CNF"
}

echo "==============================================="
echo " CiviCRM Cleanup Script"
echo "==============================================="
echo ""
echo "WARNING: This script will remove all CiviCRM, WordPress, Apache,"
echo "MariaDB, and PHP components, including databases and web files."
echo "This action is irreversible. ONLY PROCEED IF YOU WANT TO START FRESH."
echo ""

read -r -p "Are you absolutely sure you want to proceed with cleanup? (yes/no): " CONFIRM_CLEANUP
if ! is_yes "$CONFIRM_CLEANUP"; then
    echo "Cleanup aborted."
    exit 0
fi

read -r -p "Type DELETE to confirm irreversible removal of web files, packages, and database data: " DESTRUCTIVE_CONFIRM
if [[ "$DESTRUCTIVE_CONFIRM" != "DELETE" ]]; then
    echo "Cleanup aborted."
    exit 0
fi

echo ""
read -r -p "Enter the CiviCRM/WordPress Database Name you used (e.g., secure_civicrm_db): " DB_NAME_TO_DROP
read -r -s -p "Enter the MariaDB Root Password: " DB_ROOT_PASS_FOR_CLEANUP
echo
read -r -p "Enter the domain name or droplet IP used for the Apache site config: " DOMAIN_OR_IP
echo ""

validate_mysql_identifier "$DB_NAME_TO_DROP" "Database name"
validate_domain_or_ip "$DOMAIN_OR_IP"
write_mysql_root_cnf

echo "Starting cleanup process..."

# --- 1. Stop Apache before removing web files ---
echo "--- Stopping Apache service ---"
sudo systemctl stop apache2 || true
echo "Apache stopped."
echo ""

# --- 2. Remove WordPress and CiviCRM Files ---
echo "--- Removing WordPress and CiviCRM files ---"
WORDPRESS_DIR="/var/www/html"
if [ -d "$WORDPRESS_DIR" ]; then
    sudo rm -rf "$WORDPRESS_DIR"/*
    echo "WordPress and CiviCRM files removed from $WORDPRESS_DIR."
else
    echo "WordPress directory $WORDPRESS_DIR not found. Skipping file removal."
fi
echo ""

# --- 3. Drop CiviCRM/WordPress Database ---
echo "--- Dropping MariaDB database '$DB_NAME_TO_DROP' ---"
# Escape single quotes in the MariaDB root password for SQL syntax
if ! sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "DROP DATABASE IF EXISTS \`$DB_NAME_TO_DROP\`;"; then
    echo "WARNING: Could not drop database '$DB_NAME_TO_DROP'. Please check MariaDB root password and database name."
else
    echo "Database '$DB_NAME_TO_DROP' dropped."
fi

# Optionally, remove the database user if you know it and want to clean it up too
# read -p "Also remove the CiviCRM/WordPress database user? (yes/no): " REMOVE_DB_USER_CONFIRM
# if [[ "$REMOVE_DB_USER_CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
#     read -p "Enter the CiviCRM/WordPress Database User to remove: " DB_USER_TO_DROP
#     sudo mysql --defaults-extra-file="$MYSQL_ROOT_CNF" -e "DROP USER IF EXISTS '$DB_USER_TO_DROP'@'localhost';"
#     if [ $? -ne 0 ]; then
#         echo "WARNING: Could not drop database user '$DB_USER_TO_DROP'."
#     else
#         echo "Database user '$DB_USER_TO_DROP' dropped."
#     fi
# fi
echo ""

# --- 4. Remove LAMP Stack Packages ---
echo "--- Removing LAMP stack packages ---"
sudo systemctl stop mariadb || true
sudo apt purge -y apache2 mariadb-server php* libapache2-mod-php php-mysql php-mbstring php-xml php-curl php-gd php-zip php-intl php-soap unzip wget
sudo apt autoremove -y
echo "LAMP stack packages purged."
echo ""

# --- 5. Clean up Apache Configuration ---
echo "--- Cleaning up Apache configurations ---"
APACHE_CONF="/etc/apache2/sites-available/$DOMAIN_OR_IP.conf" # Assuming DOMAIN_OR_IP was used for the config name
if [ -f "$APACHE_CONF" ]; then
    sudo a2dissite "$DOMAIN_OR_IP.conf"
    sudo rm "$APACHE_CONF"
    echo "Apache virtual host configuration removed."
else
    echo "Apache virtual host config not found. Skipping removal."
fi
if [ -f /etc/apache2/sites-available/000-default.conf ]; then
    sudo a2ensite 000-default.conf # Re-enable default Apache page
fi
sudo systemctl restart apache2 || echo "Apache restart skipped or failed; Apache may already be removed."
echo "Apache configuration cleaned."
echo ""

# --- 6. Clean up MariaDB Data Directories (Optional, use with caution) ---
echo "--- Cleaning up MariaDB data directories (Optional - use with extreme caution) ---"
read -r -p "Do you want to remove MariaDB data directories? (This will delete ALL databases and users!) (yes/no): " REMOVE_MARIADB_DATA
if is_yes "$REMOVE_MARIADB_DATA"; then
    read -r -p "Type DELETE MYSQL DATA to confirm removal of /var/lib/mysql/*: " MYSQL_DATA_CONFIRM
    [[ "$MYSQL_DATA_CONFIRM" == "DELETE MYSQL DATA" ]] || fail "MariaDB data directory removal was not confirmed."
    sudo rm -rf /var/lib/mysql/*
    echo "MariaDB data directories removed."
else
    echo "Skipping MariaDB data directory removal."
fi
echo ""

# --- 7. Clean up WP-CLI and CiviCRM CLI tools ---
echo "--- Removing WP-CLI and CiviCRM CLI tools ---"
sudo rm -f /usr/local/bin/wp
sudo rm -f /usr/local/bin/cv
echo "CLI tools removed."
echo ""

# --- 8. Reset UFW Firewall (Optional) ---
echo "--- Resetting UFW firewall (Optional) ---"
read -r -p "Do you want to reset UFW firewall to default (deny all incoming, allow all outgoing)? (yes/no): " RESET_UFW
if is_yes "$RESET_UFW"; then
    sudo ufw reset --force
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw enable
    echo "UFW firewall reset."
else
    echo "Skipping UFW firewall reset."
fi
echo ""

echo "==============================================="
echo " CiviCRM Cleanup Complete!"
echo "You can now run the CiviCRM deployment script again on this droplet."
echo "==============================================="
