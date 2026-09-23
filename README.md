# OMP Local AI Sandbox

Изолированное локальное окружение для запуска **OMP (oh-my-pi)** с локальными GGUF-моделями через **llama.cpp**, **rootless Podman** и NVIDIA GPU.

Основные цели проекта:

- OMP не видит обычный домашний каталог пользователя;
- агент получает read/write-доступ только к явно выделенному workspace;
- контейнеры запускаются от отдельного host-пользователя `ompai`;
- `llama.cpp` не имеет доступа в интернет;
- OMP имеет интернет для web search/fetch;
- модели не висят постоянно в RAM/VRAM;
- можно хранить несколько GGUF-моделей и переключаться между ними в OMP;
- model store на хосте задаётся через `MODEL_STORE` в конфиге;
- Exa можно использовать как основной поиск, DuckDuckGo — как fallback.

## Архитектура

```text
main user
│
├── $HOME                     # не монтируется в OMP
│
├── ~/AI ───────────────────────────────┐
│                                       │
└───────────────────────────────────────┼─────┐
                                        │     │
                            /srv/ompai/workspace
                                        │
                                 shared ACL
                                        │
                                  user: ompai
                                        │
                              rootless Podman
                         ┌──────────────┴──────────────┐
                         │                             │
                  OMP container                llama.cpp container
                  /workspace RW                MODEL_STORE -> /models RO
                  Internet: yes                Internet: no
                  web search                   NVIDIA GPU via CDI
                         │                             │
                         └──────── omp-llm ────────────┘
```

`ompai` — отдельный системный пользователь с заблокированным login. Даже если процесс выйдет из rootless-контейнера, он должен оказаться в контексте `ompai`, а не вашего основного пользователя.

Дополнительно на весь `user-<uid>.slice` пользователя `ompai` устанавливаются root-owned лимиты RAM, swap, CPU и количества процессов.

---

## Файлы

```text
setup-omp-ai.sh   # идемпотентный installer/updater
omp-ai.conf       # основной конфиг
README.md         # эта документация
```

Конфиг не выполняется через `source`. Скрипт парсит только известные `KEY=VALUE` параметры.

Если в `omp-ai.conf` хранится `EXA_API_KEY`, держите файл с правами `0600`:

```bash
chmod 600 omp-ai.conf
```

---

## Требования

Скрипт рассчитан на **Arch Linux**.

Для NVIDIA ожидаются рабочие host-драйверы. Installer самостоятельно устанавливает необходимые пакеты, включая:

- Podman;
- `crun`;
- netavark / aardvark-dns / pasta;
- NVIDIA Container Toolkit;
- git, curl, rsync, ACL tools и т.д.

GPU внутри rootless Podman подключается через NVIDIA CDI.

---

## Быстрый старт

### 1. Положите файлы рядом

```text
my-local-ai/
├── setup-omp-ai.sh
├── omp-ai.conf
└── README.md
```

### 2. Отредактируйте конфиг

```bash
nano omp-ai.conf
```

Для начала обычно достаточно проверить следующие параметры:

```ini
[models]
MODEL_STORE=/var/lib/ompai/models
MODELS_MAX=1

[search]
EXA_API_KEY=
WEB_SEARCH_PRIMARY=auto
WEB_SEARCH_FALLBACK=duckduckgo
```

### 3. Запустите installer

```bash
chmod +x setup-omp-ai.sh
chmod 600 omp-ai.conf

./setup-omp-ai.sh
```

Скрипт рассчитан на повторные запуски. Если часть окружения уже существует, она переиспользуется или обновляется.

После изменений в `omp-ai.conf` снова запустите:

```bash
./setup-omp-ai.sh
```

Installer пересоздаст генерируемые helper-скрипты с новыми параметрами.

---

# Model store

## `MODEL_STORE`

Путь к моделям задаётся в `omp-ai.conf`:

```ini
MODEL_STORE=/var/lib/ompai/models
```

Можно вынести модели на другой SSD, например:

```ini
MODEL_STORE=/mnt/nvme-ai/llm-models
```

или:

```ini
MODEL_STORE=/srv/llm-models
```

Требования к `MODEL_STORE`:

- путь должен быть абсолютным;
- путь не должен быть `/`;
- путь должен находиться **вне обычного `$HOME`** основного пользователя;
- если путь находится на отдельном диске, убедитесь, что файловая система смонтирована **до** запуска installer/`omp-ai`.

Installer создаёт model store с ограниченными правами. Модели доступны `llama.cpp` read-only.

> Если изменить `MODEL_STORE` после установки, старые модели автоматически не переносятся. Перенесите их самостоятельно либо заново добавьте через `ai-model`, затем повторно запустите `setup-omp-ai.sh`.

---

## Как связаны `MODEL_STORE`, `ai-model` и `--models-dir`

`ai-model` управляет файлами в host-каталоге `MODEL_STORE`.

Например:

```bash
ai-model add ~/Downloads/Qwen-8B-Q4_K_M.gguf
```

при:

```ini
MODEL_STORE=/mnt/nvme-ai/llm-models
```

создаёт примерно:

```text
/mnt/nvme-ai/llm-models/
└── Qwen-8B-Q4_K_M.gguf
```

При `omp-ai` этот каталог монтируется в контейнер `llama.cpp`:

```text
HOST MODEL_STORE
      ↓ read-only bind mount
/models
```

и `llama-server` запускается в router mode:

```bash
llama-server \
  --models-dir /models \
  --models-max 1 \
  --models-autoload
```

То есть:

```text
ai-model add/remove/replace
        ↓
изменяет MODEL_STORE на диске
        ↓
следующий omp-ai
        ↓
llama.cpp заново сканирует --models-dir /models
        ↓
OMP runtime discovery
        ↓
/model
```

Изменять model store во время активной OMP-сессии запрещено специально: после остановки router следующий запуск гарантированно увидит актуальный каталог.

---

# Управление моделями

## Добавить GGUF

```bash
ai-model add ~/Downloads/Qwen-8B-Q4_K_M.gguf
```

Несколько сразу:

```bash
ai-model add \
  ~/Downloads/model-a.gguf \
  ~/Downloads/model-b.gguf
```

## Посмотреть модели

```bash
ai-model list
```

## Узнать текущий model store

```bash
ai-model path
```

Это особенно удобно, если `MODEL_STORE` вынесен на другой диск.

## Заменить модель

Если файл с таким basename уже есть:

```bash
ai-model replace ~/Downloads/Qwen-8B-Q4_K_M.gguf
```

## Удалить

```bash
ai-model remove Qwen-8B-Q4_K_M.gguf
```

---

## Multimodal и sharded модели

`ai-model add` принимает не только отдельный `.gguf`, но и каталог, представляющий один model bundle.

Например:

```text
~/Downloads/gemma-vision/
├── gemma.gguf
└── mmproj-F16.gguf
```

Добавление:

```bash
ai-model add ~/Downloads/gemma-vision
```

В model store появится:

```text
MODEL_STORE/
└── gemma-vision/
    ├── gemma.gguf
    └── mmproj-F16.gguf
```

Аналогично можно хранить sharded GGUF-модель в отдельном каталоге.

Каталоги с symlink'ами importer намеренно отвергает.

---

# `MODELS_MAX`

В конфиге:

```ini
MODELS_MAX=1
```

Это максимальное количество model instances, которое router может держать загруженным одновременно.

Для системы с примерно **32 GiB RAM и 8 GiB VRAM** рекомендуется оставить:

```ini
MODELS_MAX=1
```

На диске при этом может лежать сколько угодно моделей.

`MODELS_MAX=1` не запрещает переключение между моделями — он только не позволяет router держать несколько больших моделей резидентными одновременно.

---

# Запуск OMP

После установки:

```bash
cd ~/AI
omp-ai
```

Если работаете над конкретным проектом:

```bash
cd ~/AI/my-project
omp-ai
```

OMP увидит текущую директорию как соответствующий путь внутри `/workspace`, но не увидит обычный `$HOME`.

В OMP выберите модель командой:

```text
/model
```

OMP использует встроенный runtime discovery провайдера `llama.cpp`, поэтому статический список локальных моделей в `models.yml` не нужен.

---

## Жизненный цикл RAM/VRAM

До запуска:

```text
llama.cpp router: stopped
models in RAM:    none
models in VRAM:   none
```

При:

```bash
omp-ai
```

происходит:

1. запускается `llama.cpp` router;
2. router обнаруживает модели в `MODEL_STORE` через `/models`;
3. запускается OMP;
4. выбранная/запрошенная модель загружается по требованию;
5. при выходе из OMP контейнеры удаляются;
6. RAM/VRAM освобождаются.

Если launcher был аварийно убит, systemd reaper периодически удаляет осиротевшие `ompai-agent` / `ompai-llama` контейнеры.

---

# Workspace

Единственная обычная директория данных, которую OMP получает read/write:

```ini
WORKSPACE=/srv/ompai/workspace
```

Для основного пользователя installer создаёт удобную ссылку:

```text
~/AI -> /srv/ompai/workspace
```

Файл можно передать агенту командой:

```bash
ai-give ~/Downloads/report.pdf
```

или сразу несколько:

```bash
ai-give ~/Downloads/a.pdf ~/Downloads/data.csv
```

Можно также работать прямо внутри `~/AI` обычными редакторами:

```bash
code ~/AI/my-project
```

## Важная граница доверия

Всё, что находится внутри `~/AI`, следует считать полностью доступным агенту:

- чтение;
- изменение;
- удаление;
- выполнение;
- потенциальная отправка в интернет.

Не кладите туда SSH-ключи, production credentials, приватные `.env` и другие секреты, если не готовы дать их агенту.

---

# Web search

По умолчанию:

```ini
WEB_SEARCH_PRIMARY=auto
WEB_SEARCH_FALLBACK=duckduckgo
```

Поведение `auto`:

```text
EXA_API_KEY задан    -> Exa primary
EXA_API_KEY пустой   -> DuckDuckGo primary
```

Exa key:

```ini
EXA_API_KEY=...
```

Installer переносит его в защищённый secret env-файл вне `~/AI`.

Важно: OMP получает ключ как environment variable. Это защищает его от случайного попадания в workspace, но **не скрывает ключ от самого полностью скомпрометированного OMP-процесса**.

---

# Полезные команды

```bash
# запуск
omp-ai

# статус контейнеров
omp-ai status

# live logs llama.cpp
omp-ai logs

# принудительно остановить AI и освободить RAM/VRAM
omp-ai stop

# добавить данные в workspace
ai-give FILE_OR_DIR [...]

# управление моделями
ai-model add FILE_OR_DIR [...]
ai-model replace FILE_OR_DIR [...]
ai-model remove NAME [...]
ai-model list
ai-model path
```

---

# Основные параметры конфига

## Models

```ini
MODEL_STORE=/var/lib/ompai/models
MODELS_MAX=1
LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda
LLAMA_CTX=8192
LLAMA_MEM=22g
VRAM_RESERVE_MIB=2048
LLAMA_PORT=18080
```

`MODEL=` можно указывать несколько раз для первоначального импорта во время setup:

```ini
MODEL=~/Downloads/model-a.gguf
MODEL=~/Downloads/model-b.gguf
```

После установки обычно удобнее пользоваться `ai-model add`.

## Search

```ini
EXA_API_KEY=
WEB_SEARCH_PRIMARY=auto
WEB_SEARCH_FALLBACK=duckduckgo
```

## OMP

```ini
OMP_REPO=https://github.com/can1357/oh-my-pi.git
OMP_REF=main
OMP_MEM=3g
```

## Isolation

```ini
AI_USER=ompai
AI_HOME=/var/lib/ompai
SHARE_GROUP=ompai-share
WORKSPACE=/srv/ompai/workspace
AI_SLICE_MEM=25G
AI_SLICE_CPU=2400%
HARDEN_HOME=true
```

---

# Безопасность

Основные слои защиты:

1. отдельный host-user `ompai`;
2. rootless Podman;
3. user namespaces;
4. read-only container root filesystem;
5. `cap-drop=ALL`;
6. `no-new-privileges`;
7. root-owned systemd cgroup limits;
8. `$HOME` основного пользователя рекомендуется сделать `0700`;
9. в OMP монтируется только workspace и внутренний state;
10. model store монтируется только в `llama.cpp` и только read-only;
11. `llama.cpp` работает в internal Podman network и запускается с `--offline`;
12. OMP имеет отдельный network с интернетом.

Это не эквивалент отдельной VM: rootless containers всё равно используют ядро host Linux.

---

# Повторный запуск installer

`setup-omp-ai.sh` задуман как идемпотентный installer/updater.

После изменения, например:

```ini
MODEL_STORE=/mnt/nvme-ai/models
LLAMA_CTX=16384
VRAM_RESERVE_MIB=3072
```

примените конфиг:

```bash
./setup-omp-ai.sh
```

Скрипт обновит генерируемые helper'ы и настройки.

**Изменение `MODEL_STORE` само по себе не переносит существующие модели.**

---

# Troubleshooting

## Проверить GPU на host

```bash
nvidia-smi
```

## Проверить доступные NVIDIA CDI devices

```bash
sudo nvidia-ctk cdi list
```

## Посмотреть модели

```bash
ai-model list
ai-model path
```

## Посмотреть llama.cpp logs

```bash
omp-ai logs
```

## Освободить GPU вручную

```bash
omp-ai stop
```

## Проверить Podman пользователя `ompai`

Installer делает это автоматически. Для ручной диагностики проще сначала проверить обычный rootless Podman и NVIDIA CDI на системе, а затем смотреть вывод installer/`omp-ai logs`.

---

# Upstream

- OMP / oh-my-pi: https://github.com/can1357/oh-my-pi
- llama.cpp server: https://github.com/ggml-org/llama.cpp/tree/master/tools/server
- Podman: https://podman.io/
- NVIDIA Container Toolkit / CDI: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html
