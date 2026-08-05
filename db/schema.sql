-- Instagram-like application schema for PostgreSQL
-- Run with: psql "$DATABASE_URL" -f db/schema.sql
-- The script is transactional and can be safely re-run on a fresh database.

BEGIN;

-- UUIDs are generated in the database, so API clients never need to allocate IDs.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Used by the case-insensitive search indexes below. pg_trgm is part of the
-- standard PostgreSQL distribution (contrib) and does not add application data.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS users (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username           varchar(30) NOT NULL,
    email              varchar(320) NOT NULL,
    password_hash      text NOT NULL,
    full_name          varchar(150),
    bio                varchar(500),
    avatar_url         text,
    is_private         boolean NOT NULL DEFAULT false,
    email_verified_at  timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_username_format_ck
        CHECK (username ~ '^[A-Za-z0-9._]{1,30}$'),
    CONSTRAINT users_email_not_blank_ck
        CHECK (length(btrim(email)) > 0),
    CONSTRAINT users_full_name_not_blank_ck
        CHECK (full_name IS NULL OR length(btrim(full_name)) > 0),
    CONSTRAINT users_bio_not_blank_ck
        CHECK (bio IS NULL OR length(btrim(bio)) > 0)
);

-- Both identifiers are unique without treating "Alice" and "alice" as
-- different accounts. The trigram indexes make ILIKE '%term%' lookups useful
-- for user search as well as the normal equality/prefix lookups.
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_uq
    ON users (lower(username));
CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_uq
    ON users (lower(email));
CREATE INDEX IF NOT EXISTS users_username_trgm_idx
    ON users USING gin (lower(username) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS users_full_name_trgm_idx
    ON users USING gin (lower(full_name) gin_trgm_ops);

CREATE TABLE IF NOT EXISTS follows (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    follower_id   uuid NOT NULL,
    following_id  uuid NOT NULL,
    status        varchar(10) NOT NULL DEFAULT 'accepted',
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT follows_follower_fk
        FOREIGN KEY (follower_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT follows_following_fk
        FOREIGN KEY (following_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT follows_no_self_follow_ck
        CHECK (follower_id <> following_id),
    CONSTRAINT follows_status_ck
        CHECK (status IN ('pending', 'accepted')),
    CONSTRAINT follows_follower_following_uq
        UNIQUE (follower_id, following_id)
);

-- One index serves "who does this user follow?" and one serves "who follows
-- this user?". Including status helps private-account feed queries.
CREATE INDEX IF NOT EXISTS follows_follower_status_idx
    ON follows (follower_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS follows_following_status_idx
    ON follows (following_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS posts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL,
    caption     text,
    location    text,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT posts_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT posts_caption_not_blank_ck
        CHECK (caption IS NULL OR length(btrim(caption)) > 0),
    CONSTRAINT posts_location_not_blank_ck
        CHECK (location IS NULL OR length(btrim(location)) > 0)
);

-- The first index is the main subscription-feed access path: fetch a user's
-- posts newest first. The second supports a global chronological feed.
CREATE INDEX IF NOT EXISTS posts_user_created_idx
    ON posts (user_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS posts_created_idx
    ON posts (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS posts_caption_fts_idx
    ON posts USING gin (to_tsvector('simple'::regconfig, coalesce(caption, '')));
CREATE INDEX IF NOT EXISTS posts_location_trgm_idx
    ON posts USING gin (lower(location) gin_trgm_ops);

CREATE TABLE IF NOT EXISTS post_media (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id     uuid NOT NULL,
    media_url   text NOT NULL,
    media_type  varchar(5) NOT NULL,
    order_index integer NOT NULL DEFAULT 0,

    CONSTRAINT post_media_post_fk
        FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
    CONSTRAINT post_media_type_ck
        CHECK (media_type IN ('image', 'video')),
    CONSTRAINT post_media_url_not_blank_ck
        CHECK (length(btrim(media_url)) > 0),
    CONSTRAINT post_media_order_ck
        CHECK (order_index >= 0),
    CONSTRAINT post_media_post_order_uq
        UNIQUE (post_id, order_index)
);

-- The unique constraint already creates an index beginning with post_id and
-- guarantees a deterministic carousel order for every post.

CREATE TABLE IF NOT EXISTS likes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL,
    post_id     uuid NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT likes_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT likes_post_fk
        FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
    CONSTRAINT likes_user_post_uq
        UNIQUE (user_id, post_id)
);

-- The unique index is optimal for "did this user like this post?". This
-- additional index is optimal for counting/listing likes on feed posts.
CREATE INDEX IF NOT EXISTS likes_post_created_idx
    ON likes (post_id, created_at DESC);

CREATE TABLE IF NOT EXISTS comments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id     uuid NOT NULL,
    user_id     uuid NOT NULL,
    parent_id   uuid,
    text        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT comments_post_fk
        FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
    CONSTRAINT comments_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT comments_parent_fk
        FOREIGN KEY (parent_id) REFERENCES comments(id) ON DELETE CASCADE,
    CONSTRAINT comments_text_not_blank_ck
        CHECK (length(btrim(text)) > 0)
);

CREATE INDEX IF NOT EXISTS comments_post_created_idx
    ON comments (post_id, created_at ASC, id ASC);
CREATE INDEX IF NOT EXISTS comments_parent_created_idx
    ON comments (parent_id, created_at ASC, id ASC)
    WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS comments_user_created_idx
    ON comments (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS stories (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL,
    media_url   text NOT NULL,
    expires_at  timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT stories_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT stories_media_url_not_blank_ck
        CHECK (length(btrim(media_url)) > 0),
    CONSTRAINT stories_expiration_ck
        CHECK (expires_at > created_at)
);

-- PostgreSQL cannot use now() in a partial-index predicate because it is not
-- immutable. Query active stories with "expires_at > now()" and use this
-- regular index.
CREATE INDEX IF NOT EXISTS stories_user_created_idx
    ON stories (user_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS stories_user_expires_idx
    ON stories (user_id, expires_at, created_at DESC);
CREATE INDEX IF NOT EXISTS stories_expires_idx
    ON stories (expires_at);

CREATE TABLE IF NOT EXISTS story_views (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    story_id    uuid NOT NULL,
    user_id     uuid NOT NULL,
    viewed_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT story_views_story_fk
        FOREIGN KEY (story_id) REFERENCES stories(id) ON DELETE CASCADE,
    CONSTRAINT story_views_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT story_views_story_user_uq
        UNIQUE (story_id, user_id)
);

CREATE INDEX IF NOT EXISTS story_views_story_viewed_idx
    ON story_views (story_id, viewed_at ASC);
CREATE INDEX IF NOT EXISTS story_views_user_viewed_idx
    ON story_views (user_id, viewed_at DESC);

CREATE TABLE IF NOT EXISTS messages (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id    uuid NOT NULL,
    receiver_id  uuid NOT NULL,
    content      text,
    media_url    text,
    is_read      boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT messages_sender_fk
        FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT messages_receiver_fk
        FOREIGN KEY (receiver_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT messages_no_self_message_ck
        CHECK (sender_id <> receiver_id),
    CONSTRAINT messages_content_or_media_ck
        CHECK (content IS NOT NULL OR media_url IS NOT NULL),
    CONSTRAINT messages_content_not_blank_ck
        CHECK (content IS NULL OR length(btrim(content)) > 0),
    CONSTRAINT messages_media_url_not_blank_ck
        CHECK (media_url IS NULL OR length(btrim(media_url)) > 0)
);

-- Direct-message history is read in either sender/receiver direction. The
-- two directional indexes keep both the inbox and the sent-message query
-- efficient; the unread partial index keeps the common notification query
-- small.
CREATE INDEX IF NOT EXISTS messages_sender_receiver_created_idx
    ON messages (sender_id, receiver_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS messages_receiver_sender_created_idx
    ON messages (receiver_id, sender_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS messages_unread_receiver_idx
    ON messages (receiver_id, created_at DESC)
    WHERE is_read = false;

CREATE TABLE IF NOT EXISTS notifications (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL,
    actor_id    uuid,
    type        varchar(10) NOT NULL,
    entity_id   uuid,
    is_read     boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT notifications_user_fk
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT notifications_actor_fk
        FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT notifications_type_ck
        CHECK (type IN ('like', 'follow', 'comment'))
);

CREATE INDEX IF NOT EXISTS notifications_user_created_idx
    ON notifications (user_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_user_created_idx
    ON notifications (user_id, created_at DESC, id DESC)
    WHERE is_read = false;
CREATE INDEX IF NOT EXISTS notifications_actor_created_idx
    ON notifications (actor_id, created_at DESC)
    WHERE actor_id IS NOT NULL;

COMMIT;
