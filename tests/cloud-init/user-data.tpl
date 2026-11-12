#cloud-config
hostname: qgis-kylin-ci
fqdn: qgis-kylin-ci.local
ssh_pwauth: true
disable_root: false
users:
  - default
  - name: @VM_USER@
    lock_passwd: false
    plain_text_passwd: '@VM_PASSWORD@'
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    groups: wheel
chpasswd:
  expire: false
package_update: false
runcmd:
  - systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  - echo QGIS_CI_CLOUDINIT_OK > /run/qgis-ci-cloudinit-ok
final_message: "QGIS CI cloud-init done after $UPTIME s"
