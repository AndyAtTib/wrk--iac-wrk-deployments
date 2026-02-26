#!/bin/bash

if [[ ! -d "./.git" ]]; then echo "this script must be run from the repository root"; return 1; fi

cp -f ./.git-template/* ./.git/hooks/
chmod 744 ./.git/hooks/commit-msg
chmod 744 ./.git/hooks/common-pre-commit-run.sh
chmod 744 ./.git/hooks/pre-commit
chmod 744 ./.git/hooks/pre-push
