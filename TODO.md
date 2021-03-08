# Список необходимых доработок

##### build_ubuntu_livecd.sh

* Перейти на использование systemd-networkd вместо ifupdown;

##### control_vm_esxi.sh

* Добавить новые параметры `esxi_ssh_connect_timeout`, `vm_ssh_connect_timeout`, `vm_deploy_script_path`;
* Добавить новые команды 'deploy' (с подстветкой неотдеплоенных нод в команде 'ls'), 'up', 'down';
