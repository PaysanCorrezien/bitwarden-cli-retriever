#!/usr/bin/env bash

# Usage: ./retrieve.sh [options] <item_name>
# Requirements: jq, bw-cli

# NOTE: this is a simple script to retrieve passwords from Bitwarden CLI
# SUPPORT only totp and normal master password for now
# this is usefull for automation and CI/CD, this can be used to only retrieve the password
# EXAMPLE env file:
# BW_URL="https://vault.bitwarden.com"
# BW_EMAIL="toto@creds.com"
# BW_PASSWORD="my_master_password"
# Variable can be passed by env, or directly because calling the script
# Example: BW_URL="https://vault.bitwarden.com" ./retrieve.sh --config /path/.env password_test

# Function to display help
show_help() {
	echo "Usage: $0 [options] <item_name>"
	echo "Options:"
	echo "  --config <file>   Use config file for credentials, just put \$BW_VARIABLE=value in the file, one per line"
	echo "  --url <url>       Specify Vault URL"
	echo "  --email <email>   Specify email for login"
	echo "  --password <pass> Specify master password"
	echo "  --help            Show this help message"
	echo "If options are not provided, you will be prompted for necessary information."
	echo "Variable match the --arg name, e.g. - url so you can provide them as env variables like \$BW_URL"
	echo "Example: $0 --config config.txt my_password"
	echo "Example: BW_URL="https://vault.bitwarden.eu" $0 --config config.txt my_password"
	echo "Example for automation : secrets=\$( $0 --config /path/.env password_test)"
}

read_config() {
	local config_file=$1
	if [[ -f "$config_file" ]]; then
		while IFS='=' read -r key value; do
			# Remove leading/trailing whitespace and quotes
			key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["\x27]//g' -e 's/["\x27]$//g')
			value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["\x27]//g' -e 's/["\x27]$//g')

			# Convert key to uppercase
			key=$(echo "$key" | tr '[:lower:]' '[:upper:]')

			# Use printf to handle special characters in the value
			printf -v "$key" '%s' "$value"
		done <"$config_file"
	else
		echo "Config file not found: $config_file" >&2
		exit 1
	fi
}

# Function to get value with priority
get_value() {
	local var_name=$1
	local prompt=$2
	local value

	#NOTE:
	# Priority: 1. Environment variable (BW_*)
	#           2. Command line argument
	#           3. Config file
	#           4. User prompt

	if [[ -n "${!var_name}" ]]; then
		value="${!var_name}"
	elif [[ -n "${!2}" ]]; then
		value="${!2}"
	elif [[ -n "${CONFIG_FILE}" && -n "${!var_name}" ]]; then
		value="${!var_name}"
	else
		if [[ "$prompt" == *"password"* ]]; then
			read -s -p "$prompt" value
			echo # Add a newline after the hidden input
		else
			read -p "$prompt" value
		fi
	fi

	echo "$value"
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
	case $1 in
	--config)
		CONFIG_FILE="$2"
		shift
		;;
	--url)
		cli_url="$2"
		shift
		;;
	--email)
		cli_email="$2"
		shift
		;;
	--password)
		cli_password="$2"
		shift
		;;
	--help)
		show_help
		exit 0
		;;
	*) ITEM_NAME="$1" ;;
	esac
	shift
done

# Check if item name is provided
if [[ -z "$ITEM_NAME" ]]; then
	echo "Error: Item name not provided." >&2
	show_help
	exit 1
fi

# Read config if specified
if [[ -n "$CONFIG_FILE" ]]; then
	read_config "$CONFIG_FILE"
fi

# Get values with priority
URL=$(get_value BW_URL "Enter your Vault URL: ")
EMAIL=$(get_value BW_EMAIL "Enter your email: ")
PASSWORD=$(get_value BW_PASSWORD "Enter your master password: ")

# Debug output (remove in production)
echo "Debug: URL=$URL" >&2
echo "Debug: EMAIL=$EMAIL" >&2
echo "Debug: PASSWORD is $(if [ -n "$PASSWORD" ]; then echo "set"; else echo "not set"; fi)" >&2

# Function to extract session key from login output
extract_session_key() {
	grep 'export BW_SESSION=' | cut -d'"' -f2
}

# Configure Bitwarden CLI
bw config server "$URL" >/dev/null 2>&1

# Check login status and log in if necessary
if ! bw login --check >/dev/null 2>&1; then
	LOGIN_OUTPUT=$(bw login "$EMAIL" "$PASSWORD")
	BW_SESSION=$(echo "$LOGIN_OUTPUT" | extract_session_key)
else
	BW_SESSION=$(bw unlock --raw "$PASSWORD")
fi

if [ -z "$BW_SESSION" ]; then
	echo "Failed to obtain a valid session. Please check your credentials." >&2
	exit 1
fi

# Retrieve item
CONTENT=$(bw get item "$ITEM_NAME" --session "$BW_SESSION" 2>/dev/null)
if [ $? -ne 0 ]; then
	echo "Failed to retrieve $ITEM_NAME. Please check the item name." >&2
	bw logout >/dev/null 2>&1
	exit 1
fi

# Extract and output only the relevant information
if echo "$CONTENT" | jq -e '.type == 1' >/dev/null 2>&1; then
	# It's a login item (password)
	echo "$CONTENT" | jq -r '.login.password'
elif echo "$CONTENT" | jq -e '.type == 2' >/dev/null 2>&1; then
	# It's a secure note
	echo "$CONTENT" | jq -r '.notes'
else
	echo "Unknown item type for $ITEM_NAME" >&2
	bw logout >/dev/null 2>&1
	exit 1
fi

# Logout (suppress output)
bw logout >/dev/null 2>&1

# Clear sensitive variables
unset BW_SESSION PASSWORD
