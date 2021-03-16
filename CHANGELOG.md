# История изменений

##### build_ubuntu_livecd.sh

v1.??????
- Добавлена поддержка распаковки .tgz архивов из provision_files/
- Добавлена поддержка установки hostname виртуальной машины из `guestinfo.hostname` параметра
- Теперь по умолчанию используется `8.8.8.8` в качестве DNS сервера

##### control_vm_esxi.sh

v1.??????
- Добавлена установка параметра виртуальной машины `guestinfo.hostname`
- Добавлен параметр `StrictHostKeyChecking=no` для ssh
