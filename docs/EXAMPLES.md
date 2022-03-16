# Примеры использования

### Содержание

* [build_iso_images.sh](#build_iso_imagessh)
* [control_vm_esxi.sh](#control_vm_esxish)

### build_iso_images.sh

##### Конфигурационный файл `build_iso_images.ini`

```ini
[xenial-air]
# Сборка 'xenial-air' будет основана на 'ubuntu-xenial-amd64-minbase' базовом слое
base_layer="ubuntu-xenial-amd64-minbase"
# В папку '/opt/workset' будет склонирован GIT-репозитарий с глубиной в 1 потомок и переключен на 'master'-ветку.
repo_url="git@server:user/repo_name.git"
repo_clone_into="opt/workset/"
repo_checkout="master"
repo_depth=1

[xenial-bro]
# Сборка 'xenial-bro' будет основана только на базовом слое
base_layer="ubuntu-xenial-amd64-minbase"

[xenial-pup]
# Сборка 'xenial-pup' будет основана на 'ubuntu-xenial-amd64-minbase' базовом слое
base_layer="ubuntu-xenial-amd64-minbase"
# В папку '/opr/workset' будет склонирован GIT-репозитарий с глубиной в 2 потомка и переключен на 'develop'-ветку
repo_url="git@server:user/repo_name.git"
repo_clone_into="opt/workset/"
repo_checkout="develop"
repo_depth=2
# После чего из репозитария будет запущен скрипт деплоя '/deploy.sh'
run_from_repo="/deploy.sh"
```

##### Примеры использования

Показать список всех шаблонов указанных в конфигурационном файле:
```bash
$ ./build_iso_images.sh ls
```

Использование другого конфигурационного файла:
```bash
$ BUILD_CONFIG_PATH="./path/to/config" ./build_iso_images.sh ls
```

Сборка всех представленных в конфигурационном файле шаблонов:
```bash
$ sudo ./build_iso_images.sh build all
```

Сборка только `xenial-air` шаблона:
```bash
$ sudo ./build_iso_images.sh build xenial-air
```

Сборка только `xenial-bro` шаблона с пересборкой, если шаблон уже имеется (опция `-f`):
```bash
$ sudo ./build_iso_images.sh build -f xenial-bro
```

### control_vm_esxi.sh

##### Конфигурационный файл `control_vm_esxi.ini`

```ini
[defaults]
# Задаём значения по умолчанию для некоторых параметров, значения остальных определены в самом скрипте
local_iso_path=xenial-bro-211227-63f26add.iso
vm_esxi_datastore=hdd1
vm_ipv4_gateway=127.0.0.1
vm_network_name="wan"

[esxi_list]
esxi1 \
  esxi_hostname="esxi1.localnet" \
  esxi_ssh_password="password1"
esxi2 \
  esxi_hostname="esxi2.localnet" \
  esxi_ssh_password="password2"
esxi3 \
  esxi_hostname="esxi3.localnet" \
  esxi_ssh_password="password3" \
  # Переопределяем параметр 'vm_memory_mb' для всех виртуальных машин на этом гипервизоре
  vm_memory_mb=2048

[vm_list]
vm-example10 at="esxi2" \
  vm_autostart="yes" \
  vm_ipv4_address="127.0.0.11" \
  vm_mac_address="00:01:02-03:04:05" \
  vm_memory_mb=2048

vm1-example11 at="esxi3" vm_ipv4_address="127.0.0.12"

vm-example12 at="esxi2" \
  vm_autostart="yes" \
  vm_ipv4_address="127.0.0.13" \
  vm_memory_mb=1024 \
  local_iso_path="" \
  local_vmdk_path="ubuntu-focal.vmdk" \
  vm_hdd_gb="10"
```

##### Примеры использования

Создание всех виртуальных машин на `esxi1` и `esxi2` гипервизорах с информированием о необходимости
включения менеджера автостарта виртуальных машин где это необходимо (опция `-da`):
```bash
$ ./control_vm_esxi.sh create -da esxi1 esxi2
```

Создание виртуальной машины `vm-example11` без построение полной карты расположения виртуальных машин (опция `-n`)
и пересозданием в случае, если виртуальная машина уже присутсвует на гипервизоре (опция `-f`):
```bash
$ ./control_vm_esxi.sh create -f -n vm-example11
```

Создание виртуальной машины `vm-example12` и уничтожение на другом гипервизоре, в случае обнаружение одноименной
виртуальной машины (опция `-d`):
```bash
$ ./control_vm_esxi.sh create -d vm-example12
```

Уничтожение виртуальной машины `vm-example10` с принудительным выключением, если `vmware-tools` не запущен (опция `-fs`):
```bash
$ ./control_vm_esxi.sh destroy -fs vm-example10
```

Уничтожение виртуальной машины `test1` на `esxi2` гипервизоре, не описанной в конфигурационном файле и пропуском
удаления неиспользуемых `ISO`-образов и `HDD`-шаблонов на гипервизоре (опция `-sr`):
```bash
$ ./control_vm_esxi.sh destroy -sr esxi2/test1
```

Уничтожение виртуальной машины `vm-example12` с `HDD`-диском (опция `-ed`):
```bash
$ ./control_vm_esxi.sh destroy -ed vm-exmaple12
```

Отображение виденья всего конфигурационного файла скриптом:
```bash
$ ./control_vm_esxi.sh ls all
```

Отображение виденья настроек для `esxiz` гипервизора в другом конфигурационном файле без проверки сетевой доступности
(опция `-n`):
```bash
ESXI_CONFIG_PATH=./another.ini ./control_vm_esxi.sh ls esxiz -n
```

Перезагрузка `vm-example12` виртуальной машины с принудительным сбросом, если `vmware-tools` не запущен (опция `-fr`):
```bash
$ ./control_vm_esxi.sh reboot -fr vm-example12
```

Показ разницы настроек между конфигурационном файлом и `esxi3` гипервизором с игнорированием других недоступных
гипервизоров при построении полной карты расположения виртуальных машин (опция `-i`):
```bash
$ ./control_vm_esxi.sh show -i esxi3
```

Показ разницы настроек без использования кеша (переменная окружения CACHE_VALID="-"), т.е. актуального на данный
момент состояния для `vm-example10` виртуальной машины без построения полной карты расположения виртуальных машин (опция `-n`):
```bash
$ CACHE_VALID="-" ./control_vm_esxi.sh show -n vm-example10
```

Включение ранее выключенной виртуальной машины `vm-example10`:
```bash
$ ./control_vm_esxi.sh start vm-example10
```

Выключение виртуальной машины `test3` на `esxi1` гипервизоре, не описанной в конфигурационном файле с принудительным
выключением, если `vmware-tools` не запущен (опция `-fs`):
```bash
$ ./control_vm_esxi.sh stop -fs esxi1/test3
```

Замена `ISO`-образов на лету для всех виртуальных машин на `esxi2`-гипервизоре, с принудительной проверкой
контрольных сумм уже имеющихся на гипервизоре образах (опция `-ff`):
```bash
./control_vm_esxi.sh update local_iso_path -ff esxi2
```

Отложенное обновление (применится после перезагрузки виртуальной машины) адреса DNS-cерверов для
виртуальной машины `vm-example10`:
```bash
./control_vm_esxi.sh update vm_dns_servers vm-example10
```

Предварительная загрузка необходимых `ISO`-образов и `HDD`-шаблонов на все гипервизоры:
```bash
./control_vm_esxi.sh upload all
```

Предварительная загрузка необходимых `ISO`-образов и `HDD`-шаблонов для `vm-example10` и `vm-example12` виртуальных
машин без проверки корректности контрольных сумм в `.sha1`-файлах (т.е. доверяя содержимому `.sha1` файлов) (опция `-t`):
```bash
./control_vm_esxi.sh upload -t vm-example10 vm-example12
```
