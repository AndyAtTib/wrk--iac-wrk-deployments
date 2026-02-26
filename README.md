# iac-wrk-deployments

This is the set of deployment definitions (environment and variable files) to be used with modules in `iac-wrk-configs`.

It is designed as a set of environments, defined in the `./envs/.../<env-name>` directories. The files in these envs are encrypted using sops.

# encrypting secrets

Bootstrap config files will have secrets encrypted with a PGP key managed outside our az
infrastructure. This is mainly so that these secrets, which may include PII or secrets,
are not committed to the git repo.

This therefore assumes a basic infrastructure using GPG, and a shared keypair for all
contributors. As we grow in complexity, we can adopt age or an az KMS in addition to
the bootstrap keypair.

For encryption we use [sops]. Documentation assumes [sops v3.12.1]. Users should always
update to the latest version.

[sops]: https://github.com/getsops/sops/
[sops v3.8.1]: https://github.com/getsops/sops/releases/tag/v3.12.1

## Sops Installation

Within the docker container, for instance,

```bash
ver="3.12.1"
curl -LO https://github.com/getsops/sops/releases/download/v${ver}/sops-v${ver}.linux.amd64
mv sops-v3.12.1.linux.amd64 /usr/local/bin/sops
chmod +x /usr/local/bin/sops
```

## Example bootstrap keypair creation

### Generate keypair

```bash
read -p "Enter a deployment name (e.g. dep1): " dep_nm
email_id="security@example.com" # use our email domain
key_name="wrk-dep-${dep_nm}-root-keypair"

gpg --batch --generate-key <<EOF
%no-protection
Key-Type: default
Subkey-Type: default
Name-Real: Bootstrap key for $dep_nm
Name-Email: $email_id
Expire-Date: 0
EOF

sops_pgp_fp=$(gpg --list-keys $email_id | grep -E -o "([A-F0-9]{16,})"); echo $sops_pgp_fp

gpg --list-signatures $sops_pgp_fp
gpg --list-keys --keyid-format LONG $sops_pgp_fp
```

### Export/Import keypair

Now export the keys to save to the key db

```bash
# set a storage password, and put it alongside the key in the pw db - this secures it when in transit
gpg --edit-key $sops_pgp_fp passwd quit
# export key files
gpg --armor --output public.key --export $sops_pgp_fp
gpg --armor --output private.key --export-secret-keys $sops_pgp_fp
# now save to pw db
```

To re-import the keys later:

```bash
gpg --import private.key
gpg --import public.key
# remove the password if on a secure system
gpg --edit-key $sops_pgp_fp passwd quit
# trust the key
gpg --edit-key $sops_pgp_fp trust quit
# enter 5 (trust ultimately)
# enter y (really trust ultimately)
```

## En/Decryption of bootstrapping configs

We rely on the default sops behaviour using `.sops.yaml` to define encryption configurations.
This means that encryption and decryption will be a simple `sops -e <file>` or `sops -d <file>`
and editing is just `sops -i <file>`.

`.sops.yaml` uses a hierarchy. Typically we would just expect a single `./envs/.sops.yaml` which has a common
configuration for all files, but care must be taken that changes to this file do not apply to pre-existing encrypted
files. If they do then you will need to decrypt those files, change the `./envs/.sops.yaml` and re-encrypt those files
otherwise the changes to `./envs/.sops.yaml` will not be applied.

## apply.sh and sops

`apply.sh` helpers for configs in `iac-wrk-configs` assume that they can call `sops -d <file>` and rely on `./envs/.sops.yaml`.


## Misc GPG notes

gpg may need pinentry:

```bash
echo "pinentry-mode loopback" >> ~/.gnupg/gpg.conf
```

## Using git diff with sops

Add to one of the [git config file locations]:

[git config file locations]: https://git-scm.com/docs/git-config#FILES

```
[diff "sopsdiffer"]
    textconv = sops --decrypt --config /dev/null
```

Now add to .gitattributes a line that configures `diff=` for the file glob you want to target

```
envs/**/*.sops.tfvars.json text diff=sopsdiffer eol=lf
```
