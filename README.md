# Скрипты для работы с diskless-нодами на ESXi

Проект для запуска и работы с `diskless`-нодами на `VmWare ESXi` гипервизоре. \
Состоит из нескольких простых в использовании `BASH`-скриптов:

## build_ubuntu_livecd.sh

Скрипт для сборки `Ubuntu` iso-образа с нуля. На выходе получаем iso загрузочный образ.

##### Системные требования

* debootstrap
* cdrkit
* squashfs-tools

##### Переменные окружения

|Переменная|Значение по умолчанию|Описание|
|---|:-:|---|
|UBUNTU_ARCH|amd64|Архитектура для которой производится сборка|
|UBUNTU_SUITE|xenial|Версия Ubuntu Linux|
|UBUNTU_ISO_PATH|ubuntu-xenial-amd64-live-v1.iso|Путь до результирующего iso образа|
|UBUNTU_RUN_OPTIONS|textonly toram vga=792|Загрузочные опции|
