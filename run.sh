#!/bin/sh

source $(pwd)/.env

export GO111MODULE=on
export GOPRIVATE=bitbucket.org/everledger/*

help() {
    local help="
        Usage: run.sh [command]
        commands:

        help                                                                        : this help

        dep install [chaincode_name]                                                : install all go modules as vendor and init go.mod if does not exist yet
        dep update [chaincode_name]                                                 : update all go modules and rerun install
        
        network install                                                             : install all the dependencies and docker images
        network start                                                               : start the blockchain network and initialize it
        network restart                                                             : restart a previously running the blockchain network
        network stop                                                                : stop the blockchain network and remove all the docker containers
        network explore                                                             : run the blockchain explorer user-interface

        channel create [channel_name]                                               : generate channel configuration file
        channel update [channel_name] [org]                                         : update channel with anchor peers
        channel join [channel_name]                                                 : run by a peer to join a channel

        generate cryptos [config_path] [cryptos_path]                               : generate all the crypto keys and certificates for the network
        generate genesis [base_path] [config_path]                                  : generate the genesis block for the ordering service
        generate channeltx [channel_name] [base_path] [config_path] [cryptos_path]  : generate channel configuration files
                           [network_profile] [channel_profile] [org_msp]            

        chaincode test [chaincode_path]                                             : run unit tests
        chaincode build [chaincode_path]                                            : run build and test against the binary file
        chaincode pack [chaincode_path]                                             : create an archive ready for deployment containing chaincode and vendors
        chaincode install [chaincode_name] [chaincode_version] [chaincode_path]     : install chaincode on a peer
        chaincode instantiate [chaincode_name] [chaincode_version] [channel_name]   : instantiate chaincode on a peer for an assigned channel
        chaincode upgrade [chaincode_name] [chaincode_version] [channel_name]       : upgrade chaincode with a new version
        chaincode query [channel_name] [chaincode_name] [data_in_json]              : run query in the format '{\"Args\":[\"queryFunction\",\"key\"]}'
        chaincode invoke [channel_name] [chaincode_name] [data_in_json]             : run invoke in the format '{\"Args\":[\"invokeFunction\",\"key\",\"value\"]}'
        
        benchmark load [jobs] [entries]                                             : run benchmark bulk loading of [entries] per parallel [jobs] against a running network
        "
    echoc "$help" dark cyan
}

check_dependencies() {
    if [ "${1}" == "deploy" ]; then
        type docker >/dev/null 2>&1 || { echoc >&2 "docker required but it is not installed. Aborting." light red; exit 1; }
        type docker-compose >/dev/null 2>&1 || { echoc >&2 "docker-compose required but it is not installed. Aborting." light red; exit 1; }
    elif [ "${1}" == "test" ]; then
        type go >/dev/null 2>&1 || { echoc >&2 "Go binary is missing in your PATH. Running the dockerised version..." light yellow; echo $?; }
    fi
}

# echoc: Prints the user specified string to the screen using the specified colour.
#
# Parameters: ${1} - The string to print
#             ${2} - The intensity of the colour.
#             ${3} - The colour to use for printing the string.
#
#             NOTE: The following color options are available:
#
#                   [0|1]30, [dark|light] black
#                   [0|1]31, [dark|light] red
#                   [0|1]32, [dark|light] green
#                   [0|1]33, [dark|light] yellow
#                   [0|1]34, [dark|light] blue
#                   [0|1]35, [dark|light] purple
#                   [0|1]36, [dark|light] cyan
#
echoc() {
    if [[ ${#} != 3 ]]; then
        echo "usage: ${FUNCNAME} <string> [light|dark] [black|red|green|yellow|blue|pruple|cyan]"
        exit 1
    fi

    local message=${1}

    case $2 in
        dark) intensity=0 ;;
        light) intensity=1 ;;
    esac

    if [[ -z $intensity ]]; then
        echo "${2} intensity not recognised"
        exit 1
    fi

    case $3 in 
        black) colour_code=${intensity}30 ;;
        red) colour_code=${intensity}31 ;;
        green) colour_code=${intensity}32 ;;
        yellow) colour_code=${intensity}33 ;;
        blue) colour_code=${intensity}34 ;;
        purple) colour_code=${intensity}35 ;;
        cyan) colour_code=${intensity}36 ;;
    esac
        
    if [[ -z $colour_code ]]; then
        echo "${1} colour not recognised"
        exit 1
    fi

    colour_code=${colour_code:1}

    # Print out the message
    echo "${message}" | awk '{print "\033['${intensity}';'${colour_code}'m" $0 "\033[1;0m"}'
}

install_network() {
    echoc "========================" dark cyan
	echoc "Installing dependencies" dark cyan
    echoc "========================" dark cyan
    echo
	echoc "Pulling Go docker image" light cyan
	docker pull ${GOLANG_DOCKER_IMAGE}:${GOLANG_DOCKER_TAG}

	__docker_fabric_pull
	__docker_third_party_images_pull
}

__docker_fabric_pull() {
    for image in peer orderer ca ccenv tools; do
        echoc "==> FABRIC IMAGE: $image" light cyan
        echo
        docker pull hyperledger/fabric-$image:${FABRIC_VERSION} || exit 1
        docker tag hyperledger/fabric-$image:${FABRIC_VERSION} hyperledger/fabric-$image:latest
    done
}

__docker_third_party_images_pull() {
    for image in couchdb kafka zookeeper; do
        echoc "==> THIRDPARTY DOCKER IMAGE: $image" light cyan
        echo
        docker pull hyperledger/fabric-$image:$FABRIC_THIRDPARTY_IMAGE_VERSION || exit 1
        docker tag hyperledger/fabric-$image:$FABRIC_THIRDPARTY_IMAGE_VERSION hyperledger/fabric-$image:latest
    done
}

start_network() {
    echoc "========================" dark cyan
	echoc "Starting Fabric network" dark cyan
    echoc "========================" dark cyan
    echo

    # Note: this trick may allow the network to work also in strict-security platform
    rm -rf ./docker.sock 2>/dev/null && ln -sf /var/run ./docker.sock

    if [ ! "${1}" == "-ci" ]; then
        if [ -d "$DATA_PATH" ]; then
            echoc "Found data directory: ${DATA_PATH}" light yellow
            read -p "Do you wish to restart the network and reuse this data? [yes/no] " yn
            case $yn in
                [YyEeSs]* ) 
                    restart_network
                    return 0
                    ;;
                * ) ;;
            esac
        fi

        stop_network

        build_chaincode $CHAINCODE_NAME
        test_chaincode $CHAINCODE_NAME
    fi

	generate_cryptos $CONFIG_PATH $CRYPTOS_PATH
    generate_genesis $BASE_PATH $CONFIG_PATH $CRYPTOS_PATH $CONFIGTX_PROFILE_NETWORK
    generate_channeltx $CHANNEL_NAME $BASE_PATH $CONFIG_PATH $CRYPTOS_PATH $CONFIGTX_PROFILE_NETWORK $CONFIGTX_PROFILE_CHANNEL $ORG_MSP
    
    docker network create ${DOCKER_NETWORK} 2>/dev/null
    
    docker-compose -f ${ROOT}/docker-compose.yaml up -d || exit 1
	
    sleep 5
	
    initialize_network
}

restart_network() {
    echoc "=========================" dark cyan
	echoc "Restarting Fabric network" dark cyan
    echoc "=========================" dark cyan
    echo

    if [ ! -d "$DATA_PATH" ]; then
        echoc "Data directory not found in: ${DATA_PATH}. Run a normal start." light red
        exit 1
    fi
    
    docker-compose -f ${ROOT}/docker-compose.yaml up --force-recreate -d || exit 1

    echoc "The chaincode container will be instantiated automatically once the peer executes the first invoke or query" light yellow
}

stop_network() {
    echoc "===========================" dark cyan
	echoc "Tearing Fabric network down" dark cyan
    echoc "===========================" dark cyan

    docker-compose -f ${ROOT}/docker-compose.yaml down || exit 1

    if [[ $(docker ps | grep "hyperledger/explorer") ]]; then
        stop_explorer
    fi

    echoc "Cleaning docker leftovers containers and images" light green
    docker rm -f $(docker ps -a | awk '($2 ~ /fabric|dev-/) {print $1}') 2>/dev/null
    docker rmi -f $(docker images -qf "dangling=true") 2>/dev/null
    docker rmi -f $(docker images | awk '($1 ~ /^<none>|dev-/) {print $3}') 2>/dev/null

    if [ -d "$DATA_PATH" ]; then
        echoc "!!!!! ATTENTION !!!!!" light red
        echoc "Found data directory: ${DATA_PATH}" light red
		read -p "Do you wish to remove this data? [yes/no] " yn
		case $yn in
			[YyEeSs]* ) rm -rf $DATA_PATH ;;
			* ) return 0
    	esac
    fi
}

initialize_network() {
    echoc "============================" dark cyan
	echoc "Initializing Fabric network" dark cyan
    echoc "============================" dark cyan
    echo

	create_channel $CHANNEL_NAME
	join_channel $CHANNEL_NAME
	update_channel $CHANNEL_NAME $ORG_MSP
	install_chaincode $CHAINCODE_NAME $CHAINCODE_VERSION ${CHAINCODE_NAME}
	instantiate_chaincode $CHAINCODE_NAME $CHAINCODE_VERSION $CHANNEL_NAME
}

start_explorer() {
    echoc "============================" dark cyan
	echoc "Starting Blockchain Explorer" dark cyan
    echoc "============================" dark cyan
    echo

    if [[ ! $(docker ps | grep fabric) ]]; then
        echoc "No Fabric networks running. First launch ./run.sh start" dark red
		exit 1
    fi

    docker-compose -f ${EXPLORER_PATH}/docker-compose.yaml up -d || exit 1

    echoc "Blockchain Explorer default user is admin/adminpw" light yellow
    echoc "Grafana default user is admin/admin" light yellow
}

stop_explorer() {
    echoc "================================" dark cyan
	echoc "Tearing Blockchain Explorer down" dark cyan
    echoc "================================" dark cyan
    echo

    docker-compose -f ${EXPLORER_PATH}/docker-compose.yaml down || exit 1
}

dep_install() {
    __check_chaincode $1
    local chaincode_name="${1}"

    echoc "=======================" dark cyan
    echoc "Installing dependencies" dark cyan
    echoc "=======================" dark cyan
    echo

    cd ${CHAINCODE_PATH}/${chaincode_name} || exit 1
    __init_go_mod install
}

dep_update() {
    __check_chaincode $1
    local chaincode_name="${1}"

    echoc "===================" dark cyan
    echoc "Update dependencies" dark cyan
    echoc "===================" dark cyan
    echo

    cd ${CHAINCODE_PATH}/${chaincode_name} || exit 1
    __init_go_mod update
}

__init_go_mod() {
    if [ ! -f "./go.mod" ]; then
        go mod init
    fi

    rm -rf vendor 2>/dev/null

    if [ "${1}" == "install" ]; then
        go get ./...
    elif [ "${1}" == "update" ]; then
        go get -u=patch ./...
    fi
    
    go mod tidy
    go mod vendor
}

test_chaincode() {
    __check_chaincode $1
    local chaincode_name="${1}"

    echoc "===================" dark cyan
	echoc "Unit test chaincode" dark cyan
    echoc "===================" dark cyan

    if [[ $(check_dependencies test) ]]; then
        (docker run --rm  -v ${CHAINCODE_PATH}:/usr/src/myapp -w /usr/src/myapp/${chaincode_name} -e CGO_ENABLED=0 -e CORE_CHAINCODE_LOGGING_LEVEL=debug ${GOLANG_DOCKER_IMAGE}:${GOLANG_DOCKER_TAG} sh -c "go test ./... -v") || exit 1
    else
	    (cd ${CHAINCODE_PATH}/${chaincode_name} && CORE_CHAINCODE_LOGGING_LEVEL=debug CGO_ENABLED=0 go test ./... -v) || exit 1
    fi

    echoc "Test passed!" light green
}

build_chaincode() {
    __check_chaincode $1
    local chaincode_name="${1}"

    echoc "==================" dark cyan
	echoc "Building chaincode" dakr cyan
    echoc "==================" dark cyan

    if [[ $(check_dependencies test) ]]; then
        (docker run --rm -v ${CHAINCODE_PATH}:/usr/src/myapp -w /usr/src/myapp/${chaincode_name} -e CGO_ENABLED=0 ${GOLANG_DOCKER_IMAGE}:${GOLANG_DOCKER_TAG} sh -c "go build -a -installsuffix nocgo ./... && rm -rf ./${chaincode_name} 2>/dev/null") || exit 1
    else
	    (cd $CHAINCODE_PATH/${chaincode_name} && CGO_ENABLED=0 go build -a -installsuffix nocgo ./... && rm -rf ./${chaincode_name} 2>/dev/null) || exit 1
    fi

    echoc "Build passed!" light green
}

pack_chaincode() {
    type zip >/dev/null 2>&1 || { echoc >&2 "zip required but it is not installed. Aborting." light red; exit 1; }

    __check_chaincode $1
    local chaincode_name="${1}"

    cd $CHAINCODE_PATH/${chaincode_name} >/dev/null 2>&1 || { echoc >&2 "$CHAINCODE_PATH/${chaincode_name} path does not exist" light red; exit 1; }
    __init_go_mod install

    if [ ! -d "${DIST_PATH}" ]; then
        mkdir -p ${DIST_PATH}
    fi

    local timestamp=$(date -u +%s)
    zip -rq ${DIST_PATH}/${chaincode_name}.${timestamp}.zip . || { echoc >&2 "Error creating chaincode archive." light red; exit 1; }

    echoc "Chaincode archive created in: ${DIST_PATH}/${chaincode_name}.${timestamp}.zip" light green
}

__check_chaincode() {
    if [ -z "$1" ]; then
		echoc "Chaincode name missing" dark red
		exit 1
	fi
}

# generate genesis block
# $1: base path
# $2: config path
# $3: cryptos directory
# $4: network profile name
generate_genesis() {
    if [ -z "$1" ]; then
		echoc "Base path missing" dark red
		exit 1
	fi
    if [ -z "$2" ]; then
		echoc "Config path missing" dark red
		exit 1
	fi
    if [ -z "$3" ]; then
		echoc "Crypto material path missing" dark red
		exit 1
	fi
    if [ -z "$4" ]; then
		echoc "Network profile name" dark red
		exit 1
	fi

    local base_path="$1"
    local config_path="$2"
    local channel_dir="${base_path}/channels/orderer-system-channel"
    local cryptos_path="$3"
    local network_profile="$4"

    if [ -d "$channel_dir" ]; then
        echoc "Channel directory ${channel_dir} already exists" light yellow
		read -p "Do you wish to re-generate channel config? [yes/no] " yn
		case $yn in
			[YyEeSs]* ) ;;
			* ) return 0
    	esac
        rm -rf $channel_dir
        mkdir -p $channel_dir
    fi

    echoc "========================" dark cyan
    echoc "Generating genesis block" dark cyan
    echoc "========================" dark cyan
    echo
	echoc "Base path: $base_path" light cyan
	echoc "Config path: $config_path" light cyan
	echoc "Cryptos path: $cryptos_path" light cyan
	echoc "Network profile: $network_profile" light cyan

    # generate genesis block for orderer
	docker run --rm -v ${config_path}/configtx.yaml:/configtx.yaml \
                    -v ${channel_dir}:/channels/orderer-system-channel \
                    -v ${cryptos_path}:/crypto-config \
                    -e FABRIC_CFG_PATH=/ \
                    hyperledger/fabric-tools:${FABRIC_VERSION} \
                    bash -c " \
                        configtxgen -profile $network_profile -channelID orderer-system-channel -outputBlock /channels/orderer-system-channel/genesis_block.pb /configtx.yaml;
                        configtxgen -inspectBlock /channels/orderer-system-channel/genesis_block.pb
                    "
	if [ "$?" -ne 0 ]; then
		echoc "Failed to generate orderer genesis block..." dark red
		exit 1
	fi
}

# generate channel config
# $1: channel_name
# $2: base path
# $3: configtx.yml file path
# $4: cryptos directory
# $5: network profile name
# $6: channel profile name
# $7: org msp
generate_channeltx() {
    if [ -z "$1" ]; then
		echoc "Channel name missing" dark red
		exit 1
	fi
    if [ -z "$2" ]; then
		echoc "Base path missing" dark red
		exit 1
	fi
    if [ -z "$3" ]; then
		echoc "Config path missing" dark red
		exit 1
	fi
    if [ -z "$4" ]; then
		echoc "Crypto material path missing" dark red
		exit 1
	fi
    if [ -z "$5" ]; then
		echoc "Network profile missing" dark red
		exit 1
	fi
    if [ -z "$6" ]; then
		echoc "Channel profile missing" dark red
		exit 1
	fi
    if [ -z "$7" ]; then
		echoc "MSP missing" dark red
		exit 1
	fi

	local channel_name="$1"
    local base_path="$2"
    local config_path="$3"
    local cryptos_path="$4"
    local channel_dir="${base_path}/channels/${channel_name}"
    local network_profile="$5"
    local channel_profile="$6"
    local org_msp="$7"

    if [ -d "$channel_dir" ]; then
        echoc "Channel directory ${channel_dir} already exists" light yellow
		read -p "Do you wish to re-generate channel config? [yes/no] " yn
		case $yn in
			[YyEeSs]* ) ;;
			* ) return 0
    	esac
        rm -rf $channel_dir
        mkdir -p $channel_dir
    fi 

    echoc "=========================" dark cyan
    echoc "Generating channel config" dark cyan
    echoc "=========================" dark cyan
    echo
	echoc "Channel: $channel_name" light cyan
	echoc "Base path: $base_path" light cyan
	echoc "Config path: $config_path" light cyan
	echoc "Cryptos path: $cryptos_path" light cyan
	echoc "Channel dir: $channel_dir" light cyan
	echoc "Network profile: $network_profile" light cyan
	echoc "Channel profile: $channel_profile" light cyan
	echoc "Org MSP: $org_msp" light cyan

	# generate channel configuration transaction
	docker run --rm -v ${config_path}/configtx.yaml:/configtx.yaml \
                    -v ${channel_dir}:/channels/${channel_name} \
                    -v ${cryptos_path}:/crypto-config \
                    -e FABRIC_CFG_PATH=/ \
                    hyperledger/fabric-tools:${FABRIC_VERSION} \
                    bash -c " \
                        configtxgen -profile $channel_profile -outputCreateChannelTx /channels/${channel_name}/${channel_name}_tx.pb -channelID $channel_name /configtx.yaml;
                        configtxgen -inspectChannelCreateTx /channels/${channel_name}/${channel_name}_tx.pb
                    "
	if [ "$?" -ne 0 ]; then
		echoc "Failed to generate channel configuration transaction..." dark red
		exit 1
	fi

	# generate anchor peer transaction
	docker run --rm -v ${config_path}/configtx.yaml:/configtx.yaml \
                    -v ${channel_dir}:/channels/${channel_name} \
                    -v ${cryptos_path}:/crypto-config \
                    -e FABRIC_CFG_PATH=/ \
                    hyperledger/fabric-tools:${FABRIC_VERSION} \
                    configtxgen -profile $channel_profile -outputAnchorPeersUpdate /channels/${channel_name}/${org_msp}_anchors_tx.pb -channelID $channel_name -asOrg $org_msp /configtx.yaml
	if [ "$?" -ne 0 ]; then
		echoc "Failed to generate anchor peer update for $org_msp..." dark red
		exit 1
	fi
}

# generate crypto config
# $1: crypto-config.yml file path
# $2: certificates output directory
generate_cryptos() {
    if [ -z "$1" ]; then
		echoc "Config path missing" dark red
		exit 1
	fi
    if [ -z "$2" ]; then
		echoc "Cryptos path missing" dark red
		exit 1
	fi

    local config_path="$1"
    local cryptos_path="$2"

    echoc "==================" dark cyan
    echoc "Generating cryptos" dark cyan
    echoc "==================" dark cyan
    echo
    echoc "Config path: $config_path" light cyan
    echoc "Cryptos path: $cryptos_path" light cyan

    if [ -d "$cryptos_path" ]; then
        echoc "crypto-config already exists" light yellow
		read -p "Do you wish to remove crypto-config? [yes/no] " yn
		case $yn in
			[YyEeSs]* ) rm -rf $cryptos_path ;;
			* ) ;;
    	esac
    fi

    if [ ! -d "$cryptos_path" ]; then
        mkdir -p $cryptos_path

        # generate crypto material
        docker run --rm -v ${config_path}/crypto-config.yaml:/crypto-config.yaml \
                        -v ${cryptos_path}:/crypto-config \
                        hyperledger/fabric-tools:${FABRIC_VERSION} \
                        cryptogen generate --config=/crypto-config.yaml --output=/crypto-config
        if [ "$?" -ne 0 ]; then
            echoc "Failed to generate crypto material..." dark red
            exit 1
        fi
    fi
    
    # copy cryptos into a shared folder available for client applications (sdk)
    if [ -d "${CRYPTOS_SHARED_PATH}" ]; then
        echoc "Shared crypto-config directory ${CRYPTOS_SHARED_PATH} already exists" light yellow
		read -p "Do you wish to copy the new crypto-config here? [yes/no] " yn
		case $yn in
			[YyEeSs]* ) 
                rm -rf ${CRYPTOS_SHARED_PATH}
            ;;
			* ) return 0
    	esac
    fi
    mkdir -p ${CRYPTOS_SHARED_PATH}
    cp -r ${cryptos_path}/** ${CRYPTOS_SHARED_PATH}
}

create_channel() {
	if [ -z "$1" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local channel_name="$1"

	echoc "Creating channel $channel_name using configuration file $CHANNELS_CONFIG_PATH/$channel_name/${channel_name}_tx.pb" light cyan
	docker exec $CHAINCODE_UTIL_CONTAINER peer channel create -o $ORDERER_ADDRESS -c $channel_name -f $CHANNELS_CONFIG_PATH/$channel_name/${channel_name}_tx.pb --outputBlock $CHANNELS_CONFIG_PATH/$channel_name/${channel_name}.block
}

join_channel() {
 	if [ -z "$1" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local channel_name="$1"

	echoc "Joining channel $channel_name" light cyan
    docker exec $CHAINCODE_UTIL_CONTAINER peer channel join -b $CHANNELS_CONFIG_PATH/${channel_name}/${channel_name}.block
}

update_channel() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local channel_name="$1"
    local org_msp="$2"

	echoc "Updating anchors peers $channel_name using configuration file $CHANNELS_CONFIG_PATH/$channel_name/${org_msp}_anchors.tx" light cyan
	docker exec $CHAINCODE_UTIL_CONTAINER peer channel update -o $ORDERER_ADDRESS -c $channel_name -f $CHANNELS_CONFIG_PATH/${channel_name}/${org_msp}_anchors_tx.pb
}

install_chaincode() {
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local chaincode_name="$1"
	local chaincode_version="$2"
	local chaincode_path="$3"

    echoc "Installing chaincode $chaincode_name version $chaincode_version from path $chaincode_path" light cyan
    docker exec $CHAINCODE_UTIL_CONTAINER peer chaincode install -o $ORDERER_ADDRESS -n $chaincode_name -v $chaincode_version -p ${CHAINCODE_REMOTE_PATH}/${chaincode_path}
}

instantiate_chaincode() {
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local chaincode_name="$1"
	local chaincode_version="$2"
	local channel_name="$3"

    echoc "Instantiating chaincode $chaincode_name version $chaincode_version into channel $channel_name" light cyan
	docker exec $CHAINCODE_UTIL_CONTAINER peer chaincode instantiate -o $ORDERER_ADDRESS -n $chaincode_name -v $chaincode_version -C $channel_name -c '{"Args":[]}'
}

upgrade_chaincode() {
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local chaincode_name="$1"
	local chaincode_version="$2"
	local channel_name="$3"

	build_chaincode $chaincode_name
	test_chaincode $chaincode_name
	install_chaincode $chaincode_name $chaincode_version ${CHAINCODE_REMOTE_PATH}/${chaincode_name}

    echoc "Upgrading chaincode $chaincode_name to version $chaincode_version into channel $channel_name" light cyan
	docker exec $CHAINCODE_UTIL_CONTAINER peer chaincode upgrade -n $chaincode_name -v $chaincode_version -C $channel_name -c '{"Args":[]}'
}

invoke() {
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local channel_name="$1"
	local chaincode_name="$2"
	local request="$3"

	docker exec $CHAINCODE_UTIL_CONTAINER peer chaincode invoke -o $ORDERER_ADDRESS -C $channel_name -n $chaincode_name -c "$request"
}

query() {
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
		echoc "Incorrect usage of $FUNCNAME. Please consult the help: ./run.sh help" dark red
		exit 1
	fi

	local channel_name="$1"
	local chaincode_name="$2"
	local request="$3"

	docker exec $CHAINCODE_UTIL_CONTAINER peer chaincode query -o $ORDERER_ADDRESS -C $channel_name -n $chaincode_name -c "$request"
}

enroll_admin() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Please provide username and password in the format: ./run.sh ca enroll [user] [password]"
        exit 1
    fi

    # type fabric-ca-client >/dev/null 2>&1 || { echo >&2 "I require fabric-ca-client but it is not installed.  Aborting."; exit 1; }

    local admin_user="$1"
    local admin_password="$2"

    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$admin_user/msp ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$admin_user/msp
    fi
    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
        mv $(pwd)/$FABRIC_CA_CERT $FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
    fi

    docker run --rm --env-file uat.env \
    -v $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR:/$FABRIC_CRYPTO_CONFIG_DIR \
    $FABRIC_CA_IMAGE:$FABRIC_CA_IMAGE_TAG \
    sh -c " \
    fabric-ca-client enroll \
        --home /$FABRIC_CRYPTO_CONFIG_DIR \
        --mspdir $FABRIC_ORG/users/$admin_user \
        --url https://$admin_user:$admin_password@$CA_HOST:$CA_PORT \
        --tls.certfiles $FABRIC_ORG/$FABRIC_CA_DIR/$FABRIC_CA_CERT
      "

    # fabric-ca-client enroll \
    #     --home $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR \
    #     --mspdir $FABRIC_ORG/users/$admin_user \
    #     --url https://$admin_user:$admin_password@$CA_HOST:$CA_PORT \
    #     --tls.certfiles $FABRIC_ORG/$FABRIC_CA_DIR/$FABRIC_CA_CERT
}

register_user() {
    # type fabric-ca-client >/dev/null 2>&1 || { echo >&2 "I require fabric-ca-client but it is not installed.  Aborting."; exit 1; }
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Please provide username and password in the format: register_user [username] [password]"
        exit 1
    fi

    local user="$1"
    local password="$2"

    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/msp ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/msp
    fi
    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
        mv $(pwd)/$FABRIC_CA_CERT $FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
    fi

    docker run --rm --env-file uat.env \
    -v $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR:/$FABRIC_CRYPTO_CONFIG_DIR \
    $FABRIC_CA_IMAGE:$FABRIC_CA_IMAGE_TAG \
    sh -c " \
        fabric-ca-client register \
            --home /$FABRIC_CRYPTO_CONFIG_DIR \
            --mspdir $FABRIC_ORG/users/$user_DIR \
            --url https://$CA_HOST:$CA_PORT \
            --tls.certfiles $FABRIC_ORG/$FABRIC_CA_DIR/$FABRIC_CA_CERT \
            --id.name $user \
            --id.secret $password  \
            --id.affiliation $FABRIC_MEMBER_MSPID \
            --id.attrs $user_ATTRS --id.type user
         "

    # fabric-ca-client register \
    #     --home $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR \
    #     --mspdir $FABRIC_ORG/users/$admin_user/msp \
    #     --url https://$CA_HOST:$CA_PORT \
    #     --tls.certfiles $FABRIC_CA_CERT \
    #     --id.name $user \
    #     --id.secret $password  \
    #     --id.affiliation $FABRIC_MEMBER_MSPID \
    #     --id.attrs $user_ATTRS --id.type client
}

enroll_user() {
    type fabric-ca-client >/dev/null 2>&1 || { echo >&2 "I require fabric-ca-client but it is not installed.  Aborting."; exit 1; }

    user="$1"
    password="$2"

    if [ -z "$user" ] || [ -z "$user" ]; then
        echo "Please provide username and password in the format: enroll_user [username] [password]"
        exit 1
    fi

    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/msp ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/msp
    fi
    if [ ! -d $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR ]; then
        mkdir -p $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
        mv $(pwd)/$FABRIC_CA_CERT $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/$FABRIC_CA_DIR
    fi

    #docker run --rm --env-file uat.env \
    #    -v $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR:/$FABRIC_CRYPTO_CONFIG_DIR \
    #    $FABRIC_CA_IMAGE:$FABRIC_CA_IMAGE_TAG \
    #    sh -c " \
    #    fabric-ca-client enroll \
    #        --home /$FABRIC_CRYPTO_CONFIG_DIR/$user_DIR \
    #        --url https://$user:$password@$CA_HOST:$CA_PORT \
    #        --tls.certfiles $FABRIC_ORG/$FABRIC_CA_DIR/$FABRIC_CA_CERT
    #      "\

    fabric-ca-client enroll \
        --home $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR \
        --mspdir $FABRIC_ORG/users/$user/msp \
        --url https://$user:$password@$CA_HOST:$CA_PORT \
        --tls.certfiles $FABRIC_ORG/$FABRIC_CA_DIR/$FABRIC_CA_CERT

    echo "Renaming user cert file"
    mv $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/signcerts/*.pem $(pwd)/$FABRIC_CRYPTO_CONFIG_DIR/$FABRIC_ORG/users/$user/signcerts/$user@$FABRIC_ORG-cert.pem
}

__exec_jobs() {
    local jobs=$1
    local entries=$2

    if [ -z "$jobs" ]; then
        echo "Provide a number of jobs to run in parallel"
        exit 1
    fi
    if [ -z "$entries" ]; then
        echo "Provide a number of entries per job"
        exit 1
    fi

    echoc "Running in parallel:
    Jobs: $jobs
    Entries: $entries
    " light cyan

    start_time="$(date -u +%s)"
    
    for i in $(seq 1 $jobs); do
        __loader $entries & 
    done

    for job in $(jobs -p); do
        wait $job
    done 

    end_time="$(date -u +%s)"

    elapsed="$(($end_time - $start_time))"
    echoc "Total of $elapsed seconds elapsed for process" light yellow

    echoc "$(( $jobs * $entries )) entries added" light green
}

__loader() {
    export LC_CTYPE=C

    for i in $(seq 1 $1); do 
        key=$(cat /dev/urandom | tr -cd 'A-Z0-9' | fold -w 14 | head -n 1)
        value="$i"

        invoke mychannel mychaincode "{\"Args\":[\"put\",\"${key}\",\"${value}\"]}" &>/dev/null
    done
}

readonly func="$1"
shift

if [ "$func" == "network" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "install" ]; then
        check_dependencies deploy
        install_network
    elif [ "$param" == "start" ]; then
        check_dependencies deploy
        start_network "$@"
    elif [ "$param" == "restart" ]; then
        check_dependencies deploy
        restart_network
    elif [ "$param" == "stop" ]; then
        stop_network
    elif [ "$param" == "explore" ]; then
        check_dependencies deploy
        start_explorer
    else
        help
        exit 1
    fi
elif [ "$func" == "dep" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "install" ]; then
        dep_install "$@"
    elif [ "$param" == "update" ]; then
        dep_update "$@"
    else
        help
        exit 1
    fi
elif [ "$func" == "chaincode" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "install" ]; then
        install_chaincode "$@"
    elif [ "$param" == "instantiate" ]; then
        instantiate_chaincode "$@"
    elif [ "$param" == "upgrade" ]; then
        upgrade_chaincode "$@"
    elif [ "$param" == "test" ]; then
        test_chaincode "$@"
    elif [ "$param" == "build" ]; then
        build_chaincode "$@"
    elif [ "$param" == "pack" ]; then
        pack_chaincode "$@"
    elif [ "$param" == "query" ]; then
        query "$@"
    elif [ "$param" == "invoke" ]; then
        invoke "$@"
    else
        help
        exit 1
    fi
elif [ "$func" == "generate" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "cryptos" ]; then
        generate_cryptos "$@"
    elif [ "$param" == "genesis" ]; then
        generate_genesis "$@"
    elif [ "$param" == "channeltx" ]; then
        generate_channeltx "$@"
    else
        help
        exit 1
    fi
elif [ "$func" == "ca" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "register" ]; then
        register_user "$@"
    elif [ "$param" == "enroll" ]; then
        enroll_user "$@"
    else
        help
        exit 1
    fi
elif [ "$func" == "channel" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "create" ]; then
        create_channel "$@"
    elif [ "$param" == "update" ]; then
        update_channel "$@"
    elif [ "$param" == "join" ]; then
        join_channel "$@"
    else
        help
        exit 1
    fi
elif [ "$func" == "benchmark" ]; then
    readonly param="$1"
    shift
    if [ "$param" == "load" ]; then
        check_dependencies deploy
        __exec_jobs "$@"
    else
        help
        exit 1
    fi
else
    help
    exit 1
fi