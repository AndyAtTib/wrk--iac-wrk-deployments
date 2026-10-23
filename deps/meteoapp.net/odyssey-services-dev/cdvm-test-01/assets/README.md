# cloud-init

First-boot bootstrap for cdvm-test-01. Rendered by Terraform as a template (c-cirrus-docker-vm
cloud_init_file - see "VM init files" in that config's README):
- `${ST_NAME}`, `${ST_CON_NAME}`, `${SUB_ID}` and `${RG_NAME}` are the init-files storage account's
  name, container, subscription and resource group;
- `${compose_file}`, `${acme_gts_staging}`, `${acme_gts}`, `${acme_le_staging}` and `${acme_le}` are the
  uploaded paths of the layout file's vm_init_files entries with those keys. The layout file
  must define exactly these keys: one referenced here but missing there fails the plan;
- a literal `$${` or `%%{` must be written `$$${` / `%%%{`. Plain `$var` shell variables need
  nothing (the script below only uses that form) and Jinja's `{{ }}` passes through untouched.

Note:
- Machine setup is done by Ansible, run as a one-off Docker container instead of being installed
on the VM.
- The image is built here from python:3.13-slim with pinned ansible-core and
community.docker, and the container runs with `--pid=host --privileged` so that the
community.docker.nsenter connection executes every task inside the host's namespaces - the
host's python (Ubuntu 26.04's 3.14 is within ansible-core 2.21's target range), filesystem,
network and systemd - exactly as a locally installed Ansible would.
- ansible-pull was not used: it needs a git remote reachable from the VM, whereas the
storage account is already the file channel and the playbook is small enough to ship in custom_data.

For now the playbook only downloads the init files, as the VM's managed identity, into
/tmp/vm-init-files (root, 0600, uploaded paths preserved); installing them and starting the
compose stack are the next tasks. The download is plain Blob REST with an IMDS bearer token
(uri + get_url), which needs nothing but the identity's Storage Blob Data Reader role.

NOTE: azure.azcollection's azure_rm_storageblob also reads the account through ARM, which that role
does not allow, and needs the Azure SDK in the image.

Re-run after boot with /opt/cirrus/bin/run-ansible.sh (extra arguments go to ansible-playbook,
e.g. -v); the image is reused, `docker rmi cirrus-ansible:local` forces a rebuild. Output goes
to `/var/log/cloud-init-output.log` at first boot.

## Files written

`path: /opt/cirrus-ansible/image/Dockerfile`

One-off Ansible controller image, built at first boot by run-ansible.sh. python:3.13-slim is
Debian trixie, whose util-linux provides the nsenter binary the community.docker.nsenter
connection plugin runs. ansible-core 2.21: controller python 3.12-3.14, target 3.9-3.14.

`path: /opt/cirrus-ansible/inventory.yml`

The one managed host is the VM itself, reached through community.docker.nsenter: the
controller container runs with `--pid=host --privileged` and nsenter enters pid 1's
namespaces, so modules run as root with the host's python on the host's filesystem.

`path: /opt/cirrus-ansible/vars/vm-init-files.yml`

The only Terraform-rendered Ansible file: the init-files storage account and, keyed as in
the layout file's vm_init_files, each file's uploaded path within the container.

`path: /opt/cirrus/bin/run-ansible.sh`

Build the controller image on first use, then run the playbook against this VM.
`--pid=host --privileged` are what the nsenter connection needs to enter the host's
namespaces; the default bridge network is enough for the controller side, since every task
runs in the host's network namespace.
