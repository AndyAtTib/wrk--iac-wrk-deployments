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
/tmp/vm-init-files (root, 0644, uploaded paths preserved); installing them and starting the
compose stack are the next tasks. The files are downloaded one by one with
azure.azcollection's `azure_rm_storageblob` (`auth_source: msi`, `auth_mode: login`), each
chmod'ed to 0644 as soon as it lands (tasks/download-init-file.yml).

NOTE: `azure_rm_storageblob` runs where the Azure SDK is, i.e. in the controller container
(`delegate_to: localhost`), not on the host like the other tasks; run-ansible.sh bind-mounts
/tmp/vm-init-files at the same path so the files land on the host. Besides Storage Blob Data
Reader the VM identity needs the Reader role on the storage account: the module reads the
account's properties through ARM (`Microsoft.Storage/storageAccounts/read`) to find the blob
endpoint before it touches the data plane with the identity's token.

Re-run after boot with /opt/cirrus/bin/run-ansible.sh (extra arguments go to ansible-playbook,
e.g. -v); the image is reused, `docker rmi cirrus-ansible:local` forces a rebuild. Output goes
to `/var/log/cloud-init-output.log` at first boot.

## Files written

`path: /opt/cirrus-ansible/image/Dockerfile`

One-off Ansible controller image, built at first boot by run-ansible.sh. python:3.13-slim is
Debian trixie, whose util-linux provides the nsenter binary the community.docker.nsenter
connection plugin runs. ansible-core 2.21: controller python 3.12-3.14, target 3.9-3.14.
azure.azcollection is installed with its full `requirements.txt` (the collection's module_utils
imports most of the Azure SDK at load time, so a subset does not work); that is the bulk of the
image and of the build time.

`path: /opt/cirrus-ansible/inventory.yml`

The one managed host is the VM itself, reached through community.docker.nsenter: the
controller container runs with `--pid=host --privileged` and nsenter enters pid 1's
namespaces, so modules run as root with the host's python on the host's filesystem.

`path: /opt/cirrus-ansible/vars/vm-init-files.yml`

The only Terraform-rendered Ansible file: the init-files storage account and, keyed as in
the layout file's vm_init_files, each file's uploaded path within the container.

`path: /opt/cirrus-ansible/tasks/download-init-file.yml`

Included once per init file by site.yml: download the blob with `azure_rm_storageblob`
(delegated to the container, with retries for IMDS lag and RBAC propagation), then set the
file's owner and mode (0644) on the host.

`path: /opt/cirrus/bin/run-ansible.sh`

Build the controller image on first use, then run the playbook against this VM.
`--pid=host --privileged` are what the nsenter connection needs to enter the host's
namespaces; the default bridge network is enough for the controller side, since every task
but the delegated downloads runs in the host's network namespace (the downloads reach IMDS and
the storage account from the bridge network). /tmp/vm-init-files is bind-mounted at the same
path for those downloads.

## using azcollection

This is an alternative, but the docker container size is 1.6 GB instead of ~100MB, and the build is slow.

```yaml

write_files:
  - path: /opt/cirrus-ansible/image/Dockerfile
    permissions: "0644"
    content: |
      FROM python:3.13-slim
      ENV PIP_NO_CACHE_DIR=1 \
          PIP_DISABLE_PIP_VERSION_CHECK=1 \
          PIP_ROOT_USER_ACTION=ignore
      RUN pip install ansible-core==2.21.5 \
       && ansible-galaxy collection install community.docker:==5.4.0 azure.azcollection:==4.1.0 \
       && pip install -r /root/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt

  - path: /opt/cirrus-ansible/ansible.cfg
    permissions: "0644"
    content: |
      # Settings for the controller container (ANSIBLE_CONFIG in run-ansible.sh).
      [defaults]
      inventory = /ansible/inventory.yml
      # The container's python, for tasks delegated to localhost; the vm host sets its own in
      # inventory.yml.
      interpreter_python = /usr/local/bin/python3
      nocolor = true
      callback_result_format = yaml
      retry_files_enabled = false

  - path: /opt/cirrus-ansible/inventory.yml
    permissions: "0644"
    content: |
      ---
      all:
        hosts:
          vm:
            ansible_connection: community.docker.nsenter
            ansible_python_interpreter: /usr/bin/python3

  - path: /opt/cirrus-ansible/vars/vm-init-files.yml
    permissions: "0644"
    content: |
      ---
      vm_init_storage_account: "${ST_NAME}"
      vm_init_storage_container: "${ST_CON_NAME}"
      vm_init_subscription_id: "${SUB_ID}"
      vm_init_resource_group: "${RG_NAME}"
      vm_init_files:
        compose_file: "${compose_file}"
        acme_gts_staging: "${acme_gts_staging}"
        acme_gts: "${acme_gts}"
        acme_le_staging: "${acme_le_staging}"
        acme_le: "${acme_le}"

  # First-boot configuration of the VM. Every task runs on the host (see inventory.yml) except
  # the blob downloads, which tasks/download-init-file.yml delegates to the container.
  - path: /opt/cirrus-ansible/site.yml
    permissions: "0644"
    content: |
      ---
      - name: Configure the Cirrus Docker VM
        hosts: all
        gather_facts: false
        vars_files:
          - /ansible/vars/vm-init-files.yml
        vars:
          # Bind-mounted from the host at the same path by run-ansible.sh, so downloads made
          # inside the container land on the host.
          vm_init_files_dir: /tmp/vm-init-files
        tasks:
          - name: Create the init files directories
            ansible.builtin.file:
              path: "{{ vm_init_files_dir }}/{{ item }}"
              state: directory
              owner: root
              group: root
              mode: "0755"
            loop: "{{ ([''] + (vm_init_files | dict2items | map(attribute='value') | map('dirname') | list)) | unique }}"

          - name: Download the init files one by one as the VM's managed identity
            ansible.builtin.include_tasks: /ansible/tasks/download-init-file.yml
            loop: "{{ vm_init_files | dict2items }}"
            loop_control:
              loop_var: init_file
              label: "{{ init_file.key }}"

          - name: Report the downloaded init files
            ansible.builtin.debug:
              msg: "{{ item.key }}: {{ vm_init_files_dir }}/{{ item.value }}"
            loop: "{{ vm_init_files | dict2items }}"
            loop_control:
              label: "{{ item.key }}"

  # One init file: download it, then set its mode. azure_rm_storageblob needs the Azure SDK,
  # which is in the controller container and not on the host, so the download is delegated to
  # localhost (the container) and writes through the vm_init_files_dir bind mount; the chmod
  # runs on the host like every other task. Retried: IMDS can lag at boot and the identity's
  # role assignments can take minutes to propagate after a from-scratch apply.
  - path: /opt/cirrus-ansible/tasks/download-init-file.yml
    permissions: "0644"
    content: |
      ---
      - name: "Download {{ init_file.key }}"
        azure.azcollection.azure_rm_storageblob:
          auth_source: msi
          subscription_id: "{{ vm_init_subscription_id }}"
          resource_group: "{{ vm_init_resource_group }}"
          storage_account_name: "{{ vm_init_storage_account }}"
          container: "{{ vm_init_storage_container }}"
          blob: "{{ init_file.value }}"
          dest: "{{ vm_init_files_dir }}/{{ init_file.value }}"
          auth_mode: login
          force: true
        delegate_to: localhost
        register: vm_init_download
        retries: 20
        delay: 15
        until: vm_init_download is succeeded

      - name: "Set the mode of {{ init_file.key }}"
        ansible.builtin.file:
          path: "{{ vm_init_files_dir }}/{{ init_file.value }}"
          owner: root
          group: root
          mode: "0644"

  - path: /opt/cirrus/bin/run-ansible.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      dir=/opt/cirrus-ansible
      image=cirrus-ansible:local
      # Where the playbook puts the init files (vm_init_files_dir in site.yml), bind-mounted at
      # the same path so the downloads the container makes land on the host.
      init_files_dir=/tmp/vm-init-files

      if ! docker image inspect "$image" >/dev/null 2>&1; then
        docker build --pull -t "$image" "$dir/image"
      fi

      mkdir -p "$init_files_dir"
      exec docker run --rm --name cirrus-ansible \
        --pid=host --privileged \
        -v "$dir":/ansible:ro \
        -v "$init_files_dir":"$init_files_dir" \
        -e ANSIBLE_CONFIG=/ansible/ansible.cfg \
        "$image" ansible-playbook /ansible/site.yml "$@"
```
