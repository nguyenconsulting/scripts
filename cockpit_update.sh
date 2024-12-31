#!/bin/bash

#==============================================================================
# Cockpit Certificate Updater for RaspbianPi v0.1
# Created: [December 30, 2024]
# Last Modified: [December 31, 2024]
#==============================================================================

# Main header function
main_header() {
    echo -e "\e[34m============================================\e[0m"  # Blue
    echo -e "\e[32m Cockpit Certificate Updater for RaspbianPi  \e[0m"  # Green
    echo -e "\e[34m============================================\e[0m"  # Blue
}

# Status function with colors
status() {
    local type="$1"
    local message="$2"
    case "$type" in
        info) echo -e "\e[36m[INFO]\e[0m \e[37m$message\e[0m" ;;      # Cyan for [INFO], White for message
        ok) echo -e "\e[32m[OK]\e[0m $message" ;;          # Green
        warning) echo -e "\e[33m[WARNING]\e[0m $message" ;;# Yellow
        critical) echo -e "\e[31m[CRITICAL]\e[0m $message" ;;# Red
        *) echo -e "\e[37m[UNKNOWN]\e[0m $message" ;;      # White
    esac
}

# Check if running as sudoer or root
if [[ $EUID -ne 0 ]]; then
    status critical "This script must be run as root or with sudo."
    exit 1
fi

main_header

# Check if cockpit is installed
if ! dpkg -l | grep -q cockpit; then
    status warning "Cockpit is not installed."
    read -p "Would you like to install Cockpit? (y/n): " install_cockpit
    if [[ "$install_cockpit" == "y" ]]; then
        apt-get update && apt-get install -y cockpit
        status ok "Cockpit installed successfully."
    else
        status critical "Cockpit is required for this script to run."
        exit 1
    fi
else
    status ok "Cockpit is already installed."
fi

# Check if certificate files exist
hostname=$(hostname)
crt_file="/etc/cockpit/ws-certs.d/$hostname.crt"
key_file="/etc/cockpit/ws-certs.d/$hostname.key"

if [[ ! -f "$crt_file" || ! -f "$key_file" ]]; then
    status critical "Certificate files not found in /etc/cockpit/ws-certs.d/"
    exit 1
fi

# Check if certificates are valid against each other
if ! openssl x509 -noout -modulus -in "$crt_file" | openssl md5 > /tmp/crt.md5 || ! openssl rsa -noout -modulus -in "$key_file" | openssl md5 > /tmp/key.md5 || ! diff /tmp/crt.md5 /tmp/key.md5 > /dev/null; then
    status critical "Certificate and key do not match."
    exit 1
fi

# Check certificate expiry
expiry_date=$(openssl x509 -enddate -noout -in "$crt_file" | cut -d= -f2)
expiry_seconds=$(date -d "$expiry_date" +%s)
current_seconds=$(date +%s)
days_left=$(( (expiry_seconds - current_seconds) / 86400 ))

if (( days_left > 60 )); then
    status ok "Certificate is valid for more than 60 days. Expiry date: $expiry_date"
elif (( days_left > 30 )); then
    status warning "Certificate is valid for more than 30 days. Expiry date: $expiry_date"
else
    status critical "Certificate is valid for less than 30 days. Expiry date: $expiry_date"
fi

# Prompt user to update certificates
read -p "Would you like to update the certificates? (y/n): " update_certs
if [[ "$update_certs" != "y" ]]; then
    status info "No updates made to certificates."
    exit 0
fi

# Ask user for the source of the new certificates, default to local
read -p "Would you like to fetch the certificates from a remote server (TrueNAS) or use local files? (remote/local, default: local): " cert_source
cert_source=${cert_source:-local}

if [[ "$cert_source" == "remote" ]]; then
    # Ask for the secrets file location
    read -p "Enter the directory where the secrets file is located (default: /home/$SUDO_USER): " secrets_dir
    secrets_dir=${secrets_dir:-/home/$SUDO_USER}
    secrets_file="$secrets_dir/secrets.env"

    # Check if the secrets file exists
    if [[ ! -f "$secrets_file" ]]; then
        status warning "Secrets file not found. Creating a new one."
        touch "$secrets_file"
        chmod 600 "$secrets_file"
        status ok "Secrets file created at $secrets_file."
    fi

    # Check for required variables in the secrets file
    source "$secrets_file"

    # Prompt user to define variables if they are not set
    while [[ -z "$REMOTE_SERVER" ]]; do
        read -p "Enter the remote server (e.g., user@truenas-server): " REMOTE_SERVER
        if [[ -z "$REMOTE_SERVER" ]]; then
            status warning "Remote server cannot be blank. Please enter a valid remote server."
        else
            echo "REMOTE_SERVER=\"$REMOTE_SERVER\"" >> "$secrets_file"
        fi
    done

    while [[ -z "$API_TOKEN" || ${#API_TOKEN} -lt 20 ]]; do
        read -s -p "Enter the API token (at least 20 characters): " API_TOKEN
        echo
        if [[ -z "$API_TOKEN" || ${#API_TOKEN} -lt 20 ]]; then
            status warning "API token cannot be blank and must be at least 20 characters. Please enter a valid API token."
        else
            echo "API_TOKEN=\"$API_TOKEN\"" >> "$secrets_file"
        fi
    done

    # Inform user about the location of the certificate name
    echo "The certificate name can be found under 'Certificates' in the TrueNAS UI, labeled as 'name: nameofcert'."

    # Prompt user for the certificate name
    while [[ -z "$cert_name" ]]; do
        read -p "Enter the certificate name: " cert_name
        if [[ -z "$cert_name" ]]; then
            status warning "Certificate name cannot be blank. Please enter a valid certificate name."
        fi
    done

    # Set default certificate path on the remote server
    CERT_PATH="/etc/certificates"
    CERT_FILE="${CERT_PATH}/${cert_name}.crt"
    KEY_FILE="${CERT_PATH}/${cert_name}.key"

    # Prompt user to confirm or change the certificate path
    read -p "Enter the certificate path on the remote server (default: $CERT_PATH): " user_cert_path
    CERT_PATH=${user_cert_path:-$CERT_PATH}
    CERT_FILE="${CERT_PATH}/${cert_name}.crt"
    KEY_FILE="${CERT_PATH}/${cert_name}.key"
    echo "CERT_PATH=\"$CERT_PATH\"" >> "$secrets_file"
    echo "CERT_FILE=\"$CERT_FILE\"" >> "$secrets_file"
    echo "KEY_FILE=\"$KEY_FILE\"" >> "$secrets_file"

    # Fetch the certificate using the API
    curl -H "Authorization: Bearer ${API_TOKEN}" \
        "https://${REMOTE_SERVER}/api/v1.0/certificates/${cert_name}" \
        -o "${CERT_FILE}"

    status ok "Certificate fetched and saved to ${CERT_FILE}."

    # Test the certificate connection using the API
    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${API_TOKEN}" \
        "https://${REMOTE_SERVER}/api/v1.0/certificates/${cert_name}")

    if [[ "$response" -eq 200 ]]; then
        status ok "Certificate connection test successful."
    else
        status critical "Certificate connection test failed with HTTP status code $response."
        exit 1
    fi

    new_crt_file="$CERT_FILE"
    new_key_file="$KEY_FILE"

else
    # Ask user for new certificate and key file locations
    read -p "Enter the directory where the new .crt and .key files are located (default: /home/$SUDO_USER): " new_cert_dir
    new_cert_dir=${new_cert_dir:-/home/$SUDO_USER}

    # List available .crt files in the directory
    crt_files=($(ls "$new_cert_dir"/*.crt 2>/dev/null))
    if [[ ${#crt_files[@]} -eq 0 ]]; then
        status critical "No .crt files found in $new_cert_dir."
        exit 1
    fi

    echo "Available .crt files:"
    for i in "${!crt_files[@]}"; do
        echo "$((i+1))) ${crt_files[$i]}"
    done

    # Prompt user to select a .crt file
    read -p "Select the number of the .crt file to use (default is 1): " crt_index
    crt_index=${crt_index:-1}
    crt_index=$((crt_index-1))

    if [[ ! "$crt_index" =~ ^[0-9]+$ ]] || [[ "$crt_index" -ge ${#crt_files[@]} ]]; then
        status critical "Invalid selection."
        exit 1
    fi

    new_crt_file="${crt_files[$crt_index]}"
    new_key_file="${new_crt_file%.crt}.key"

    # Check if the new key file exists
    if [[ ! -f "$new_key_file" ]]; then
        status warning "Corresponding .key file not found for $new_crt_file."

        # Search for key files in the directory
        key_files=($(ls "${new_crt_file%/*}"/*.key 2>/dev/null))
        if [[ ${#key_files[@]} -eq 0 ]]; then
            status critical "No .key files found in the directory."
            exit 1
        fi

        echo "Available .key files:"
        for i in "${!key_files[@]}"; do
            echo "$((i+1))) ${key_files[$i]}"
        done

        # Prompt user to select a .key file
        read -p "Select the number of the .key file to use (default is 1): " key_index
        key_index=${key_index:-1}
        key_index=$((key_index-1))

        if [[ ! "$key_index" =~ ^[0-9]+$ ]] || [[ "$key_index" -ge ${#key_files[@]} ]]; then
            status critical "Invalid selection."
            exit 1
        fi

        new_key_file="${key_files[$key_index]}"
        status ok "Using selected key file: $new_key_file"
    fi
fi

# Check if new certificates are valid against each other
if ! openssl x509 -noout -modulus -in "$new_crt_file" | openssl md5 > /tmp/new_crt.md5 || ! openssl rsa -noout -modulus -in "$new_key_file" | openssl md5 > /tmp/new_key.md5 || ! diff /tmp/new_crt.md5 /tmp/new_key.md5 > /dev/null; then
    status critical "New certificate and key do not match."
    exit 1
fi

# Rename existing certificates
date_suffix=$(date +%Y%m%d)
mv "$crt_file" "/etc/cockpit/ws-certs.d/${hostname}_${date_suffix}.crt.old"
mv "$key_file" "/etc/cockpit/ws-certs.d/${hostname}_${date_suffix}.key.old"

# Copy new certificates
cp "$new_crt_file" "$crt_file"
cp "$new_key_file" "$key_file"

# Verify new certificates are copied correctly
if [[ ! -f "$crt_file" || ! -f "$key_file" ]]; then
    status critical "Failed to copy new certificates."
    exit 1
fi

# Restart cockpit service
systemctl restart cockpit
if systemctl is-active --quiet cockpit; then
    status ok "Cockpit service restarted successfully."
else
    status critical "Failed to restart Cockpit service."
    exit 1
fi

# Log the update
log_file="/var/log/cockpit_updater_$(date +%Y%m%d).log"
echo "Cockpit certificates updated on $(date)" >> "$log_file"
ln -sf "$log_file" /var/log/cockpit_updater.log

status ok "Certificate update process completed successfully."

#==============================================================================
# Change Log
#==============================================================================
# [December 30, 2024] - Initial version created.
# [December 31, 2024] - Added support for fetching certificates from TrueNAS.
# [December 31, 2024] - Added support for testing certificate connections using the API.
# [December 31, 2024] - Added support for checking if certificates are valid against each other.
# [December 31, 2024] - Added support for checking certificate expiry.
# [December 31, 2024] - Added support for updating certificates from local files.
# [December 31, 2024] - Added support for creating and managing a secrets file.
# [December 31, 2024] - Added support for prompting user input for remote server, API token, and certificate name.
# [December 31, 2024] - Added support for restarting the Cockpit service after updating certificates.