# Subscription Monitor — Backend API

REST API на FastAPI (Python) для MVP «Монитор подписок».  
Хакатон «Цифровой вызов» 2026, направление «Фулстэк».

---

## Содержание

1. [Стек технологий](#стек-технологий)
2. [Структура проекта](#структура-проекта)
3. [Установка и запуск](#установка-и-запуск)
4. [Переменные окружения](#переменные-окружения)
5. [Описание эндпоинтов](#описание-эндпоинтов)
   - [Подписки](#подписки)
   - [Аналитика](#аналитика)
   - [Уведомления](#уведомления)
   - [Системные](#системные)
6. [Модель данных](#модель-данных)
7. [Примеры запросов](#примеры-запросов)
8. [Бизнес-логика](#бизнес-логика)
9. [Деплой](#деплой)
10. [Критерии ТЗ и их реализация](#критерии-тз-и-их-реализация)

---

## Стек технологий

| Компонент | Технология | Версия |
|-----------|-----------|--------|
| Язык | Python | 3.10+ |
| Фреймворк | FastAPI | 0.115.0 |
| ASGI-сервер | Uvicorn | 0.30.6 |
| ORM | SQLAlchemy | 2.0.36 |
| База данных | SQLite (dev) / PostgreSQL (prod) | — |
| Валидация | Pydantic | 2.9.2 |
| Планировщик | APScheduler | 3.10.4 |
| Даты | python-dateutil | 2.9.0 |

---

## Структура проекта

```
tiktok-mvp/
└── subscriptions.py   # весь бекенд — один файл
    ├── DB & ORM       # модель Subscription, создание таблиц
    ├── Schemas        # Pydantic-схемы (Create / Update / Out)
    ├── Helpers        # расчёт дат, приведение цены к месячной
    ├── CRUD Routes    # /subscriptions
    ├── Analytics      # /analytics/summary|forecast|history
    ├── Notifications  # /notifications
    └── Scheduler      # фоновая задача — автоперенос дат списания
```

---

## Установка и запуск

### 1. Установить зависимости

```bash
pip3 install fastapi==0.115.0 "uvicorn[standard]==0.30.6" sqlalchemy==2.0.36 python-dateutil==2.9.0 apscheduler==3.10.4 pydantic==2.9.2
```

### 2. Запустить сервер

```bash
# из папки где лежит subscriptions.py
uvicorn subscriptions:app --reload --host 0.0.0.0 --port 8000
```

### 3. Открыть документацию

| URL | Описание |
|-----|----------|
| http://localhost:8000/docs | Swagger UI — интерактивное тестирование |
| http://localhost:8000/redoc | ReDoc — читаемая документация |
| http://localhost:8000/health | Healthcheck |

### 4. База данных

При первом запуске автоматически создаётся файл `subscriptions.db` в той же папке.  
Никаких миграций и настроек не нужно — SQLite создаётся сам.

---

## Переменные окружения

Для разработки переменные не нужны — всё работает из коробки.  
Для продакшена можно задать:

```bash
DATABASE_URL=postgresql://user:password@host:5432/dbname
```

---

## Описание эндпоинтов

### Подписки

#### `GET /subscriptions`
Получить список всех подписок.

**Query-параметры:**

| Параметр | Тип | Описание |
|----------|-----|----------|
| `active_only` | bool | Если `true` — только активные подписки |
| `category` | string | Фильтр по категории |

**Пример ответа:**
```json
[
  {
    "id": 1,
    "name": "Netflix",
    "category": "streaming",
    "price": 799.0,
    "currency": "RUB",
    "period": "monthly",
    "next_payment": "2025-04-15",
    "description": null,
    "is_active": true,
    "created_at": "2025-03-25T10:00:00",
    "days_until_payment": 21
  }
]
```

---

#### `POST /subscriptions`
Создать новую подписку.

**Тело запроса:**
```json
{
  "name": "Netflix",
  "category": "streaming",
  "price": 799,
  "currency": "RUB",
  "period": "monthly",
  "next_payment": "2025-04-15",
  "description": "Семейный тариф"
}
```

**Допустимые значения `period`:** `monthly`, `yearly`, `weekly`

**Допустимые значения `category`:** `streaming`, `software`, `delivery`, `storage`, `other`

---

#### `GET /subscriptions/{id}`
Получить одну подписку по ID.

---

#### `PUT /subscriptions/{id}`
Обновить подписку. Передавай только те поля, которые хочешь изменить.

```json
{
  "price": 899,
  "next_payment": "2025-04-20"
}
```

---

#### `DELETE /subscriptions/{id}`
Удалить подписку навсегда.

---

#### `POST /subscriptions/{id}/pause`
Приостановить подписку (устанавливает `is_active = false`).  
Подписка остаётся в базе, но не учитывается в аналитике и уведомлениях.

---

### Аналитика

#### `GET /analytics/summary`
Сводка по всем активным подпискам.

**Пример ответа:**
```json
{
  "total_monthly": 1497.0,
  "total_yearly": 17964.0,
  "by_category": {
    "streaming": 1098.0,
    "storage": 199.0,
    "software": 200.0
  },
  "by_period": {
    "monthly": 3,
    "yearly": 1
  },
  "active_count": 4
}
```

> Годовые подписки автоматически делятся на 12 для расчёта месячной стоимости.  
> Еженедельные умножаются на 4.33.

---

#### `GET /analytics/forecast`
Прогноз будущих списаний.

Возвращает два блока:
- `next_30_days` — конкретные платежи в ближайшие 30 дней с датами
- `monthly_totals` — суммарные расходы по каждому из следующих 12 месяцев

**Пример ответа:**
```json
{
  "next_30_days": [
    {
      "id": 2,
      "name": "Яндекс 360",
      "price": 199.0,
      "currency": "RUB",
      "date": "2025-03-26",
      "days_left": 1
    }
  ],
  "monthly_totals": [
    { "month": "2025-03", "total": 199.0 },
    { "month": "2025-04", "total": 1298.0 },
    ...
  ]
}
```

---

#### `GET /analytics/history`
История расходов за период (для графиков).

**Query-параметры:**

| Параметр | Тип | По умолчанию |
|----------|-----|--------------|
| `from_date` | date (YYYY-MM-DD) | 6 месяцев назад |
| `to_date` | date (YYYY-MM-DD) | сегодня |

**Пример ответа:**
```json
[
  {
    "month": "2024-10",
    "total": 1298.0,
    "breakdown": {
      "streaming": 1098.0,
      "storage": 199.0
    }
  },
  ...
]
```

---

### Уведомления

#### `GET /notifications`
Подписки, у которых ближайшее списание через N дней.

**Query-параметры:**

| Параметр | Тип | По умолчанию |
|----------|-----|--------------|
| `days_ahead` | int | 3 |

**Пример ответа:**
```json
[
  {
    "id": 2,
    "name": "Spotify",
    "price": 299.0,
    "currency": "RUB",
    "next_payment": "2025-03-27",
    "days_left": 2
  }
]
```

> Фронтенд должен опрашивать этот эндпоинт при запуске приложения и показывать алерты.

---

### Системные

#### `GET /health`
```json
{
  "status": "ok",
  "timestamp": "2025-03-25T10:00:00"
}
```

---

## Модель данных

### Таблица `subscriptions`

| Поле | Тип | Описание |
|------|-----|----------|
| `id` | INTEGER PK | Автоинкремент |
| `name` | TEXT | Название сервиса |
| `category` | TEXT | Категория |
| `price` | REAL | Стоимость списания |
| `currency` | TEXT | Валюта (по умолчанию RUB) |
| `period` | TEXT | Период: monthly / yearly / weekly |
| `next_payment` | DATE | Дата следующего списания |
| `description` | TEXT | Произвольное описание (необязательно) |
| `is_active` | BOOLEAN | Активна ли подписка |
| `created_at` | DATETIME | Дата добавления записи |
| `notified` | BOOLEAN | Флаг: было ли уведомление в текущем цикле |

---

## Примеры запросов

### curl

```bash
# Создать подписку
curl -X POST http://localhost:8000/subscriptions \
  -H "Content-Type: application/json" \
  -d '{"name":"Netflix","category":"streaming","price":799,"period":"monthly","next_payment":"2025-04-15"}'

# Получить все подписки
curl http://localhost:8000/subscriptions

# Получить только активные стриминги
curl "http://localhost:8000/subscriptions?active_only=true&category=streaming"

# Аналитика
curl http://localhost:8000/analytics/summary

# Уведомления на 7 дней вперёд
curl "http://localhost:8000/notifications?days_ahead=7"
```

### JavaScript (fetch)

```javascript
// Создать подписку
const res = await fetch('http://localhost:8000/subscriptions', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    name: 'Spotify',
    category: 'streaming',
    price: 299,
    period: 'monthly',
    next_payment: '2025-03-27'
  })
});
const sub = await res.json();

// Получить аналитику
const analytics = await fetch('http://localhost:8000/analytics/summary').then(r => r.json());
```

---

## Бизнес-логика

### Расчёт месячной стоимости

Для корректной аналитики все подписки приводятся к месячной стоимости:

| Период | Формула |
|--------|---------|
| `monthly` | цена × 1 |
| `yearly` | цена ÷ 12 |
| `weekly` | цена × 4.33 |

### Автоперенос дат списания

Каждую ночь в 00:05 фоновая задача проверяет все активные подписки.  
Если `next_payment` уже прошла — дата автоматически переносится на следующий цикл:

- `monthly` → +1 месяц
- `yearly` → +1 год
- `weekly` → +7 дней

После переноса сбрасывается флаг `notified`, чтобы уведомление пришло снова.

---

## Деплой

### Railway / Render (рекомендуется для хакатона)

1. Загрузи код в GitHub
2. Создай новый проект на [railway.app](https://railway.app) или [render.com](https://render.com)
3. Укажи команду запуска:
```bash
uvicorn subscriptions:app --host 0.0.0.0 --port $PORT
```
4. Для продакшена добавь PostgreSQL и переменную:
```
DATABASE_URL=postgresql://...
```
5. В `subscriptions.py` замени строку:
```python
DATABASE_URL = "sqlite:///./subscriptions.db"
# на:
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./subscriptions.db")
```
И добавь в начало файла: `import os`

---

## Критерии ТЗ и их реализация

| # | Критерий | Реализация |
|---|----------|------------|
| 1 | Единый бекенд для мобилки и веба | ✅ REST API с CORS — подключается любой клиент |
| 3 | Аутентификация | ⚡ Намеренно убрана для MVP (добавляется за 30 минут) |
| 4 | CRUD подписок с ценой, периодом, категорией | ✅ POST / GET / PUT / DELETE `/subscriptions` |
| 5 | Автоимпорт (хотя бы 1 метод) | 🔧 Эндпоинты готовы — нужно подключить парсер почты или платёжный API |
| 6 | Аналитика с визуализацией расходов | ✅ `/analytics/summary`, `/analytics/history` — данные для графиков |
| 7 | Уведомления о предстоящих списаниях | ✅ `/notifications?days_ahead=3` |
| 8 | Синхронизация между мобилкой и вебом | ✅ Единая БД, один API для всех клиентов |
| 9 | Прогноз месячных/годовых затрат | ✅ `/analytics/forecast` — 30 дней и 12 месяцев |
