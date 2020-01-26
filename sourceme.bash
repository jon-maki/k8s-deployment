#!/bin/bash

# Get the absolute path to the script dir
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# The bins dir includes all of the binary dependencies and will be added to the user's PATH
BINS_DIR="$SCRIPT_DIR/bin"

# Export the path to include the bins dir
export PATH="$BINS_DIR:$PATH" 

# The RKE cluster configuration file declaritively describes our cluseter
RKE_CLUSTER_CONFIG="$SCRIPT_DIR/cluster.yml"

# Export the RKE_CONFIG variable so we can use rke from any location
export RKE_CONFIG="$RKE_CLUSTER_CONFIG"

# RKE will generate the KUBECONFIG we need to talk to our cluster and store it in 
# this directory.
RKE_KUBECONFIG="$SCRIPT_DIR/kube_config_cluster.yml"

# Export the KUBECONFIG variable for kubectl and other tooling
export KUBECONFIG="$RKE_KUBECONFIG"

# Set up a convenient alias k->kubectl
alias k=kubectl

# Set up bash completion for kubectl and our "k" alias
source <(kubectl completion bash)
source <(kubectl completion bash | sed "s/kubectl/k/g")

# Check to see if the cluster is running already
# This command will run locally and attempt to contact the running cluster. It returns
# non-zero if it fails to contact the cluster.
if ! rke version; then
    echo "Starting cluster install..."

    # Export "USE_EXISTING_NFS_SERVER" to skip running a local version of the NFS server.
    # You will need to provide the address of the server as well as the path to the 
    # exported directory. 
    # To use an existing NFS server, you will need to export the following environment 
    # variables:
    # USE_EXISTING_NFS_SERVER=1
    # NFS_ADDRESS=<NFS SERVER IP ADDRESS> 
    # NFS_DIRECTORY=</path/on/nfs> 
    if [ -z "${USE_EXISTING_NFS_SERVER}" ]; then
        # Check to see if the local NFS server is already running and start it up if not
        # The NFS server is used as the persistent storage backend for our local cluster
        if [ ! "$(docker ps -q -f name=nfs-server)" ]; then
            # If the container has been running and is exited, clean it up
            if [ "$(docker ps -aq -f status=exited -f name=nfs-server)" ]; then
                docker rm nfs-server
            fi

            # Create the NFS directory if it does not exist
            if [ ! -d /opt/nfs ]; then
                sudo mkdir -p /opt/nfs
                sudo chmod 777 /opt/nfs
            fi

            # Load the required kernel modules
            sudo modprobe nfs
            sudo modprobe nfsd
            sudo modprobe rpcsec_gss_krb5

            # Run the local nfs server
            docker run \
              -v /opt/nfs:/nfs \
              -e NFS_EXPORT_0='/nfs *(rw,sync,no_subtree_check)' \
              --privileged \
              -p 2049:2049 \
              -d \
              --name nfs-server \
              erichough/nfs-server:2.2.1
        fi
    fi

    # Grab the IP address of the NFS server from the environment or from the 
    # docker-assigned IP. We'll use this later when configuring our cluster 
    # storage provider
    nfs_address="${NFS_ADDRESS:=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nfs-server)}"
    echo "NFS server is serving at $nfs_address:2049."

    # Grab the exported NFS directory from the environment or default to our local 
    # NFS directory. We'll use this later when configuring our cluster storage provider.
    nfs_directory="${NFS_DIRECTORY:=/nfs}"
    echo "NFS server directory is $nfs_directory"

    # Generate an RKE cluster configuration if it doesn't already exist
    if [ ! -f "$RKE_CLUSTER_CONFIG" ];then
        echo "RKE cluster configuration file is missing. Generating one now..."

        # Use `rke config` to prompt for required configuration values
        rke config

        # We intend on using traefik as our ingress provider, so update the cluster config
        # to explicitly remove the ingress provider
        yq write -i cluster.yml ingress.provider "none" 
    fi

    
    echo "Starting cluster now!"

    # This command starts up the kubernetes cluster as described in cluster.yml
    rke up

    # Check to see if we are up and running correctly by running `rke version` again
    if ! rke version; then
        echo "Something went wrong while installing the cluster. Aborting!"
        return
    fi

    # Annoyingly, the kubernetes metrics server deploys with a imagePullPolicy set to 
    # "Always". This breaks down in offline environments. The following command is a 
    # bit of a hack to set the pull policy to "IfNotPresent" and re-apply it to the
    # cluster.
    kubectl get -n kube-system deployment.apps/metrics-server -o yaml | 
      yq write - spec.template.spec.containers[*].imagePullPolicy "IfNotPresent" |
      kubectl apply -f -

    # Install metallb. You can choose between layer2 mode and bgp mode. 
    # If you want bgp mode, you will need to modify the configuration file located at:
    #   ./deploy/kustomize/metallb/overlays/bgp/configmap.yaml
    # to set up your BGP peering correctly. This script assumes you have already 
    # done that and uses kustomize to build and install metallb using the provided 
    # configuration. It defaults to layer2 mode, which is the most useful for offline
    # clusters.
    # To use metallb in bgp mode, you will need to export the following environment 
    # variable:
    # USE_BGP_MODE_METALLB=1
    if [ -z "${USE_BGP_MODE_METALLB}" ]; then
        kustomize build "$SCRIPT_DIR/deploy/kustomize/metallb/overlays/layer2" |
          kubectl apply -f -
    else
        kustomize build "$SCRIPT_DIR/deploy/kustomize/metallb/overlays/bgp" |
          kubectl apply -f - 
    fi

    # Install traefik.
    kustomize build "$SCRIPT_DIR/deploy/kustomize/traefik/overlays/production" |
      kubectl apply -f -

    # Install nfs-client-provisioner. This requires us to do a little magic so we can
    # reference the NFS_ADDRESS and NFS_DIRECTORY variables to point the provisioner
    # at our NFS server. We have to set those values in a few places, which are defined
    # here.
    yq write -i "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/overlays/production/deployment.yaml" \
      spec.template.spec.containers[0].env[0].value "$nfs_address"
    yq write -i "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/overlays/production/deployment.yaml" \
      spec.template.spec.volumes[0].nfs.server "$nfs_address"
    yq write -i "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/overlays/production/deployment.yaml" \
      spec.template.spec.containers[0].env[1].value "$nfs_directory"
    yq write -i "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/overlays/production/deployment.yaml" \
      spec.template.spec.volumes[0].nfs.path "$nfs_directory" 

    kustomize build "$SCRIPT_DIR/deploy/kustomize/nfs-client-provisioner/overlays/production" |
      kubectl apply -f -
fi
