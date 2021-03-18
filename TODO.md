# Список необходимых доработок

##### build_ubuntu_livecd.sh

* Перейти на использование systemd-networkd вместо ifupdown;
* Вынести формирование /etc/hosts из скрипта cloud-network.sh на этап сборки ISO-образа;
* Удалить юнит unmount_cdrom.service и подправить casper-скрипты, чтобы не удалял cdrom.mount юнит;

##### control_vm_esxi.sh

* Добавить новые параметры `esxi_ssh_connect_timeout`, `vm_ssh_connect_timeout`, `vm_deploy_script_path`;
* Добавить новые команды 'deploy' (с подстветкой неотдеплоенных нод в команде 'ls'), 'up', 'down';
* Добавить вывод прогресса копирования ISO-образа на гипервизор;
