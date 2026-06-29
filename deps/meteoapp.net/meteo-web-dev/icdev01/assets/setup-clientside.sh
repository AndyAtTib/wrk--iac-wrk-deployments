#!/bin/bash

icdev01_rsync() { read -n 1 -p"from (l)ocal/(r)emote? " dr; echo; \
 unset fl; unset tl; \
 [[ "$dr" == "l" ]] && fl=1; [[ "$dr" != "l" ]] && tl=1; \
 echo "${fl},${tl}"; \
 read -n 1 -p"dry-run (Y/n)? " xx; echo; \
 local dry="y"; local act; \
 [[ "$xx" =~ ^[nN]$ ]] && { act="y"; unset dry; }; \
 fn=~/rsync${act:+.actual}.out; \
 rm -f $fn; \
 rsync ${dry:+--dry-run} -avz --delete --exclude='**/.venv/*' --exclude='**/.terraform/*' --exclude='**/mirrors/*' -e ssh ${fl:+$localpath} $remoteuser@$remotehost:$remotepath ${tl:+$localpath} | tee -a $fn; \
 less $fn; \
};

function icdev01_call_rsync() {
  local localpath="$1"; local remotepath="${2:-$1}";
  [[ -z "$remoteuser" || -z "$remotehost" ]] && { echo "remoteuser or remotehost is not set"; return 1; }
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} "mkdir -p '$remotepath'"
  rsync -az --delete \
    --info=progress2 \
    --exclude='**/.venv/*' --exclude='**/.terraform/*' --exclude='**/mirrors/*' \
    -e "ssh -F $HOME/.ssh/config" "$localpath" $remoteuser@$remotehost:$remotepath
  echo
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} "du -hs '$remotepath'"
}

function icdev01_setup_clientside() {
  sudo echo "can sudo"
  echo "copying files to icdev01"
  echo "n.b.: assumes that the local and remote user have the same name"

  [[ -z "$remoteuser" || -z "$remotehost" ]] && { echo "remoteuser or remotehost is not set"; return 1; }

  echo -e "\n\n==== copying .bash_history ====\n"
  scp ~/.bash_history.icdev01 $remoteuser@$remotehost:~/.bash_history

  echo -e "\n\n==== copying .gnupg/wrk-met ====\n"
  icdev01_call_rsync "/home/$remoteuser/.gnupg/wrk-met/"
  # echo -e "\n\n==== setting permissions on remote:.gnupg/wrk-met ====\n"
  # ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} \
  #   "chown -R \$(whoami) \$HOME/.gnupg/; chmod 600 \$HOME/.gnupg/*; chmod 700 \$HOME/.gnupg"

  echo -e "\n\n==== copying .ssh files ====\n"
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} "mkdir -p '\$HOME/.ssh'"
  rsync -avz -e "ssh -F $HOME/.ssh/config" \
    --include='config.icdev01' \
    --include='known_hosts' \
    --include='scripts/' \
    --include='scripts/ssh-find-agent.sh' \
    --include='configs/' \
    --include='configs/wrk/' \
    --include='configs/wrk/**' \
    --include='configs/wrk-tib/' \
    --include='configs/wrk-tib/**' \
    --exclude='*' \
    --info=progress2 \
    ~/.ssh/ $remoteuser@$remotehost:~/.ssh/
  echo -e "\n\n==== moving .ssh/config ====\n"
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} \
    "[[ -f "\$HOME/.ssh/config" ]] && mv \$HOME/.ssh/config \$HOME/.ssh/config.old; mv \$HOME/.ssh/config.icdev01 \$HOME/.ssh/config; chmod 600 \$HOME/.ssh/config"

  echo -e "\n\n==== copying dev/wrk/infra/iac-wrk-workspace ====\n"
  icdev01_call_rsync "/data/home/$remoteuser/dev/wrk/infra/iac-wrk-workspace/"

  echo -e "\n\n==== copying /dc/shellhistory files ====\n"
  local copypath="$HOME/devcons/iac-wrk-workspace/shellhistory/"
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} "mkdir -p '$copypath'"
  rsync -az -e "ssh -F $HOME/.ssh/config" \
    --info=progress2 \
    "$copypath" $remoteuser@$remotehost:$copypath
  echo
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} "du -hs '$copypath'"

  echo -e "\n\n==== creating empty .config/sops ====\n"
  ssh -o ConnectTimeout=5 ${remoteuser}@${remotehost} \
    "mkdir -p \$HOME/.config/sops;"
}

echo 'on vscode host, run `read vm_ip; [[ -n "$vm_ip" ]] && ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$vm_ip"`'
