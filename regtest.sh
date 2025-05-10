#!/usr/bin/env bash
#
# utility script to run and command regtest services
#

set -e  # Terminate script if a command fails

# Default settings
DEFAULT_COMPOSE_FILE="compose.yaml"
INITIAL_BLOCKS=103

# Initialize variables
COMPOSE_FILE=""
NAME="./$(basename "$0")"

#
# Utility functions
#

_die() {
    echo "ERR: $*" >&2
    echo "Checking bitcoind logs for more details:"
    $COMPOSE logs bitcoind
    exit 1
}

_check_port() {
    local port=$1
    case "$(uname)" in
        "Linux")
            ss -ltn | grep -q ":$port " && return 0 || return 1
            ;;
        "Darwin")
            lsof -i "tcp:${port}" -sTCP:LISTEN -t >/dev/null 2>&1 && return 0 || return 1
            ;;
        *)
            _die "Unsupported OS for port check"
            ;;
    esac
}

_wait_for_service() {
    local service=$1
    local grep_pattern=$2
    local max_attempts=${3:-60}
    local attempt=1

    echo "Waiting for $service to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if $COMPOSE logs $service | grep -q "$grep_pattern"; then
            echo "$service is ready!"
            return 0
        fi
        echo "Waiting for $service ($attempt/$max_attempts)..."
        sleep 1
        ((attempt++))
    done
    _die "$service did not become ready in time"
}

#
# Service management functions
#

_start_services() {
    _stop_services
    
    # Clean and create data directories
    rm -rf data{core,index,ldk0,ldk1,ldk2}
    mkdir -p data{core,index,ldk0,ldk1,ldk2}
    
    # Verify data directories are writable
    touch datacore/testfile || _die "data directory is not writable"
    rm datacore/testfile
    
    # Check if required ports are available
    EXPOSED_PORTS=(3000 50001)
    for port in "${EXPOSED_PORTS[@]}"; do
        if _check_port $port; then
            _die "Port $port is already in use. Please free the port and try again."
        fi
    done
    
    # Start services
    $COMPOSE up -d
    
    # Wait for bitcoind to be fully ready
    _wait_for_service bitcoind "Bound to"
    
    # Wait for bitcoind RPC to be available
    until $BITCOIN_CLI getblockchaininfo >/dev/null 2>&1; do
        echo "Waiting for bitcoind RPC to be available..."
        sleep 1
    done
    
    echo "Preparing bitcoind wallet..."
    
    # Check if the wallet already exists
    wallet_list_output=$($BITCOIN_CLI listwallets)
    
    if ! echo "$wallet_list_output" | grep -q "miner"; then
        if ! $BITCOIN_CLI createwallet miner >/dev/null; then
            _die "Failed to create wallet 'miner'"
        fi
        echo "Created wallet 'miner'"
    else
        echo "Wallet 'miner' already exists"
    fi
    
    # Verify wallet is accessible
    if ! $BITCOIN_CLI -rpcwallet=miner getwalletinfo >/dev/null; then
        _die "Wallet 'miner' is not accessible"
    fi
    
    # Generate initial blocks
    _mine $INITIAL_BLOCKS
    
    # Wait for electrs to be ready
    _wait_for_service electrs "finished full compaction"
    
    echo "Bitcoind and wallet ready"
}

_stop_services() {
    $COMPOSE down --remove-orphans
    rm -rf data{core,index,ldk0,ldk1,ldk2}
}

#
# Bitcoin operations
#

_mine() {
    local num_blocks=$1
    [ -n "$num_blocks" ] || _die "Number of blocks required for mining"
    echo "Mining $num_blocks block(s)..."
    $BITCOIN_CLI -rpcwallet=miner -generate $num_blocks >/dev/null
    echo "Mined $num_blocks block(s)"
}

_fund() {
    local address="$1"
    [ -n "$address" ] || _die "Destination address required"
    
    echo "Funding address $address with 1 BTC..."
    if ! $BITCOIN_CLI -rpcwallet=miner sendtoaddress "$address" 1; then
        _die "Failed to send funds to $address"
    fi
    
    # Mine a block to confirm the transaction
    _mine 1
    echo "Successfully funded $address with 1 BTC"
}

_sendtoaddress() {
    local address="$1"
    local amount="$2"
    [ -n "$address" ] || _die "Address is required"
    [ -n "$amount" ] || _die "Amount is required"
    
    echo "Sending $amount BTC to $address..."
    if ! $BITCOIN_CLI -rpcwallet=miner sendtoaddress "$address" "$amount"; then
        _die "Failed to send $amount BTC to $address"
    fi
    echo "Successfully sent $amount BTC to $address"
}

_help() {
    cat << EOF
$NAME [-h|--help] [-f <compose-file>]
    Show this help message

$NAME [-f <compose-file>] start
    Specify Docker Compose file and start services,
    create bitcoind wallet used for mining,
    generate initial blocks

$NAME stop
    Stop services and clean up

$NAME mine <blocks>
    Mine the requested number of blocks

$NAME fund <address>
    Fund the requested address with 1 BTC

$NAME sendtoaddress <address> <amount>
    Send to a Bitcoin address

Options:
    -f, --compose-file <file>    Specify a Docker Compose file (default: $DEFAULT_COMPOSE_FILE)
EOF
}

#
# Parse command line arguments
#

# Process options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            _help
            exit 0
            ;;
        -f|--compose-file)
            if [ -n "$2" ]; then
                COMPOSE_FILE="$2"
                shift 2
            else
                _die "Option $1 requires an argument."
            fi
            ;;
        start|stop|mine|fund|sendtoaddress)
            break
            ;;
        *)
            _die "Unsupported argument \"$1\""
            ;;
    esac
done

# Set compose file, prefer specific argument over environment variable
COMPOSE_FILE=${COMPOSE_FILE:-${COMPOSE_FILE:-$DEFAULT_COMPOSE_FILE}}

# Set up command prefix
COMPOSE="docker-compose -f $COMPOSE_FILE"
if ! $COMPOSE version >/dev/null 2>&1; then
    _die "Could not call docker compose (hint: install docker compose plugin)"
fi
BITCOIN_CLI="$COMPOSE exec -u blits bitcoind bitcoin-cli -regtest"

#
# Command execution
#

case "$1" in
    start)
        _start_services
        ;;
    stop)
        _stop_services
        ;;
    mine)
        [ -n "$2" ] || _die "Number of blocks required for mine command"
        _mine "$2"
        ;;
    fund)
        [ -n "$2" ] || _die "Address required for fund command"
        _fund "$2"
        ;;
    sendtoaddress)
        [ -n "$2" ] || _die "Address required for sendtoaddress command"
        [ -n "$3" ] || _die "Amount required for sendtoaddress command"
        _sendtoaddress "$2" "$3"
        ;;
    *)
        _help
        exit 1
        ;;
esac

exit 0