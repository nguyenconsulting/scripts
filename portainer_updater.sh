#!/bin/bash

#==============================================================================
# Portainer Certificate Updater for RaspbianPi v0.1
# Created: [December 31, 2024]
# Last Modified: [December 31, 2024]
#==============================================================================

# Configuration
DOCKER_CONTAINER_NAME="portainer"
DEFAULT_CERT_DIR="/home/$SUDO_USER"
PORTAINER_CERT_DIR=""
CERT_FILE=""
KEY_FILE=""

# Main header function
main_header() {
    echo -e "\e[34m============================================\e[0m"  # Blue
    echo -e "\e[32m Portainer Certificate Updater for RaspbianPi  \e[0m"  # Green
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

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    status critical "This script must be run as root or with sudo."
    exit 1
fi

main_header

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    status warning "Docker is not installed."
    read -p "Would you like to install Docker? (y/n): " install_docker
    if [[ "$install_docker" == "y" ]]; then
        apt-get update && apt-get install -y docker.io
        status ok "Docker installed successfully."
    else
        status critical "Docker is required for this script to run."
        exit 1
    fi
else
    status ok "Docker is already installed."
fi

# Check if Portainer container is running
if ! docker ps -a --format '{{.Names}}' | grep -iq "$DOCKER_CONTAINER_NAME"; then
    status warning "Portainer container not found."
    read -p "Enter the name of the Docker container: " DOCKER_CONTAINER_NAME
    if [[ -z "$DOCKER_CONTAINER_NAME" ]]; then
        status critical "Docker container name cannot be blank."
        exit 1
    fi
fi

# Check if Portainer is installed
if ! docker ps -a --format '{{.Names}}' | grep -iq "$DOCKER_CONTAINER_NAME"; then
    status warning "Portainer is not installed."
    read -p "Would you like to install Portainer? (y/n): " install_portainer
    if [[ "$install_portainer" == "y" ]]; then
        docker volume create portainer_data
        docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce
        status ok "Portainer installed successfully."
    else
        status critical "Portainer is required for this script to run."
        exit 1
    fi
else
    status ok "Portainer is already installed."
fi

# Determine the Portainer certificate directory
PORTAINER_CERT_DIR=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Source }}{{ end }}{{ end }}' $DOCKER_CONTAINER_NAME)/certs
CERT_FILE="$PORTAINER_CERT_DIR/cert.pem"
KEY_FILE="$PORTAINER_CERT_DIR/key.pem"

# Check TLS certificate
if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
    EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_TIMESTAMP=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 ))

    status info "Certificate expiry date: $EXPIRY_DATE"

    if [[ $DAYS_LEFT -gt 31 ]]; then
        status ok "Certificate is valid for more than 31 days."
    elif [[ $DAYS_LEFT -gt 7 ]]; then
        status warning "Certificate is valid for more than 7 days but less than 31 days."
    else
        status critical "Certificate is valid for 7 days or less."
    fi
else
    status critical "Certificate files not found."
    exit 1
fi

# Ask user if they wish to replace the certificate
read -p "Would you like to replace the certificate? (y/n): " replace_cert
if [[ "$replace_cert" != "y" ]]; then
    status info "Certificate replacement skipped."
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
        -o "${DEFAULT_CERT_DIR}/${cert_name}.crt"
    curl -H "Authorization: Bearer ${API_TOKEN}" \
        "https://${REMOTE_SERVER}/api/v1.0/certificates/${cert_name}/key" \
        -o "${DEFAULT_CERT_DIR}/${cert_name}.key"

    new_crt_file="${DEFAULT_CERT_DIR}/${cert_name}.crt"
    new_key_file="${DEFAULT_CERT_DIR}/${cert_name}.key"
else
    # Ask user for the new certificate and key file paths
    read -p "Enter the path to the new certificate file (default: $DEFAULT_CERT_DIR): " new_crt_file
    new_crt_file=${new_crt_file:-$DEFAULT_CERT_DIR}

    # List available .crt and .pem files in the directory
    crt_files=($(ls "$new_crt_file"/*.{crt,pem} 2>/dev/null))
    if [[ ${#crt_files[@]} -eq 0 ]]; then
        status critical "No .crt or .pem files found in the directory."
        exit 1
    fi

    echo "Available .crt and .pem files:"
    for i in "${!crt_files[@]}"; do
        echo "$((i+1))) ${crt_files[$i]}"
    done

    # Prompt user to select a .crt or .pem file
    read -p "Select the number of the .crt or .pem file to use (default is 1): " crt_index
    crt_index=${crt_index:-1}
    crt_index=$((crt_index-1))

    if [[ ! "$crt_index" =~ ^[0-9]+$ ]] || [[ "$crt_index" -ge ${#crt_files[@]} ]]; then
        status critical "Invalid selection."
        exit 1
    fi

    new_crt_file="${crt_files[$crt_index]}"
    status ok "Using selected certificate file: $new_crt_file"

    # List available .key files in the directory
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

    # Convert .crt and .key files to .pem format if necessary
    if [[ "$new_crt_file" != *.pem ]]; then
        openssl x509 -in "$new_crt_file" -out "$DEFAULT_CERT_DIR/cert.pem"
        new_crt_file="$DEFAULT_CERT_DIR/cert.pem"
        status ok "Converted $new_crt_file to PEM format."
    fi

    if [[ "$new_key_file" != *.pem ]]; then
        openssl rsa -in "$new_key_file" -out "$DEFAULT_CERT_DIR/key.pem"
        new_key_file="$DEFAULT_CERT_DIR/key.pem"
        status ok "Converted $new_key_file to PEM format."
    fi
fi

# Check if new certificates are valid against each other
if ! openssl x509 -noout -modulus -in "$new_crt_file" | openssl md5 > /tmp/new_crt.md5 || ! openssl rsa -noout -modulus -in "$new_key_file" | openssl md5 > /tmp/new_key.md5 || ! diff /tmp/new_crt.md5 /tmp/new_key.md5 > /dev/null; then
    status critical "New certificate and key do not match."
    exit 1
fi

# Backup old certificate
BACKUP_CERT_NAME="cert_$(date -d "$EXPIRY_DATE" +%Y%m%d).bak"
mv "$CERT_FILE" "$PORTAINER_CERT_DIR/$BACKUP_CERT_NAME"
mv "$KEY_FILE" "$PORTAINER_CERT_DIR/$BACKUP_CERT_NAME.key"
status ok "Old certificate backed up as $BACKUP_CERT_NAME and $BACKUP_CERT_NAME.key"

# Replace new certificate and keypair
cp "$new_crt_file" "$CERT_FILE"
cp "$new_key_file" "$KEY_FILE"
chmod 600 "$CERT_FILE"
chmod 600 "$KEY_FILE"
status ok "New certificate and keypair copied."

# Restart Portainer container
docker restart $DOCKER_CONTAINER_NAME
status ok "Portainer container restarted."

status ok "TLS certificate update completed."

#====================================================================================================================================
# Change Log
#====================================================================================================================================
# [December 31, 2024] [v0.1] 
# - Initial release of Portainer Certificate Updater for RaspbianPi.
# - Added main header function to display script information.
# - Added status function to display messages with different severity levels (info, ok, warning, critical).
# - Added check to ensure the script is run as root.
# - Added check to verify if Docker is installed, with an option to install it if not present.
# - Added configuration variables for Docker container name, new certificate path, new key path, and Portainer certificate directory.
