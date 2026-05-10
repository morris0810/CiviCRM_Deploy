# CiviCRM Deploy

Hardened deployment and cleanup scripts for installing CiviCRM on WordPress on a fresh DigitalOcean Ubuntu 22.04 LTS droplet.

This repository is intended for operators who want a repeatable starting point for a small CiviCRM deployment without manually stitching together Apache, MariaDB, PHP, WordPress, WP-CLI, CiviCRM, firewall rules, and baseline host hardening.

## What This Repo Provides

- `deploy.sh`: installs and configures a CiviCRM-on-WordPress stack on Ubuntu 22.04 LTS.
- `clean.sh`: removes the deployed stack so the droplet can be rebuilt from a known baseline.

The scripts are interactive. They prompt for site, database, domain, SSH, and firewall settings, then perform the installation or cleanup using `sudo`.

## Why Use These Scripts

CiviCRM deployments touch several layers at once: operating system packages, PHP extensions, web server configuration, database users and privileges, WordPress configuration, CiviCRM files, firewall policy, and administrative access. Manual setup is easy to get mostly right while leaving sensitive gaps, especially around password handling, overly broad database grants, unsigned downloads, exposed SSH, and destructive cleanup operations.

These scripts aim to make the initial deployment more consistent by:

- Installing a known LAMP baseline for WordPress and CiviCRM.
- Prompting for secrets without echoing them to the terminal.
- Avoiding long-lived root database password files in the user's home directory.
- Validating database names, database users, hostnames, IP values, and SSH ports before use.
- Verifying downloaded WP-CLI and CiviCRM release artifacts with published checksums.
- Granting the application database user scoped database-level privileges instead of unrestricted global privileges.
- Disabling direct display of the WordPress admin password at the end of setup.
- Applying baseline SSH and UFW firewall hardening.
- Requiring explicit typed confirmation before destructive cleanup actions.

This is not a complete security program. It is a hardened bootstrap process that should be followed by normal production controls: HTTPS, backups, monitoring, patching, access reviews, MFA, off-host logging, and tested incident response.

## Target Environment

The scripts are written for:

- DigitalOcean droplets.
- Ubuntu 22.04 LTS.
- Apache, MariaDB, PHP, WordPress, and CiviCRM.
- A fresh server or disposable rebuild environment.

They are not written as a generic Linux installer. Running them on an existing production server may remove or overwrite services, files, firewall rules, web roots, and database configuration.

## Repository Files

| File | Purpose |
| --- | --- |
| `deploy.sh` | Installs Apache, MariaDB, PHP, WordPress, CiviCRM, WP-CLI, `cv`, Apache virtual host configuration, UFW rules, and baseline hardening. |
| `clean.sh` | Removes WordPress/CiviCRM files, drops the configured database, purges LAMP packages, removes CLI tools, and optionally removes MariaDB data and resets UFW. |
| `LICENSE` | Project license. |

## Deployment Overview

`deploy.sh` performs these main steps:

1. Prompts for WordPress site details, WordPress admin credentials, MariaDB credentials, domain or droplet IP, SSH restrictions, and SSH hardening choices.
2. Validates user-supplied identifiers and network values.
3. Updates and upgrades Ubuntu packages.
4. Installs Apache, MariaDB, PHP, required PHP extensions, `curl`, `wget`, `unzip`, and CA certificates.
5. Sets a MariaDB root password and applies basic database hardening.
6. Creates a dedicated CiviCRM/WordPress database and database user.
7. Installs WP-CLI after checksum verification.
8. Downloads and configures WordPress in `/var/www/html`.
9. Creates an Apache virtual host for the supplied domain or IP.
10. Detects the current stable CiviCRM release, downloads it, verifies its SHA256 checksum, and installs it as a WordPress plugin.
11. Installs the CiviCRM command line tool `cv`.
12. Activates CiviCRM and runs CiviCRM installation.
13. Applies baseline WordPress, PHP, SSH, and firewall hardening.
14. Prints next steps for HTTPS, MFA, VPN-based administration, backups, monitoring, and ongoing security work.

## Prerequisites

Before running `deploy.sh`, prepare:

- A fresh Ubuntu 22.04 LTS droplet.
- SSH access as `root` or a sudo-capable user.
- A domain name pointed at the droplet, or the droplet public IP if no domain is available yet.
- A strong MariaDB root password.
- A database name using only letters, numbers, and underscores.
- A database username using only letters, numbers, and underscores.
- A strong database password for the application user.
- A strong WordPress admin password.
- A WordPress admin email address.
- Your trusted SSH source IP addresses or CIDR ranges, if you want to restrict SSH access.
- A plan for reconnecting if you change the SSH port or disable password authentication.

Important: if you disable SSH password authentication, confirm that key-based SSH access works before ending your session.

## Recommended DigitalOcean Setup

1. Create a new Ubuntu 22.04 LTS droplet.
2. Add SSH keys during droplet creation.
3. Use the smallest droplet that comfortably fits your expected CiviCRM workload, then scale after measuring real usage.
4. Point your DNS A record at the droplet public IP.
5. Log in by SSH.
6. Clone this repository or copy the scripts to the droplet.
7. Review the scripts before running them.

## Running The Deployment

From the droplet:

```bash
git clone https://github.com/morris0810/CiviCRM_Deploy.git
cd CiviCRM_Deploy
chmod +x deploy.sh clean.sh
bash ./deploy.sh
```

Answer the prompts carefully. The script will ask whether to:

- Restrict SSH to trusted source IPs.
- Change the SSH port.
- Disable SSH password authentication.

For an internet-facing server, restricting SSH by trusted IP or VPN source is strongly preferred. Leaving SSH open to the internet is convenient, but it increases exposure.

## After Deployment

The deployment script leaves the site accessible over HTTP so that Certbot can complete certificate issuance. Configure HTTPS immediately after DNS is pointing to the droplet:

```bash
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --apache
```

Then verify:

- `https://your-domain.example` loads.
- `https://your-domain.example/wp-admin` loads.
- WordPress login works.
- CiviCRM is visible inside the WordPress admin dashboard.
- SSH access still works from a new terminal before closing the current session.
- UFW rules match your intended access policy.

## Cleanup And Rebuild

Use `clean.sh` only when you want to remove the deployment and start fresh.

```bash
cd CiviCRM_Deploy
bash ./clean.sh
```

The cleanup script:

- Requires `yes` confirmation.
- Requires typing `DELETE` before irreversible removal begins.
- Removes files under `/var/www/html`.
- Drops the named CiviCRM/WordPress database.
- Purges Apache, MariaDB, PHP packages, and related packages.
- Removes `/usr/local/bin/wp` and `/usr/local/bin/cv`.
- Optionally removes all MariaDB data under `/var/lib/mysql`.
- Optionally resets UFW.

The MariaDB data directory removal step requires the exact confirmation phrase `DELETE MYSQL DATA`.

Warning: `clean.sh` is destructive. Do not run it on a server that hosts unrelated websites, databases, or applications.

## Security Model

The scripts improve the baseline deployment posture, but they do not make the server "secure" by themselves. They focus on reducing common setup risks:

- Shell execution stops on unset variables and command failures.
- User input is constrained before being used in shell or SQL contexts.
- Database password use avoids command-line `-pPASSWORD` patterns where possible.
- Temporary MySQL credential files are created with `0600` permissions and removed on exit.
- Downloaded application artifacts are verified with checksums.
- Database privileges are scoped to the configured database.
- SSH can be restricted by source address and moved away from port 22.
- Password authentication can be disabled for SSH.
- UFW defaults to denying inbound traffic except explicit allowances.

You should still add:

- HTTPS with automatic renewal.
- MFA for WordPress/CiviCRM administrators.
- Key-only SSH with a tested recovery path.
- A VPN or bastion host for administrative access.
- Automated off-site backups with restore tests.
- Log forwarding and alerting.
- File integrity monitoring.
- Regular OS, WordPress, plugin, and CiviCRM updates.
- Periodic vulnerability reviews and penetration tests.

## Operational Notes

- The scripts assume WordPress lives in `/var/www/html`.
- The Apache virtual host file is named from the domain or IP value you provide.
- `deploy.sh` resets UFW during firewall setup.
- `clean.sh` may restart Apache even after package removal; failure is tolerated because Apache may already be gone.
- `deploy.sh` installs a daily root cron job for package updates and cleanup.
- If you change SSH ports, reconnect with `ssh -p PORT user@host`.
- If DNS is not ready, use the droplet IP during initial testing and update configuration later.

## Troubleshooting

### The script cannot find the latest CiviCRM version

The script parses `https://civicrm.org/download` to identify the current stable version. If the page format changes, update the CiviCRM version detection logic in `deploy.sh` or manually download the correct WordPress release from CiviCRM.

### CiviCRM download verification fails

This usually means the download did not match the published SHA256 checksum, the release URL changed, or the download was incomplete. Do not bypass checksum verification unless you have independently verified the artifact.

### SSH stops working after hardening

Use an existing open session to inspect:

```bash
sudo systemctl status ssh
sudo sshd -t
sudo ufw status verbose
```

Confirm the SSH port, source IP rules, and key-based login configuration.

### WordPress loads but CiviCRM does not

Check Apache, PHP, WordPress plugin status, and CiviCRM logs:

```bash
sudo systemctl status apache2
sudo wp plugin list --path=/var/www/html --allow-root
sudo tail -n 100 /var/log/apache2/error.log
```

### Database connection fails

Confirm the database exists, the database user exists, and credentials in `wp-config.php` match what you entered:

```bash
sudo mysql --defaults-extra-file=/path/to/root-client.cnf -e "SHOW DATABASES;"
sudo wp config get DB_NAME --path=/var/www/html --allow-root
sudo wp config get DB_USER --path=/var/www/html --allow-root
```

Do not store long-lived root database credential files on the server. The command above is only an example of the MySQL client option pattern.

## Maintenance

Keep this repository under version control and review changes before running them on a real server. For production use, test changes on a disposable droplet first, then rebuild or apply the reviewed process to the production environment.

Recommended maintenance cycle:

1. Test the scripts on a fresh staging droplet.
2. Confirm WordPress, CiviCRM, PHP, Apache, and MariaDB versions.
3. Validate HTTPS issuance and renewal.
4. Validate backup and restore.
5. Review firewall and SSH access.
6. Document any local changes before promoting them.

## Limitations

- The scripts target a single-server deployment.
- They do not configure external object storage, CDN, or managed database services.
- They do not install Certbot automatically during the main deployment.
- They do not configure email deliverability for CiviCRM.
- They do not replace a real backup strategy.
- They do not provide high availability.
- They do not guarantee compliance with any regulatory framework.

## License

See `LICENSE`.