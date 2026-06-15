#!/bin/bash

accs=$(az account list -o tsv --query '[].id'); echo "${accs[@]}"
vmsi=$(for acc in ${accs[@]}; do { az vm list --subscription $acc -o json --query '[].{nm:name, rg:resourceGroup}' | jq -c --arg sub $acc '. | map({nm, rg, sub: $sub})'; } done); echo "${vmsi[@]}" | jq -c '.[]'
vms="$(echo "${vmsi[@]}" | jq -c '.[]')"
vmsout=$(for vmi in ${vms[@]}; do { read vm rg sub < <(echo $(echo "$vmi" | jq -r '.nm, .rg, .sub')); az vm show --subscription $sub -d -n $vm -g $rg -o json --query '{nm:name, ip:publicIps, rg:resourceGroup, st:powerState}' | jq --arg sub $sub -c '. += {sub:$sub}'; } done); echo "${vmsout[@]}" | jq -c '.'
export vmsout=$vmsout
