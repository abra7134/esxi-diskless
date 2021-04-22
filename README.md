# Скрипты для работы с diskless-нодами на ESXi

Проект для запуска и работы с `diskless`-нодами на `VmWare ESXi` гипервизоре. \
Состоит из нескольких простых в использовании `BASH`-скриптов.
Скрипты оформлены в едином стиле, а чтобы получить подсказки по использованию,
а также значения используемых переменных, ровно как и список необходимых зависемостей,
достаточно просто их запустить.

## build_iso_images.sh

Скрипт для сборки загрузочных iso-образов с нуля.

##### Системные требования

* cdrkit
* squashfs-tools

## control_vm_esxi.sh

Скрипт для управления `diskless`-виртуальным машинами на `ESXi` гипервизоре.

##### Системные требования

* openssh
* sshpass
