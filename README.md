# Скрипты для работы с diskless-нодами на ESXi

Проект для запуска и работы с `diskless`-нодами на `VmWare ESXi` гипервизоре. \
Состоит из нескольких простых в использовании `BASH`-скриптов.
Скрипты оформлены в едином стиле, а чтобы получить подсказки по использованию,
а также значения используемых переменных, ровно как и список необходимых зависимостей,
достаточно просто их запустить.

## build_iso_images.sh

Скрипт для сборки загрузочных iso-образов с нуля.

##### Системные требования

* debootstrap (для базовых слоёв `ubuntu-*`)
* genisoimage (может быть отдельным пакетом или в составе `cdrkit` или `wodim` пакетов)
* git
* mkpasswd (для базовых слоёв `ubuntu-*`, идёт в составе `whois` пакета)
* squashfs-tools (для базовых слоёв `ubuntu-*`)

#### Запуск в **Docker**

Для запуска сборки образов в Docker можно использовать следующую последовательность команд:

```bash
$ docker build -t esxi-diskless .
$ docker run --rm -v /proc:/proc -v `pwd`:/build --cap-add=SYS_ADMIN esxi-diskless ./build_iso_images.sh
```

## control_vm_esxi.sh

Скрипт для управления `diskless`-виртуальным машинами на `ESXi` гипервизоре.

##### Системные требования

* govc из состава [gomomi](https://github.com/vmware/govmomi) проекта
* openssh
* sshpass

#### Запуск в **Docker**

Подобным образом этот скрипт также можно запускать в Docker следующей последовательностью команд:

```bash
$ docker build -t esxi-diskless .
$ docker run --rm -v `pwd`:/build esxi-diskless ./control_vm_esxi.sh
```
