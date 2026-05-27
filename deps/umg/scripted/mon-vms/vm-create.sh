#!/bin/bash

function setup_env() {
  local sub_filt="$sub_filt"
  local rg_filt="$rg_filt"

  [[ -z $sub_filt ]] && { echo "ERROR: sub_filt is not set"; return 1; }
  [[ -z $rg_filt ]] && { echo "ERROR: rg_filt is not set"; return 1; }

  sub_nm=$(az account list --query "[?name == '$sub_filt'] | [].name" --output tsv)
  echo $sub_nm

  az account set -s $sub_nm
  az account show

  declare -g rg_nm=$(az group list --query "[?contains(name, '$rg_filt')].name" --output tsv)
  echo $rg_nm
}

# ssh-keygen -f "/home/andrew/.ssh/known_hosts" -R "$vm_ip"
# ssh -o ConnectTimeout=5 $ssh_un@$vm_ip
# tail  --lines=+2000 /var/log/cloud-init-output.log | less -N
# vm_ip=$(az network public-ip list -g $rg_nm --output json | jq -r '.[0].ipAddress'); echo $vm_ip
# watch -n 10 -d "sudo grep -ni cron /var/log/syslog; echo; echo; ls -al /root/jobs"

function get_vm_nm() {
  local rg_nm

  local OPTIND args

  while getopts "g:n:p:d:f:o:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  local vm_nms=$(az vm list -g $rg_nm --query '[].{name:name}' --output json)
  echo $(echo $vm_nms | jq -r '.[].name' | nl)
  local ans
  read -p "Enter VM number: " ans
  ans=$((ans-1))
  declare -g vm_nm=$(echo $vm_nms | jq -r --argjson k $ans '.[$k].name')
  echo $vm_nm
}

function get_nsg_nm() {
  local rg_nm vm_nm

  local OPTIND args

  while getopts "g:n:p:d:f:o:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      n) vm_nm="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  local nic_id=$(az vm show -g $rg_nm -n $vm_nm --output json | jq -r '.networkProfile.networkInterfaces[0].id')
  if [[ -z $nic_id ]]; then echo "ERROR: failed to find nic id"; return 1; fi

  local nic_nm=$(echo ${nic_id/*networkInterfaces\//});
  if [[ -z $nic_nm ]]; then echo "ERROR: failed to find nic name"; return 1; fi

  local nsg_id=$(az network nic list --query "[?id=='$nic_id'] | [0].networkSecurityGroup.id" --output tsv)
  if [[ -z $nsg_id ]]; then echo "ERROR: failed to find nsg id"; return 1; fi

  unset nsg_nm
  declare -g nsg_nm=$(echo ${nsg_id/*networkSecurityGroups\//});
  if [[ -z $nsg_nm ]]; then echo "ERROR: failed to find nsg name"; return 1; fi

  echo $nsg_nm
}

function read_vm_ip() {
  declare -g vm_ip=$(az network public-ip list -g $rg_nm --query "[].ipAddress" --output tsv); echo $vm_ip
}

function create_vm() {
  local rg_nm vm_nm loc pub_nm

  local OPTIND args

  while getopts "g:n:l:p:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      n) vm_nm="$OPTARG";;
      l) loc="$OPTARG";;
      p) pub_nm="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  [[ -z $ssh_un ]] && { echo "ERROR: ssh_un is not set"; return 1; }
  [[ -z $pip_nm ]] && { echo "ERROR: pip_nm is not set"; return 1; }

  # https://learn.microsoft.com/en-us/azure/virtual-machines/linux/cli-ps-findimage#find-specific-images
  # az vm image list-offers --location $loc --publisher Canonical --query "[?contains(id, 'jammy')]"
  # az vm image list-skus --location $loc --publisher Canonical --offer 0001-com-ubuntu-server-jammy
  # az vm image list -l $loc --publisher Canonical --offer 0001-com-ubuntu-server-jammy --sku 22_04-lts-gen2 --all --output table

  local im_nm=$(az vm image list -l $loc --publisher $pub_nm -f ubuntu-server-jammy --query "[?version == 'latest'] | [0].[urnAlias]" --output tsv); echo $im_nm
  if [[ -z $im_nm ]]; then echo "ERROR: failed to find image"; return 1; fi
  im_nm="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
  im_nm="Ubuntu2204"

  # az vm image list-offers --location northeurope --publisher Canonical --query "[?contains(id, 'jammy')]"
  #im_nm=0001-com-ubuntu-server-jammy

  local vm_sz=Standard_B2s
  vm_sz=$(az vm list-sizes -l $loc --query "[?name == '$vm_sz'].[name]" --output tsv); echo $vm_sz
  if [[ -z $vm_sz ]]; then echo "ERROR: failed to find vm size"; return 1; fi

  vm_sz2=Standard_B1ls
  vm_sz2=$(az vm list-sizes -l $loc --query "[?name == '$vm_sz2'].[name]" --output tsv); echo $vm_sz2
  if [[ -z $vm_sz2 ]]; then echo "ERROR: failed to find vm size"; return 1; fi

  local au_nm="$ssh_un"
  [[ -z $au_nm ]] && { echo "ERROR: au_nm is not set"; return 1; }
  # https://learn.microsoft.com/en-us/cli/azure/vm?view=azure-cli-latest#az-vm-resize
  # https://learn.microsoft.com/en-us/cli/azure/vm?view=azure-cli-latest#az-vm-create
  # N.B. use --ssh-dest-key-path to specify a custom path for the generated ssh key,
  #   otherwise it will default to ~/.ssh/id_rsa. --generate-ssh-keys will either use,
  #   or create if it doesn't exist, the key file at that path.
  az vm create \
    -g $rg_nm \
    -n $vm_nm \
    -l $loc ${au_nm:+--admin-username $au_nm} \
    --image $im_nm \
    --size $vm_sz \
    --generate-ssh-keys \
    --public-ip-address $pip_nm \
    --custom-data cloud-init.txt

  az vm wait -g $rg_nm -n $vm_nm --created

  local nic_id=$(az vm show -g $rg_nm -n $vm_nm --output json | jq -r '.networkProfile.networkInterfaces[0].id')
  if [[ -z $nic_id ]]; then echo "ERROR: failed to find nic id"; return 1; fi

  local nsg_id=$(az network nic list --query "[?id=='$nic_id'] | [0].networkSecurityGroup.id" --output tsv)
  if [[ -z $nsg_id ]]; then echo "ERROR: failed to find nsg id"; return 1; fi

  local nsg_nm=$(echo ${nsg_id/*networkSecurityGroups\//});
  if [[ -z $nsg_nm ]]; then echo "ERROR: failed to find nsg name"; return 1; fi

  az network nsg rule update \
    --resource-group $rg_nm \
    --nsg-name $nsg_nm \
    --name default-allow-ssh \
    --protocol Tcp \
    --direction Inbound \
    --priority 1000 \
    --source-address-prefixes Internet \
    --source-port-ranges '*' \
    --destination-address-prefixes VirtualNetwork \
    --destination-port-ranges 22 \
    --access Deny \
    --description "Deny SSH from Internet"

  az network nsg rule create \
    --resource-group $rg_nm \
    --nsg-name $nsg_nm \
    --name allow-ssh-cloud-shell-ne \
    --protocol Tcp \
    --direction Inbound \
    --priority 900 \
    --source-address-prefixes AzureCloud.northeurope \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges 22 \
    --access Allow \
    --description "Allow ssh from Azure Cloud Shell"

  read -p "Enter to resize"

  az vm stop -g $rg_nm -n $vm_nm

  az vm resize -g $rg_nm -n $vm_nm --size $vm_sz2

  az vm start -g $rg_nm -n $vm_nm
}

function create_fwr() {
  local rg_nm vm_nm port desc

  local OPTIND args

  while getopts "g:n:p:d:f:o:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      n) vm_nm="$OPTARG";;
      p) port="$OPTARG";;
      d) desc="$OPTARG";;
      f) fwr_nm="$OPTARG";;
      o) pri="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  local nic_id=$(az vm show -g $rg_nm -n $vm_nm --output json | jq -r '.networkProfile.networkInterfaces[0].id')
  if [[ -z $nic_id ]]; then echo "ERROR: failed to find nic id"; return 1; fi

  local nic_nm=$(echo ${nic_id/*networkInterfaces\//});
  if [[ -z $nic_nm ]]; then echo "ERROR: failed to find nic name"; return 1; fi

  local nsg_id=$(az network nic list --query "[?id=='$nic_id'] | [0].networkSecurityGroup.id" --output tsv)
  if [[ -z $nsg_id ]]; then echo "ERROR: failed to find nsg id"; return 1; fi

  local nsg_nm=$(echo ${nsg_id/*networkSecurityGroups\//});
  if [[ -z $nsg_nm ]]; then echo "ERROR: failed to find nsg name"; return 1; fi

  az network nsg rule create \
    --resource-group $rg_nm \
    --nsg-name $nsg_nm \
    --name "$fwr_nm" \
    --protocol Tcp \
    --direction Inbound \
    --priority $pri \
    --source-address-prefixes AzureCloud.northeurope \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges $port \
    --access Allow \
    --description "$desc"
}

function set_fwr() {
  local rg_nm nsg_nm access rule_nm access_orig
  local ans

  local OPTIND args

  while getopts "g:s:n:a:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      s) nsg_nm="$OPTARG";;
      n) rule_nm="$OPTARG";;
      a) access="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  if [[ -z $nsg_nm ]]; then echo "nsg_nm required"; return 1; fi

  if [[ -z $rule_nm ]]; then
    local rules=$(az network nsg rule list \
      -g $rg_nm \
      --nsg-name $nsg_nm \
      --output json \
      --query '[].{name:name, access:access}')
    echo $rules | jq
    echo $rules | jq -r '.[].name' | nl
    read -p "Select rule: " ans
    ans=$((ans-1))
    rule_nm=$(echo "$rules" | jq -r --argjson k $ans '.[$k].name')
    echo $rule_nm
    if [[ -z $rule_nm ]]; then echo "error selecting rule name"; return 1; fi
    access_orig=$(echo "$rules" | jq -r --argjson k $ans '.[$k].access')
  else
    access_orig=$(az network nsg rule show -g $rg_nm --nsg-name $nsg_nm --name $rule_nm --output tsv --query '[access]')
  fi

  if [[ -z "$access" ]]; then
    access="Allow"
    if [[ "$access_orig" == "Allow" ]]; then access="Deny"; fi
  fi

  az network nsg rule update \
    --resource-group "$rg_nm" \
    --nsg-name "$nsg_nm" \
    --name "$rule_nm" \
    --access "$access"
}

function delete_vm() {
  local rg_nm vm_nm loc pub_nm

  local OPTIND args

  while getopts "g:n:l:p:" args; do
    if [[ $OPTARG == '' ]]; then OPTARG=1; fi
    echo "'$args': '$OPTARG'"
    case $args in
      g) rg_nm="$OPTARG";;
      n) vm_nm="$OPTARG";;
      \?) echo "invalid option -$OPTARG" >&2; return 1;;
    esac
  done

  local disk_id=$(az vm show -g $rg_nm -n $vm_nm --output json | jq -r '.storageProfile.osDisk.managedDisk.id')

  local nic_id=$(az vm show -g $rg_nm -n $vm_nm --output json | jq -r '.networkProfile.networkInterfaces[0].id')
  if [[ -z $nic_id ]]; then echo "ERROR: failed to find nic id"; return 1; fi

  local nic_nm=$(echo ${nic_id/*networkInterfaces\//});
  if [[ -z $nic_nm ]]; then echo "ERROR: failed to find nic name"; return 1; fi

  local nsg_id=$(az network nic list --query "[?id=='$nic_id'] | [0].networkSecurityGroup.id" --output tsv)
  if [[ -z $nsg_id ]]; then echo "ERROR: failed to find nsg id"; return 1; fi

  local nsg_nm=$(echo ${nsg_id/*networkSecurityGroups\//});
  if [[ -z $nsg_nm ]]; then echo "ERROR: failed to find nsg name"; return 1; fi

  local snet_id=$(az network nic list --query "[?id=='$nic_id'] | [0].ipConfigurations[0].subnet.id" --output tsv)
  local vnet_nm="${snet_id/*virtualNetworks\//}"
  vnet_nm="${snet_id/\/subnets*/}"
  if [[ -z $vnet_nm ]]; then echo "ERROR: failed to find vnet name"; return 1; fi

  az vm delete -g $rg_nm -n $vm_nm --yes
  az disk delete -g $rg_nm -n ${disk_id/*disks\//} --yes
  az network nic delete -g $rg_nm -n $nic_nm
  az network nsg delete -g $rg_nm -n $nsg_nm
  az network vnet delete -g $rg_nm -n $vnet_nm
}
