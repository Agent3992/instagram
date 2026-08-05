# Backend: архитектура и API (этап 2)

Этот документ фиксирует контракт backend до написания контроллеров и frontend. Выбранный стек:

- **Node.js 20 + TypeScript**;
- **Express** — HTTP API;
- **Prisma** — типизированный доступ к PostgreSQL;
- **Zod** — валидация входных данных и конфигурации;
- **Argon2id** — хеширование паролей;
- **jose** — подпись и проверка JWT;
- **Socket.IO** — Direct и in-app события;
- **S3/MinIO** — хранение медиа, PostgreSQL хранит только URL и метаданные.

## Структура модулей

```text
backend/
├── src/
│   ├── app.ts                 # Express, middleware, роуты
│   ├── server.ts              # HTTP + Socket.IO bootstrap
│   ├── config/env.ts          # Zod-проверка ENV
│   ├── db/prisma.ts           # один PrismaClient на процесс
│   ├── middleware/
│   │   ├── auth.ts            # Bearer JWT и req.user
│   │   ├── error.ts           # единый формат ошибок
│   │   └── validate.ts        # Zod schemas
│   ├── modules/
│   │   ├── auth/              # register, login, refresh, logout
│   │   ├── users/             # профиль, поиск, блокировки
│   │   ├── follows/           # follow requests, accept, unfollow
│   │   ├── posts/             # posts, media, feed, likes, comments
│   │   ├── stories/           # stories и просмотры
│   │   ├── messages/          # direct/group chat
│   │   ├── notifications/     # in-app и push queue
│   │   └── explore/           # поиск и рекомендации
│   ├── routes/v1.ts           # mount всех HTTP-модулей
│   └── realtime/socket.ts     # Socket.IO authentication/events
└── prisma/schema.prisma       # ORM-модели, синхронизированные с db/schema.sql
```

Каждый модуль разделен на `*.router.ts`, `*.controller.ts`, `*.service.ts`, `*.repository.ts` и `*.schema.ts`. Контроллер только разбирает HTTP-запрос и формирует ответ; правила доступа находятся в service, SQL/Prisma-запросы — в repository.

## Модели и связи

Основные Prisma-модели соответствуют SQL-схеме из [`../db/schema.sql`](../db/schema.sql):

| Модель | Связи и назначение |
|---|---|
| `User` | `posts`, `comments`, `likes`, `stories`; две связи `Follow` (follower/following); sender/receiver для `Message`; user/actor для `Notification`. |
| `Follow` | `followerId -> User`, `followingId -> User`, уникальная пара, `status = pending/accepted`. |
| `Post` | владелец `User`, `PostMedia`, `Like`, `Comment`; сортировка по `createdAt`. |
| `PostMedia` | несколько media-строк одного поста, порядок через `orderIndex`. |
| `Like` | уникальная пара `userId + postId`. |
| `Comment` | пост, автор и необязательный `parentId` для ответов. |
| `Story` | автор и `expiresAt`; `StoryView` уникален на пару story/user. |
| `Message` | direct-сообщение sender → receiver, текст и/или media URL. |
| `Notification` | получатель, необязательный actor, тип и полиморфный `entityId`. |

Для полного набора требований перед реализацией соответствующих модулей нужны отдельные миграции: `RefreshSession`, `EmailVerificationToken`, `PasswordResetToken`, `UserBlock`, `Conversation`, `ConversationMember`, `Hashtag`, `PostHashtag`, `PostMention` и `Repost`. Базовая SQL-схема намеренно ограничена таблицами пункта 1.

## HTTP API v1

Все маршруты имеют префикс `/api/v1`. Успешный ответ имеет форму:

```json
{
  "data": {},
  "meta": { "requestId": "..." }
}
```

Ошибки:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid request",
    "details": [{ "path": "email", "message": "Invalid email" }]
  },
  "meta": { "requestId": "..." }
}
```

### Авторизация и безопасность

| Метод | Путь | Auth | Назначение |
|---|---|---|---|
| `POST` | `/auth/register` | нет | Создать пользователя, захешировать пароль Argon2id, отправить email verification. |
| `POST` | `/auth/login` | нет | Проверить email/password, вернуть access JWT и refresh cookie. |
| `POST` | `/auth/refresh` | refresh cookie | Rotation refresh token, отзыв предыдущей сессии. |
| `POST` | `/auth/logout` | access/refresh | Отозвать текущую refresh-сессию. |
| `GET` | `/auth/verify-email?token=...` | нет | Подтвердить email однократным токеном. |
| `POST` | `/auth/forgot-password` | нет | Отправить одноразовую ссылку без раскрытия существования email. |
| `POST` | `/auth/reset-password` | нет | Установить новый пароль по одноразовому токену. |
| `POST` | `/auth/change-password` | access | Проверить старый пароль, изменить пароль и отозвать refresh-сессии. |
| `GET` | `/auth/me` | access | Вернуть текущего пользователя. |

Access JWT короткоживущий (например, 15 минут) и передается в `Authorization: Bearer <token>`. Refresh token живет дольше (например, 30 дней), хранится в `HttpOnly`, `Secure`, `SameSite=Lax` cookie; в БД хранится только его хеш. При rotation повторное использование старого токена отзывает всю token family.

### Профили и подписки

| Метод | Путь | Auth | Назначение |
|---|---|---|---|
| `GET` | `/users/:username` | optional | Публичный профиль с учетом privacy и block rules. |
| `PATCH` | `/users/me` | access | Изменить `username`, `fullName`, `bio`, `avatarUrl`, `isPrivate`. |
| `POST` | `/users/me/avatar/presign` | access | Получить presigned upload URL для S3/MinIO. |
| `GET` | `/users/search?q=&cursor=` | optional | Поиск по username/full name, cursor pagination. |
| `POST` | `/users/:id/follow` | access | Создать `accepted` или `pending` follow request. |
| `DELETE` | `/users/:id/follow` | access | Отписаться или отменить pending-запрос. |
| `POST` | `/users/:id/follow/accept` | access | Принять запрос на приватный аккаунт. |
| `POST` | `/users/:id/follow/decline` | access | Отклонить запрос. |
| `GET` | `/users/me/follow-requests` | access | Список входящих pending-запросов. |
| `POST` | `/users/:id/block` | access | Добавить пользователя в blacklist; скрыть взаимный контент. |
| `DELETE` | `/users/:id/block` | access | Снять блокировку. |

Проверка доступа к приватному пользователю выполняется в одном service-методе: владелец, accepted follower или публичные поля профиля. При блокировке API не возвращает заблокированного пользователя в поиске, ленте и рекомендациях.

### Посты, лента и взаимодействия

| Метод | Путь | Auth | Назначение |
|---|---|---|---|
| `POST` | `/posts` | access | Создать пост и media rows в одной транзакции; нужен минимум один media item. |
| `GET` | `/posts/:id` | optional | Получить пост, media, счетчики и viewer state. |
| `DELETE` | `/posts/:id` | access | Удалить собственный пост и каскадные media/likes/comments. |
| `GET` | `/feed?cursor=&limit=` | access | Хронологическая лента accepted follows + собственные посты. |
| `POST` | `/posts/:id/like` | access | Idempotent-like через `INSERT ... ON CONFLICT DO NOTHING`. |
| `DELETE` | `/posts/:id/like` | access | Удалить собственный like. |
| `GET` | `/posts/:id/comments?cursor=` | optional | Получить корневые комментарии и ответы. |
| `POST` | `/posts/:id/comments` | access | Добавить корневой комментарий или ответ с `parentId`. |
| `DELETE` | `/comments/:id` | access | Удалить собственный комментарий или комментарий владельцу поста. |
| `GET` | `/explore?cursor=` | access | Публичная/рекомендованная лента с cursor pagination. |
| `GET` | `/search/hashtags?q=&cursor=` | optional | Поиск хештегов после добавления hashtag-моделей. |

Для стабильной пагинации используется cursor из `(createdAt, id)`, а не `OFFSET`. Лента сначала получает разрешенные `following_id` из `follows`, затем выбирает posts по индексу `posts_user_created_idx`. Like/comment counters можно получить агрегатами или денормализованными счетчиками в следующей оптимизационной итерации.

### Stories

| Метод | Путь | Auth | Назначение |
|---|---|---|---|
| `POST` | `/stories` | access | Создать story, `expiresAt` по умолчанию `createdAt + 24h`. |
| `GET` | `/stories/feed` | access | Активные stories accepted follows, только `expiresAt > now()`. |
| `GET` | `/stories/:id` | access | Открыть story и зарегистрировать view через upsert. |
| `GET` | `/stories/:id/views` | access | Владелец получает список viewers. |
| `DELETE` | `/stories/:id` | access | Удалить собственную story. |

Ответ на story в Direct требует дополнительного `replyToStoryId` в messaging migration; в текущей таблице `messages` сохранен ровно контракт пункта 1.

### Direct, уведомления и realtime

| Метод | Путь | Auth | Назначение |
|---|---|---|---|
| `GET` | `/conversations` | access | Список личных/групповых чатов после добавления conversation-моделей. |
| `GET` | `/conversations/:id/messages?cursor=` | access | История сообщений участника. |
| `POST` | `/conversations/:id/messages` | access | Отправить текст/media. |
| `PATCH` | `/conversations/:id/read` | access | Пометить сообщения прочитанными. |
| `GET` | `/notifications?cursor=` | access | In-app уведомления. |
| `PATCH` | `/notifications/:id/read` | access | Пометить уведомление прочитанным. |
| `POST` | `/notifications/read-all` | access | Прочитать все уведомления пользователя. |

Socket.IO namespace `/realtime` проверяет access JWT при handshake. Клиент входит в комнаты `user:{userId}` и `conversation:{conversationId}`. События:

```text
message:send       client -> server
message:new        server -> conversation members
message:read       client -> server
message:read       server -> sender and receiver
typing:start      client -> server
typing:stop       client -> server
presence:update   server -> relevant users
notification:new  server -> user:{userId}
```

Socket-события не являются источником истины: сообщение сначала сохраняется в транзакции, после commit публикуется через Socket.IO. Для нескольких backend-инстансов используется Redis adapter.

## Общий pipeline запроса

1. `helmet`, CORS allowlist, JSON size limit и rate limit.
2. `requestId` middleware и structured logging.
3. `auth` middleware проверяет JWT и загружает минимальный `userId`.
4. `validate` проверяет params/query/body через Zod.
5. Controller вызывает service.
6. Service проверяет ownership/privacy и открывает короткую Prisma transaction.
7. Repository выполняет запросы с cursor pagination.
8. Error middleware превращает известные ошибки в стабильные `code` и HTTP status.

Нельзя логировать пароль, access/refresh token, cookie и приватные сообщения. Login/register/forgot-password должны иметь отдельный rate limit; ответы `forgot-password` одинаковы для существующего и несуществующего email.

## Порядок реализации

1. Подключить Prisma к существующей `db/schema.sql`, добавить конфигурацию и health-check.
2. Реализовать auth: register/login/refresh/logout/me.
3. Реализовать profiles, follows и privacy checks.
4. Реализовать posts/media/feed/likes/comments.
5. Добавить migrations для refresh sessions, blocks и conversations.
6. Реализовать stories, notifications и Socket.IO.
7. Добавить Explore, hashtags, mentions, reposts и рекомендации.
