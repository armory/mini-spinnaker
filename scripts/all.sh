#!/bin/bash
set -x
set -e

##### Dev Notes:
# We use `yml` instead of `yaml` for consistency (all service-settings and profiles require `yml`)

# On Linux, we assume we control the whole machine
# On OSX, we minimize impact to non-Spinnaker things

## TODO
# Move metrics server manifests (and see if we need it) - also detect existence
# Figure out nginx vs. traefik (nginx for m4m, traefik for ubuntu?, or use helm?)
# Exclude spinnaker namespace - not doing this
# Update 'public_ip'/'PUBLIC_IP' to 'public/endpoint/PUBLIC_ENDPOINT'
# Fix localhost public ip for m4m

# OOB application(s)
# Refactor all hydrates into a function: copy_and_hydrate


##### Functions
print_help () {
  set +x
  echo "Usage: all.sh"
  echo "               [-o|--oss]                                         : Install Open Source Spinnaker (instead of Armory Spinnaker)"
  echo "               [-P|--public-endpoint <PUBLIC_IP_OR_DNS_ADDRESS>]  : Specify public IP (or DNS name) for instance (rather than detecting using ifconfig.co)"
  echo "               [-B|--base-dir <BASE_DIRECTORY>]                   : Specify root directory to use for manifests"
  set -x
}

install_k3s () {
  # curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--no-deploy=traefik" K3S_KUBECONFIG_MODE=644 sh -
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.0.0" K3S_KUBECONFIG_MODE=644 sh -
}

# Todo: Support multiple installation methods (apt, etc.)
install_git () {
  set +e
  if [[ $(command -v snap >/dev/null; echo $?) -eq 0 ]];
  then
    sudo snap install git
  elif [[ $(command -v apt-get >/dev/null; echo $?) -eq 0 ]];
  then
    sudo apt-get install git -y
  else
    sudo yum install git -y
  fi
  set -e
}

get_metrics_server_manifest () {
# TODO: detect existence and skip if existing
  rm -rf ${BASE_DIR}/manifests/metrics-server
  git clone https://github.com/kubernetes-incubator/metrics-server.git ${BASE_DIR}/metrics-server
}

detect_endpoint () {
  if [[ ! -f ${BASE_DIR}/.hal/public_endpoint ]]; then
    if [[ -n "${PUBLIC_ENDPOINT}" ]]; then
      echo "Using provided public IP ${PUBLIC_ENDPOINT}"
      echo "${PUBLIC_ENDPOINT}" > ${BASE_DIR}/.hal/public_endpoint
    else
      if [[ $(curl -m 1 169.254.169.254 -sSfL &>/dev/null; echo $?) -eq 0 ]]; then
        echo "Detected cloud metadata endpoint; Detecting Public IP Address from ifconfig.co (and storing in ${BASE_DIR}/.hal/public_endpoint):"
        curl -sSfL ifconfig.co | tee ${BASE_DIR}/.hal/public_endpoint
      else
        echo "No cloud metadata endpoint detected, detecting interface IP (and storing in ${BASE_DIR}/.hal/public_endpoint):"
        ip r get 8.8.8.8 | awk 'NR==1{print $7}' | tee ${BASE_DIR}/.hal/public_endpoint
        cat ${BASE_DIR}/.hal/public_endpoint
      fi
    fi
  else
    echo "Using existing Public IP from ${BASE_DIR}/.hal/public_endpoint"
    cat ${BASE_DIR}/.hal/public_endpoint
  fi
}

generate_passwords () {
  if [[ ! -f ${BASE_DIR}/.hal/.secret/minio_password ]]; then
    echo "Generating Minio password (${BASE_DIR}/.hal/.secret/minio_password):"
    openssl rand -base64 36 | tee ${BASE_DIR}/.hal/.secret/minio_password
  else
    echo "Minio password already exists (${BASE_DIR}/.hal/.secret/minio_password)"
  fi

  if [[ ! -f ${BASE_DIR}/.hal/.secret/spinnaker_password ]]; then
    echo "Generating Spinnaker password (${BASE_DIR}/.hal/.secret/spinnaker_password):"
    openssl rand -base64 36 | tee ${BASE_DIR}/.hal/.secret/spinnaker_password
  else
    echo "Spinnaker password already exists (${BASE_DIR}/.hal/.secret/spinnaker_password)"
  fi
}

print_templates () {
### Miscellaneous
# templates/halyard.yml
# templates/minio.yml
# templates/config-seed

### .hal files (will be hydrated to `.hal/default/[]``)
# templates/profiles/gate-local.yml
#   - servlet path
#   - https redirect headers
#   - password (linux only)
# templates/profiles/front50-local.yml
#   - s3 versioning off
# templates/profiles/settings-local.js
#   - artifact rewrite
#   - auth (linux only)
# templates/service-settings/gate.yml
#   - health check path

tee ${BASE_DIR}/templates/halyard.yml <<-EOF
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: halyard
  namespace: spinnaker
spec:
  replicas: 1
  serviceName: halyard
  selector:
    matchLabels:
      app: halyard
  template:
    metadata:
      labels:
        app: halyard
    spec:
      containers:
      - name: halyard
        image: HALYARD_IMAGE
        volumeMounts:
        - name: hal
          mountPath: "/home/spinnaker/.hal"
        - name: kube
          mountPath: "/home/spinnaker/.kube"
        env:
        - name: HOME
          value: "/home/spinnaker"
      securityContext:
        runAsUser: 1000
        runAsGroup: 65535
      volumes:
      - name: hal
        hostPath:
          path: BASE_DIR/.hal
          type: DirectoryOrCreate
      - name: kube
        hostPath:
          path: BASE_DIR/.kube
          type: DirectoryOrCreate
EOF

tee ${BASE_DIR}/templates/minio.yml <<-'EOF'
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
  namespace: spinnaker
spec:
  replicas: 1
  serviceName: minio
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      volumes:
      - name: storage
        hostPath:
          path: BASE_DIR/minio
          type: DirectoryOrCreate
      containers:
      - name: minio
        image: minio/minio
        args:
        - server
        - /storage
        env:
        # MinIO access key and secret key
        - name: MINIO_ACCESS_KEY
          value: "minio"
        - name: MINIO_SECRET_KEY
          value: "MINIO_PASSWORD"
        ports:
        - containerPort: 9000
        volumeMounts:
        - name: storage
          mountPath: "/storage"
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: spinnaker
spec:
  ports:
    - port: 9000
      targetPort: 9000
      protocol: TCP
  selector:
    app: minio
EOF

tee ${BASE_DIR}/templates/config-seed <<-'EOF'
currentDeployment: default
deploymentConfigurations:
- name: default
  version: 2.17.1
  providers:
    kubernetes:
      enabled: true
      accounts:
      - name: spinnaker
        providerVersion: V2
        serviceAccount: true
        onlySpinnakerManaged: true
      primaryAccount: spinnaker
  deploymentEnvironment:
    size: SMALL
    type: Distributed
    accountName: spinnaker
    location: spinnaker
  persistentStorage:
    persistentStoreType: s3
    s3:
      bucket: spinnaker
      rootFolder: front50
      pathStyleAccess: true
      endpoint: http://minio.spinnaker:9000
      accessKeyId: minio
      secretAccessKey: MINIO_PASSWORD
  features:
    artifacts: true
  security:
    apiSecurity:
      ssl:
        enabled: false
      overrideBaseUrl: https://PUBLIC_ENDPOINT/api/v1
    uiSecurity:
      ssl:
        enabled: false
      overrideBaseUrl: https://PUBLIC_ENDPOINT
  artifacts:
    http:
      enabled: true
      accounts: []
EOF


tee ${BASE_DIR}/templates/profiles/gate-local.yml <<-EOF
server:
  servlet:
    context-path: /api/v1
  tomcat:
    protocolHeader: X-Forwarded-Proto
    remoteIpHeader: X-Forwarded-For
    internalProxies: .*
    httpsServerPort: X-Forwarded-Port
EOF

if [[ ${LINUX} -eq 1 ]]; then
tee -a ${BASE_DIR}/templates/profiles/gate-local.yml <<-EOF

security:
  basicform:
    enabled: true
  user:
    name: admin
    password: SPINNAKER_PASSWORD
EOF
fi

tee ${BASE_DIR}/templates/profiles/front50-local.yml <<-'EOF'
spinnaker.s3.versioning: false
EOF

tee ${BASE_DIR}/templates/profiles/settings-local.js <<-EOF
window.spinnakerSettings.feature.artifactsRewrite = true;
EOF

if [[ ${LINUX} -eq 1 ]]; then
tee -a ${BASE_DIR}/templates/profiles/settings-local.js <<-EOF
window.spinnakerSettings.authEnabled = true;
EOF
fi

tee ${BASE_DIR}/templates/service-settings/gate.yml <<-'EOF'
healthEndpoint: /api/v1/health
EOF
}

print_manifests () {
###
# namespace.yml
# spinnaker-ingress.yml
# spinnaker-default-clusteradmin-clusterrolebinding

tee ${BASE_DIR}/manifests/namespace.yml <<-'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: spinnaker
EOF

tee ${BASE_DIR}/manifests/spinnaker-ingress.yml <<-'EOF'
---
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  labels:
    app: spin
  name: spin-ingress
  namespace: spinnaker
spec:
  rules:
  - 
    http:
      paths:
      - backend:
          serviceName: spin-deck
          servicePort: 9000
        path: /
  - 
    http:
      paths:
      - backend:
          serviceName: spin-gate
          servicePort: 8084
        path: /api/v1
EOF

if [[ ${LINUX} -eq 1 ]]; then
tee ${BASE_DIR}/manifests/spinnaker-default-clusteradmin-clusterrolebinding.yml <<-'EOF'
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: spinnaker-default-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: default
  namespace: spinnaker
EOF
fi
}

print_bootstrap_script () {
tee ${BASE_DIR}/.hal/start.sh <<-'EOF'
#!/bin/bash
# Determine port detection method
if [[ $(ss -h &> /dev/null; echo $?) -eq 0 ]];
then
  ns_cmd=ss
else
  ns_cmd=netstat
fi

# Wait for Spinnaker to start
while [[ $(${ns_cmd} -plnt | grep 8064 | wc -l) -lt 1 ]];
do
  echo 'Waiting for Halyard daemon to start';
  sleep 2;
done

VERSION=$(hal version latest -q)

hal config version edit --version ${VERSION}
sleep 5

echo ""
echo "Installing Spinnaker - this may take a while (up to 10 minutes) on slower machines"
echo ""

hal deploy apply --wait-for-completion

echo "https://$(cat /home/spinnaker/.hal/public_endpoint)"
echo "username: 'admin'"
echo "password: '$(cat /home/spinnaker/.hal/.secret/spinnaker_password)'"
EOF
  
  chmod +x ${BASE_DIR}/.hal/start.sh
}


hydrate_manifest_halyard () {
  if [[ ! -e ${BASE_DIR}/manifests/halyard.yml ]]; then
    sed \
      -e "s|HALYARD_IMAGE|${HALYARD_IMAGE}|g" \
      -e "s|BASE_DIR|${BASE_DIR}|g" \
    ${BASE_DIR}/templates/halyard.yml \
    | tee ${BASE_DIR}/manifests/halyard.yml
  fi
}

hydrate_manifest_minio () {
  MINIO_PASSWORD=$(cat ${BASE_DIR}/.hal/.secret/minio_password)

  if [[ ! -e ${BASE_DIR}/manifests/minio.yml ]]; then
    sed \
      -e "s|MINIO_PASSWORD|${MINIO_PASSWORD}|g" \
      -e "s|BASE_DIR|${BASE_DIR}|g" \
    ${BASE_DIR}/templates/minio.yml \
    | tee ${BASE_DIR}/manifests/minio.yml
  fi
}

hydrate_and_seed_halconfig () {
  MINIO_PASSWORD=$(cat ${BASE_DIR}/.hal/.secret/minio_password)
  PUBLIC_ENDPOINT=$(cat ${BASE_DIR}/.hal/public_endpoint)

  # Hydrate (dynamic) config seed with minio password and public IP
    sed \
      -e "s|MINIO_PASSWORD|${MINIO_PASSWORD}|g" \
      -e "s|PUBLIC_ENDPOINT|${PUBLIC_ENDPOINT}|g" \
    ${BASE_DIR}/templates/config-seed \
    | tee ${BASE_DIR}/templates/config

  # Seed config if it doesn't exist
  if [[ ! -e ${BASE_DIR}/.hal/config ]]; then
    cp ${BASE_DIR}/templates/config ${BASE_DIR}/.hal/config
  fi
}

hydrate_profiles_and_service_settings () {
  # None of these actually have BASE_DIR, but I like the pattern here
  SPINNAKER_PASSWORD=$(cat ${BASE_DIR}/.hal/.secret/spinnaker_password)

  if [[ ! -e ${BASE_DIR}/.hal/default/profiles/gate-local.yml ]]; then
    sed \
      -e "s|SPINNAKER_PASSWORD|${SPINNAKER_PASSWORD}|g" \
    ${BASE_DIR}/templates/profiles/gate-local.yml \
    | tee ${BASE_DIR}/.hal/default/profiles/gate-local.yml
  fi

  if [[ ! -e ${BASE_DIR}/.hal/default/profiles/front50-local.yml ]]; then
    cp ${BASE_DIR}/templates/profiles/front50-local.yml \
      ${BASE_DIR}/.hal/default/profiles/front50-local.yml
  fi

  if [[ ! -e ${BASE_DIR}/.hal/default/profiles/settings-local.js ]]; then
    cp ${BASE_DIR}/templates/profiles/settings-local.js \
      ${BASE_DIR}/.hal/default/profiles/settings-local.js
  fi

  if [[ ! -e ${BASE_DIR}/.hal/default/service-settings/gate.yml ]]; then
    cp ${BASE_DIR}/templates/service-settings/gate.yml \
      ${BASE_DIR}/.hal/default/service-settings/gate.yml
  fi
}

create_hal_shortcut () {
sudo tee /usr/local/bin/hal <<-'EOF'
#!/bin/bash
POD_NAME=$(kubectl -n spinnaker get pod -l app=halyard -oname | cut -d'/' -f 2)
# echo $POD_NAME
set -x
kubectl -n spinnaker exec -it ${POD_NAME} -- hal $@
EOF

sudo chmod 755 /usr/local/bin/hal
}

######## Script starts here

OPEN_SOURCE=0
PUBLIC_ENDPOINT=""

case "$(uname -s)" in
  Darwin*)
    LINUX=0
    BASE_DIR=~/minnaker
    ;;
  Linux*)
    LINUX=1
    BASE_DIR=/etc/spinnaker
    ;;
  *)
    LINUX=1
    BASE_DIR=/etc/spinnaker
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--oss)
      printf "Using OSS Spinnaker"
      OPEN_SOURCE=1
      ;;
    -P|--public-endpoint)
      if [ -n $2 ]; then
        PUBLIC_ENDPOINT=$2
        shift
      else
        printf "Error: --public-ip requires an IP address >&2"
        exit 1
      fi
      ;;
    -B|--base-dir)
      if [ -n $2 ]; then
        BASE_DIR=$2
      else
        printf "Error: --base-dir requires a directory >&2"
        exit 1
      fi
      ;;
    -h|--help)
      print_help
      exit 1
      ;;
  esac
  shift
done

if [[ ${OPEN_SOURCE} -eq 1 ]]; then
  printf "Using OSS Spinnaker"
  HALYARD_IMAGE="gcr.io/spinnaker-marketplace/halyard:stable"
else
  printf "Using Armory Spinnaker"
  HALYARD_IMAGE="armory/halyard-armory:1.8.0"
fi

echo "Setting the Halyard Image to ${HALYARD_IMAGE}"

# Scaffold out directories
if [[ ${LINUX} -eq 1 ]]; then
  echo "Running minnaker setup for Linux"
  
  # OSS Halyard uses 1000; we're using 1000 for everything
  sudo mkdir -p ${BASE_DIR}/.kube
  sudo mkdir -p ${BASE_DIR}/.hal/.secret
  sudo mkdir -p ${BASE_DIR}/.hal/default/{profiles,service-settings}
  sudo mkdir -p ${BASE_DIR}/manifests
  sudo mkdir -p ${BASE_DIR}/templates/{profiles,service-settings}

  sudo chown -R 1000 ${BASE_DIR}

  install_k3s
  install_git
  # get_metrics_server_manifest

  detect_endpoint

  sudo env "PATH=$PATH" kubectl config set-context default --namespace spinnaker

else
  echo "Running minnaker setup for OSX"

  # OSX / Docker Desktop has some fancy permissions so we do everything as ourselves
  mkdir -p ${BASE_DIR}/.kube
  mkdir -p ${BASE_DIR}/.hal/.secret
  mkdir -p ${BASE_DIR}/.hal/default/{profiles,service-settings}
  mkdir -p ${BASE_DIR}/manifests
  mkdir -p ${BASE_DIR}/templates/{profiles,service-settings}
  
  echo "localhost" > ${BASE_DIR}/.hal/public_endpoint
fi

generate_passwords
print_templates
print_manifests
print_bootstrap_script

hydrate_manifest_halyard
hydrate_manifest_minio
hydrate_and_seed_halconfig
hydrate_profiles_and_service_settings

if [[ ${LINUX} -eq 1 ]]; then
  ### Create all manifests:
  # - namespace - must be created first
  # - halyard
  # - minio
  # - clusteradmin
  # - ingress
  kubectl apply -f ${BASE_DIR}/manifests/namespace.yml
  kubectl apply -f ${BASE_DIR}/manifests
    
  # if [[ ${LINUX} -eq 1 ]]; then
  #   kubectl apply -f ${BASE_DIR}/metrics-server/deploy/1.8+/
  # fi

  ######## Bootstrap
  while [[ $(kubectl get statefulset -n spinnaker halyard -ojsonpath='{.status.readyReplicas}') -ne 1 ]];
  do
    echo "Waiting for Halyard pod to start"
    sleep 2;
  done

  sleep 5;
  HALYARD_POD=$(kubectl -n spinnaker get pod -l app=halyard -oname | cut -d'/' -f2)
  kubectl -n spinnaker exec -it ${HALYARD_POD} /home/spinnaker/.hal/start.sh

  create_hal_shortcut
  echo 'source <(kubectl completion bash)' >>~/.bashrc

else
  curl -L https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml -o ${BASE_DIR}/manifests/nginx-ingress-controller-mandatory.yaml
  curl -L https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/cloud-generic.yaml -o ${BASE_DIR}/manifests/nginx-ingress-controller-generic.yaml

  # This hasn't been built yet
  kubectl --context docker-desktop get ns
  if [[ $? -eq 0 ]]; then
    echo "Docker desktop detected"

    # First two create namespaces, and must be run first
    kubectl --context docker-desktop apply -f ${BASE_DIR}/manifests/namespace.yml
    kubectl --context docker-desktop apply -f ${BASE_DIR}/manifests/nginx-ingress-controller-mandatory.yaml
    kubectl --context docker-desktop apply -f ${BASE_DIR}/manifests


    ######## Bootstrap
    while [[ $(kubectl --context docker-desktop get statefulset -n spinnaker halyard -ojsonpath='{.status.readyReplicas}') -ne 1 ]];
    do
      echo "Waiting for Halyard pod to start"
      sleep 2;
    done

    sleep 5;
    HALYARD_POD=$(kubectl --context docker-desktop -n spinnaker get pod -l app=halyard -oname | cut -d'/' -f2)
    kubectl --context docker-desktop -n spinnaker exec -it ${HALYARD_POD} /home/spinnaker/.hal/start.sh

    # create_hal_shortcut
    # echo 'source <(kubectl completion bash)' >>~/.bashrc
  
  else
    echo "Docker desktop not detected; bailing."  
  fi
fi
