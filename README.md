# bootstrap_pub

## Одна команда

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash
```

На минимальной Ubuntu без `curl`:

```bash
sudo apt-get update && sudo apt-get install -y --no-install-recommends curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash
```

Launcher:

1. без эха запрашивает fine-grained GitHub token;
2. загружает `install.sh` из приватного bootstrap;
3. проверяет Bash-синтаксис загруженного файла;
4. передаёт управление приватному установщику;
5. удаляет временный токен и файлы при завершении.

Токен не передаётся в аргументах процессов и не записывается в shell history.

## Права GitHub token

Создайте короткоживущий fine-grained token:

- Repository access: только `Kimoko/homelab-bootstrap`;
- Repository permissions → Contents: `Read-only`;
- остальные разрешения: `No access`;
- expiration: минимально подходящий срок.

Launcher отправляет токен только на `raw.githubusercontent.com`; приватный
установщик использует его для чтения архива через `api.github.com`.

## Настройка перед установкой

При первом запуске установщик предложит один из вариантов:

- `wizard` — заполнить параметры вопросами в консоли;
- `editor` — открыть полный `.env` в `nano` или `vi`.

Конфиг сохраняется отдельно от исходников:

```text
/etc/homelab-bootstrap/bootstrap.env
```

Он принадлежит `root:root`, имеет права `0600`, валидируется до изменения SSH,
firewall, пакетов или служб и не перезаписывается при повторном запуске.

Можно сразу выбрать редактор:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --config-mode editor
```

Или консольный мастер:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --config-mode wizard
```

## Фиксация версии

Для воспроизводимого восстановления используйте тег приватного bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --ref v1.0.0
```

Первый запуск следует выполнять на тестовой VM: приватный bootstrap управляет
пакетами, SSH, UFW и systemd-службами и может повлиять на доступность сервера.

