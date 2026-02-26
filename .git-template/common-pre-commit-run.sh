function _do_run_precommit_hook() {
  # last stable was 1.97.4 before 2025-04-09, but this didn't work with worktrees. v1.98.0 fixed that issue.
  # 2025-04-09:
  local -r TAG="v1.98.1"; local -r img="ghcr.io/antonbabenko/pre-commit-terraform:$TAG"

  local OPTIND arg
  local hook_nm
  while getopts "h:" arg; do
    case $arg in
      h) hook_nm="$OPTARG";;
      \?) echo "ERROR: invalid option - $args: $OPTARG" >&2; return 1;;
    esac
  done
  if [[ -z "$hook_nm" ]]; then echo "ERROR - hook name not given"; return 1; fi
  shift $((OPTIND-1))

  local -r pcpath=".pre-commit"
  local -r repo_dir=$(git rev-parse --show-toplevel)
  local -r repo_name=$(basename "$repo_dir")
  local -r repo_hash=$(git rev-parse --show-toplevel | md5sum | cut -c 1-7)
  local -r lpcpathhome=$(if [ -d /host-home ]; then echo /host-home; else readlink -f ~/; fi)
  local -r lpcpathhome_local=$(if [ -d /host-home ]; then echo "$LOCALHOME"; else readlink -f ~/; fi)
  local -r lpcpath="$lpcpathhome/var/lib/precommit/repo-${repo_name}-${repo_hash}/${pcpath}"
  local -r lpcpath_local="$lpcpathhome_local/var/lib/precommit/repo-${repo_name}-${repo_hash}/${pcpath}"
  #echo "lpcpath: $lpcpath"
  mkdir -p $lpcpath
  echo "$repo_dir" > $lpcpath/.gitdir.txt
  local -r pccpath=".pre-commit-cache"
  local -r tfcpath=".tflint.d/plugins"
  local -r absolute_path=$(realpath $(pwd))
  # get the path relative to /<workspace>/projects, assuming we are in projects
  local -r relative_path=${absolute_path#/workspaces/}
  local -r local_ws_parent_dir=$(if [ -n "$LOCALWORKSPACEFOLDER" ]; then echo "$(dirname "$LOCALWORKSPACEFOLDER")/$relative_path"; else pwd; fi)
  #echo "local_ws_parent_dir: $local_ws_parent_dir"

  local -r wrk_dir="/lint"
  local -r config=".pre-commit-config.yaml"
  mkdir -p $lpcpath/$pccpath
  mkdir -p $lpcpath/$tfcpath
  local -r docker_sudo=$(id -Gn | grep -viqw docker && [[ $(id -u) -ne 0 ]] && echo 1)

  local -r remote_nm="$1"
  local args=(hook-impl --config="$config" --hook-type="$hook_nm" --hook-dir "$wrk_dir" -- "$@")

  # TODO: this is an issue if working in a devcontainer - we need the host user id?
  local userid="$(id -u):$(id -g)"

  local gh_tkn="$GITHUB_TOKEN_API"

  # dump all the variables we have collected
  if [ -n "$PRE_COMMIT_COMMON_DEBUG" ]; then
    declare -p | grep ' [a-z_]*='
  fi

  # read one LF terminated line at a time into a variable input, and loop on the variable `input`
  local input
  local run_hook="$hook_nm"
  while IFS= read -r -d $'\n' input || \
    [[ "$run_hook" != "pre-push" && -n "$run_hook" ]]; do
    # this will only run if there is input, and we assume there is only
    # input if there is a local-remote diff, i.e. the shas are not the same.
    # warning: this will not trigger if it is a force push and we are stale
    echo "Running hook $hook_nm${input:+ for }$input"
    run_hook=""
    # echo "args: ${args[@]}"

    local movedwtfile=0
    local gitmount
    if [ -n "$LOCALWORKSPACEFOLDER" ]; then
      # if .git is a file, then we are in a worktree (possibly submodule but ignore that)
      if [ -f .git ]; then
        # local wtgitdir=$(git rev-parse --git-dir)
        # local wtgitdir_rel=${wtgitdir#/workspaces/}
        # local wtgitdir_local="$(dirname "$LOCALWORKSPACEFOLDER")/$wtgitdir_rel"
        # echo "gitdir: ${wtgitdir_local}" > .git

        local cgitdir="$(dirname $(git rev-parse --git-common-dir))"
        local cgitdir_rel=${cgitdir#/workspaces/}
        local gitmount="$(dirname "$LOCALWORKSPACEFOLDER")/$cgitdir_rel"

        cp .git ../.git.old
        movedwtfile=1

        sed -i 's|.*\(/.git/\)|\1|' .git
        # echo; cat .git; echo
        local wtgitftext=$(cat .git)

        echo "gitdir: /gitcommon${wtgitftext}" > .git
        # echo; cat .git; echo
        # mv ../.git.old .git
        # return 0

        # Replace paths in args from /workspaces/xxx/yyy/.git to /gitcommon/.git
        local argsadj=()
        for arg in "${args[@]}"; do
          # Use regex replacement to change /workspaces/anything/more/again/.git to /gitcommon/.git
          local modified_arg=$(echo "$arg" | sed -E 's|(/workspaces/.+?)(/.git)|/gitcommon\2|g')
          argsadj+=("$modified_arg")
        done
        # Use argsadj instead of args for docker command
        args=("${argsadj[@]}")
      fi
    fi

    # echo; echo "gitmount: $gitmount"; echo
    # echo "/pcpath/tfcpath: /$pcpath/$tfcpath"
    # echo "/pcpath/pccpath: /$pcpath/$pccpath"
    # echo "lpcpath_local:pcpath: $lpcpath_local:/$pcpath"
    # echo "local_ws_parent_dir:wrk_dir: $local_ws_parent_dir:$wrk_dir"
    # echo "${args[@]}"

#     cat <<EOF
#     echo "$input" | ${docker_sudo:+sudo} docker run -i \
#       --rm \
#       -e "USERID=$userid" \
#       -e "GITHUB_TOKEN=$gh_tkn" \
#       -e "TFLINT_PLUGIN_DIR=/$pcpath/$tfcpath" \
#       -e "PRE_COMMIT_HOME=/$pcpath/$pccpath" \
#       ${gitmount:+-v $gitmount:/gitcommon} \
#       -v $lpcpath_local:/$pcpath \
#       -v $local_ws_parent_dir:$wrk_dir -w $wrk_dir \
#       $img \
#       "${args[@]}"
# EOF
    #  -a stdout -a stderr \
    echo "$input" | ${docker_sudo:+sudo} docker run -i \
      --rm \
      -e "USERID=$userid" \
      -e "GITHUB_TOKEN=$gh_tkn" \
      -e "TFLINT_PLUGIN_DIR=/$pcpath/$tfcpath" \
      -e "PRE_COMMIT_HOME=/$pcpath/$pccpath" \
      ${gitmount:+-v $gitmount:/gitcommon} \
      -v $lpcpath_local:/$pcpath \
      -v $local_ws_parent_dir:$wrk_dir -w $wrk_dir \
      $img \
      "${args[@]}"
    local ret=$?;
    if [ $movedwtfile -eq 1 ]; then
      mv ../.git.old .git
    fi
    [[ $ret -ne 0 ]] && echo -e "\e[31mERROR: error on docker run: $ret\e[0m"
    if [[ $ret -ne 0 ]]; then return $ret; fi
  done
  return 0
}

function is_sourced() {
  local sourced
  (
    [[ -n $ZSH_VERSION && $ZSH_EVAL_CONTEXT =~ :file$ ]] ||
    [[ -n $KSH_VERSION && "$(cd -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")" != "$(cd -- "$(dirname -- "${.sh.file}")" && pwd -P)/$(basename -- "${.sh.file}")" ]] ||
    [[ -n $BASH_VERSION ]] && (return 0 2>/dev/null)
  ) && sourced=1 || sourced=0
  return sourced
}

_do_run_precommit_hook -h $stage -- "$@"; ret=$?
echo "$stage result: $ret"

if [[ is_sourced -eq 0 ]]; then exit $ret; fi
return $ret;
