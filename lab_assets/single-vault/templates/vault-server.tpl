#!/bin/bash

#### Install System Packages ####
apt-get update
apt-get install -qq -y \
    git \
    jq \
    unzip > /dev/null 2>&1

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

#### Set up Vault Server ####
export DEBIAN_FRONTEND=noninteractive
sudo echo "127.0.0.1 $(hostname)" >> /etc/hosts

USER="vault"
COMMENT="Hashicorp vault user"
GROUP="vault"
HOME="/srv/vault"

# Get Private IP address
PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $${GROUP} >/dev/null
  then
    sudo addgroup --system $${GROUP} >/dev/null
  fi

  if ! getent passwd $${USER} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $${GROUP} \
      --home $${HOME} \
      --no-create-home \
      --gecos "$${COMMENT}" \
      --shell /bin/false \
      $${USER}  >/dev/null
  fi
}

user_ubuntu

VAULT_ZIP="vault_1.4.2_linux_amd64.zip"
VAULT_URL="https://releases.hashicorp.com/vault/1.4.2/vault_1.4.2_linux_amd64.zip"
sudo curl --silent --output /tmp/$${VAULT_ZIP} $${VAULT_URL}
sudo unzip -o /tmp/$${VAULT_ZIP} -d /usr/local/bin/
sudo chmod 0755 /usr/local/bin/vault
sudo chown vault:vault /usr/local/bin/vault
sudo mkdir -pm 0755 /etc/vault.d
sudo mkdir -pm 0755 /opt/vault
sudo chown vault:vault /opt/vault

cat << EOF | sudo tee /lib/systemd/system/vault.service
[Unit]
Description=Vault Agent
Requires=network-online.target
After=network-online.target
[Service]
Restart=on-failure
PermissionsStartOnly=true
ExecStartPre=/sbin/setcap 'cap_ipc_lock=+ep' /usr/local/bin/vault
ExecStart=/usr/local/bin/vault server -config /etc/vault.d
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=vault
Group=vault
[Install]
WantedBy=multi-user.target
EOF
###########################################

cat << EOF | sudo tee /etc/vault.d/vault.hcl
storage "file" {
  path = "/opt/vault"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key}"
}
api_addr = "http://$${PUBLIC_IP}:8200"
ui=true
disable_mlock = true
EOF


sudo chmod 0664 /lib/systemd/system/vault.service
sudo systemctl daemon-reload
sudo chown -R vault:vault /etc/vault.d
sudo chmod -R 0644 /etc/vault.d/*
###########################################

#### Set up Vault environment ####
sudo tee -a /etc/environment <<EOF
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
EOF

source /etc/environment
###########################################

#### Start Vault server ###
sudo systemctl enable vault
sudo systemctl start vault
###########################################

#### Initialize Vault - Token in Clear txt ####
until curl -fs -o /dev/null localhost:8200/v1/sys/init; do
  echo "Waiting for Vault to start..."
  sleep 1
done

init=$(curl -fs localhost:8200/v1/sys/init | jq -r .initialized)

if [ "$init" == "false" ]; then
  echo "Initializing Vault"
  install -d -m 0755 -o vault -g vault /etc/vault
  SECRET_VALUE=$(vault operator init -recovery-shares=1 -recovery-threshold=1 | tee /etc/vault/vault-init.txt)
  echo "Storing vault init values in secrets manager"
  aws secretsmanager put-secret-value --region "${aws_region}" --secret-id "${vault_secrets_id}" --secret-string "$${SECRET_VALUE}"
else
  echo "Vault is already initialized"
fi

sealed=$(curl -fs localhost:8200/v1/sys/seal-status | jq -r .sealed)
unseal_key=$(awk '{ if (match($0,/Unseal Key 1: (.*)/,m)) print m[1] }' /etc/vault/vault-init.txt)
root_token=$(awk '{ if (match($0,/Initial Root Token: (.*)/,m)) print m[1] }' /etc/vault/vault-init.txt)

export VAULT_TOKEN=$root_token

echo $unseal_key > /etc/vault/unseal-key.txt 
echo $root_token > /etc/vault/root-token.txt

if [ "$sealed" == "true" ]; then
  echo "Unsealing Vault"
  vault operator unseal $unseal_key 
else
  echo "Vault is already unsealed"
fi
###########################################

#### Set up Vault Database backend ####
vault auth enable aws

vault write -force auth/aws/config/client

# Add the new capabilities into the policy definition
tee /home/ubuntu/workshopapp.hcl <<EOF
path "database/static-creds/rotate-mysql-pass" {
  capabilities = ["read"]
}
EOF

# Update the policy named 'workshopapp'
cd /home/ubuntu
vault policy write workshopapp workshopapp.hcl

# Set up Vault db backend configs
vault write auth/aws/role/client-role-iam auth_type=iam \
        bound_iam_principal_arn=${role_arn} \
        policies=workshopapp \
        ttl=24h

vault secrets enable database

vault write database/config/mysql \
        plugin_name=mysql-database-plugin \
        allowed_roles="rotate-mysql-pass" \
        connection_url="{{username}}:{{password}}@tcp(${mysql_endpoint}:3306)/" \
        username="${db_user}" \
        password="${db_password}"
###########################################



