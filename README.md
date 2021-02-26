# Скрипты для работы с diskless-нодами на ESXi

Проект для запуска и работы с `diskless`-нодами на `VmWare ESXi` гипервизоре. \
Состоит из нескольких простых в использовании `BASH`-скриптов:

## build_ubuntu_livecd.sh

Скрипт для сборки `Ubuntu` iso-образа с нуля. На выходе получаем iso загрузочный образ.

##### Системные требования

* cdrkit
* debootstrap
* mkpasswd (from debian 'whois' package)
* squashfs-tools

##### Переменные окружения

|Переменная|Значение по умолчанию|Описание|
|---|:-:|---|
|UBUNTU_ARCH|amd64|Архитектура для которой производится сборка|
|UBUNTU_SUITE|xenial|Версия Ubuntu Linux|
|UBUNTU_ROOT_PASSWORD|examplePassword789|Пароль пользователя 'root'|
|UBUNTU_OUTPUT_ISO_PATH|ubuntu-xenial-amd64-live-v1.210212.iso|Путь до результирующего iso образа|
