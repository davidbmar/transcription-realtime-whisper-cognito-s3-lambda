#!/bin/bash
#
# CloudDrive Cognito Authentication Helper
# Authenticates with Cognito and stores JWT token
#
# Usage: ./auth-helper.sh [email] [password]
#        ./auth-helper.sh --check (check if token is valid)
#        ./auth-helper.sh --refresh (refresh token)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load environment variables
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration
USER_POOL_ID="${COGNITO_USER_POOL_ID:-us-east-2_MREOwTQNv}"
CLIENT_ID="${COGNITO_USER_POOL_CLIENT_ID:-43ocivrrit30vs0l0ujaj4qsj5}"
REGION="${AWS_REGION:-us-east-2}"
TOKEN_DIR="$HOME/.clouddrive"
TOKEN_FILE="$TOKEN_DIR/token"
REFRESH_TOKEN_FILE="$TOKEN_DIR/refresh_token"
USER_INFO_FILE="$TOKEN_DIR/user_info"

# Create token directory
mkdir -p "$TOKEN_DIR"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if token exists and is valid
check_token() {
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log_warn "No token found"
        return 1
    fi

    local token=$(cat "$TOKEN_FILE")

    # Parse JWT payload (decode base64)
    local payload=$(echo "$token" | cut -d'.' -f2)

    # Add padding if needed
    local padded_payload="$payload$(printf '%*s' $((${#payload} % 4)) '' | tr ' ' '=')"

    # Decode base64
    local decoded=$(echo "$padded_payload" | base64 -d 2>/dev/null || echo "{}")

    # Extract expiration
    local exp=$(echo "$decoded" | jq -r '.exp // 0' 2>/dev/null || echo "0")
    local now=$(date +%s)

    if [[ $exp -gt $now ]]; then
        local remaining=$((exp - now))
        local hours=$((remaining / 3600))
        local minutes=$(((remaining % 3600) / 60))
        log_success "Token is valid (expires in ${hours}h ${minutes}m)"

        # Show user info
        if [[ -f "$USER_INFO_FILE" ]]; then
            local email=$(cat "$USER_INFO_FILE" | jq -r '.email // "unknown"')
            local user_id=$(cat "$USER_INFO_FILE" | jq -r '.sub // "unknown"')
            log_info "Logged in as: $email"
            log_info "User ID: $user_id"
        fi

        return 0
    else
        log_warn "Token has expired"
        return 1
    fi
}

# Authenticate with username and password
authenticate() {
    local email="$1"
    local password="$2"

    log_info "Authenticating with Cognito..."

    # Use AWS CLI to authenticate
    local auth_response=$(aws cognito-idp initiate-auth \
        --auth-flow USER_PASSWORD_AUTH \
        --client-id "$CLIENT_ID" \
        --region "$REGION" \
        --auth-parameters "USERNAME=$email,PASSWORD=$password" \
        2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Authentication failed"
        log_error "$auth_response"
        return 1
    fi

    # Extract tokens
    local id_token=$(echo "$auth_response" | jq -r '.AuthenticationResult.IdToken')
    local access_token=$(echo "$auth_response" | jq -r '.AuthenticationResult.AccessToken')
    local refresh_token=$(echo "$auth_response" | jq -r '.AuthenticationResult.RefreshToken')

    if [[ "$id_token" == "null" ]] || [[ -z "$id_token" ]]; then
        log_error "Failed to get ID token"
        return 1
    fi

    # Save tokens
    echo "$id_token" > "$TOKEN_FILE"
    echo "$refresh_token" > "$REFRESH_TOKEN_FILE"

    # Extract and save user info from token
    local payload=$(echo "$id_token" | cut -d'.' -f2)
    local padded_payload="$payload=$(printf '%*s' $((${#payload} % 4)) '' | tr ' ' '=')"
    local decoded=$(echo "$padded_payload" | base64 -d 2>/dev/null)

    echo "$decoded" > "$USER_INFO_FILE"

    local user_email=$(echo "$decoded" | jq -r '.email // "unknown"')
    local user_id=$(echo "$decoded" | jq -r '.sub // "unknown"')

    log_success "Authentication successful!"
    log_info "Email: $user_email"
    log_info "User ID: $user_id"
    log_info "Token saved to: $TOKEN_FILE"

    return 0
}

# Refresh token using refresh token
refresh_token() {
    if [[ ! -f "$REFRESH_TOKEN_FILE" ]]; then
        log_error "No refresh token found. Please login again."
        return 1
    fi

    log_info "Refreshing authentication token..."

    local refresh=$(cat "$REFRESH_TOKEN_FILE")

    local auth_response=$(aws cognito-idp initiate-auth \
        --auth-flow REFRESH_TOKEN_AUTH \
        --client-id "$CLIENT_ID" \
        --region "$REGION" \
        --auth-parameters "REFRESH_TOKEN=$refresh" \
        2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Token refresh failed"
        log_error "$auth_response"
        return 1
    fi

    # Extract new tokens
    local id_token=$(echo "$auth_response" | jq -r '.AuthenticationResult.IdToken')
    local access_token=$(echo "$auth_response" | jq -r '.AuthenticationResult.AccessToken')

    if [[ "$id_token" == "null" ]] || [[ -z "$id_token" ]]; then
        log_error "Failed to get new ID token"
        return 1
    fi

    # Save new token
    echo "$id_token" > "$TOKEN_FILE"

    log_success "Token refreshed successfully!"

    return 0
}

# Interactive login
interactive_login() {
    log_info "CloudDrive Login"
    log_info "================"

    read -p "Email: " email
    read -sp "Password: " password
    echo ""

    authenticate "$email" "$password"
}

# Main execution
main() {
    local command="${1:-login}"

    case "$command" in
        --check)
            check_token
            ;;
        --refresh)
            refresh_token
            ;;
        --logout)
            log_info "Logging out..."
            rm -f "$TOKEN_FILE" "$REFRESH_TOKEN_FILE" "$USER_INFO_FILE"
            log_success "Logged out successfully"
            ;;
        --help)
            echo "CloudDrive Authentication Helper"
            echo ""
            echo "Usage:"
            echo "  $0                     Interactive login"
            echo "  $0 <email> <password>  Login with credentials"
            echo "  $0 --check             Check if token is valid"
            echo "  $0 --refresh           Refresh expired token"
            echo "  $0 --logout            Remove all tokens"
            echo "  $0 --help              Show this help"
            ;;
        *)
            if [[ $# -eq 0 ]]; then
                # Interactive login
                interactive_login
            elif [[ $# -eq 2 ]]; then
                # Login with provided credentials
                authenticate "$1" "$2"
            else
                log_error "Invalid arguments. Use --help for usage."
                exit 1
            fi
            ;;
    esac
}

# Run main
main "$@"
