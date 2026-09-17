# bootstrap_pub

Публичный, самодостаточный bootstrap для чистых Ubuntu VPS и VM. Репозиторий не содержит токенов, паролей или приватных ключей: персональный конфиг создаётся только на сервере и хранится в `/etc/homelab-bootstrap/bootstrap.env` с правами `0600`.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash
```

На минимальной Ubuntu без `curl`:

```bash
sudo apt-get update && sudo apt-get install -y --no-install-recommends curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash
```

GitHub token и Deploy Key не требуются.

## Настройка перед установкой

При первом запуске выберите:

- `wizard` — заполнить параметры вопросами в консоли;
- `editor` — открыть полный конфиг в `nano` или `vi`.

Можно указать режим сразу:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --config-mode wizard
```

или:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --config-mode editor
```

Если нужно начать настройку заново без редактора, старый конфиг будет сохранён в backup, а консольный мастер задаст вопросы повторно:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --reset-config --config-mode wizard
```

Перед применением установщик проверяет конфиг и показывает итоговый план. Чтобы только создать и проверить конфиг:

```bash
curl -fsSL https://raw.githubusercontent.com/Kimoko/bootstrap_pub/main/install.sh | sudo bash -s -- --configure-only
```

## Что устанавливается

Bootstrap обновляет Ubuntu, создаёт администратора, устанавливает его публичный SSH-ключ, настраивает OpenSSH, UFW, fail2ban, unattended-upgrades и базовый sysctl hardening. Docker и swapfile включаются настройками.

Исходники устанавливаются в `/opt/homelab-bootstrap`. Существующий конфиг при повторном запуске не перезаписывается.

> Сначала запускайте на тестовой VM. Bootstrap меняет пакеты, SSH, firewall и systemd-службы и может повлиять на доступность сервера.

## Секреты

Не добавляйте в репозиторий:

- реальные `.env`;
- пароли и токены;
- приватные SSH-ключи;
- сертификаты и VPN-конфиги с ключами.
