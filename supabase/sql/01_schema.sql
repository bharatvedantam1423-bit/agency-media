-- Social Signal: schema
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.config (
  key text primary key,
  value text not null
);
insert into private.config(key, value) values
  ('worker_token', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- Accounts we watch (and candidates the system discovered itself)
create table if not exists public.accounts (
  id bigserial primary key,
  platform text not null check (platform in ('x','instagram','bluesky','mastodon','youtube','linkedin','dribbble','behance','contra','threads','reddit')),
  handle text not null,
  display_name text,
  bio text,
  url text,
  followers integer,
  kind text,                       -- agency | studio | freelancer | creator | business | unknown
  status text not null default 'watch' check (status in ('watch','candidate','ignored','invalid')),
  origin text not null default 'seed' check (origin in ('seed','discovered','manual')),
  discovered_from text,
  relevance real,                  -- 0..1, heuristic first, Laya later
  relevance_source text,           -- heuristic | laya
  median_eng real,
  posts_count integer not null default 0,
  last_collected_at timestamptz,
  next_collect_at timestamptz not null default now(),
  fail_count integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  unique (platform, handle)
);
create index if not exists accounts_due_idx on public.accounts (status, next_collect_at);

-- Hashtags / keywords the system watches for discovery
create table if not exists public.sources (
  id bigserial primary key,
  platform text not null,
  kind text not null check (kind in ('hashtag','keyword')),
  value text not null,
  origin text not null default 'seed' check (origin in ('seed','auto','manual')),
  active boolean not null default true,
  last_collected_at timestamptz,
  next_collect_at timestamptz not null default now(),
  unique (platform, kind, value)
);

create table if not exists public.posts (
  id text primary key,             -- platform:native_id
  platform text not null,
  account_id bigint references public.accounts(id) on delete set null,
  handle text,
  url text,
  text text,
  posted_at timestamptz,
  format text,                     -- text | image | video | carousel | link | thread
  media_count integer default 0,
  likes integer default 0,
  reposts integer default 0,
  replies integer default 0,
  views bigint,
  saves integer,
  engagement real,
  outlier real,                    -- engagement / account median
  early_outlier real,              -- same, for posts < 36h old
  is_winner boolean default false,
  features jsonb not null default '{}'::jsonb,
  lang text,
  via text not null default 'timeline',   -- timeline | hashtag | keyword
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  raw jsonb
);
create index if not exists posts_platform_posted_idx on public.posts (platform, posted_at desc);
create index if not exists posts_account_idx on public.posts (account_id);
create index if not exists posts_winner_idx on public.posts (is_winner, posted_at desc);

create table if not exists public.post_snapshots (
  post_id text not null references public.posts(id) on delete cascade,
  captured_at timestamptz not null default now(),
  likes integer, reposts integer, replies integer, views bigint,
  primary key (post_id, captured_at)
);

-- Laya answers
create table if not exists public.post_tags (
  post_id text primary key references public.posts(id) on delete cascade,
  relevant real,
  purpose text,
  hook text,
  subject text,
  has_cta real,
  specificity real,
  slop real,
  answers jsonb,
  model text,
  tagged_at timestamptz not null default now()
);

-- Curated keyword dictionary for hot topics (hashtags are added automatically)
create table if not exists public.topic_terms (
  term text primary key,
  pattern text not null,           -- case-insensitive regex
  origin text not null default 'seed',
  active boolean not null default true
);

create table if not exists public.post_terms (
  post_id text not null references public.posts(id) on delete cascade,
  term text not null,
  primary key (post_id, term)
);
create index if not exists post_terms_term_idx on public.post_terms (term);

create table if not exists public.pattern_stats (
  window_days integer not null,
  dimension text not null,
  value text not null,
  posts integer, winners integer, win_rate real, lift real, median_outlier real,
  example_ids text[],
  computed_at timestamptz not null default now(),
  primary key (window_days, dimension, value)
);

create table if not exists public.combo_stats (
  window_days integer not null,
  dim_a text not null, val_a text not null,
  dim_b text not null, val_b text not null,
  posts integer, winners integer, win_rate real, lift real, median_outlier real,
  example_ids text[],
  computed_at timestamptz not null default now(),
  primary key (window_days, dim_a, val_a, dim_b, val_b)
);

create table if not exists public.hot_topics (
  term text primary key,
  posts_now integer, posts_prev integer,
  eng_now real, eng_prev real,
  growth real, score real,
  platforms text[],
  example_ids text[],
  computed_at timestamptz not null default now()
);

create table if not exists public.runs (
  id bigserial primary key,
  job text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  ok boolean,
  stats jsonb,
  error text
);

-- Lock everything down: no public (anon) access to tables. The dashboard reads
-- through the owner's Supabase connector; the Laya worker uses token-checked RPCs.
alter table public.accounts enable row level security;
alter table public.sources enable row level security;
alter table public.posts enable row level security;
alter table public.post_snapshots enable row level security;
alter table public.post_tags enable row level security;
alter table public.topic_terms enable row level security;
alter table public.post_terms enable row level security;
alter table public.pattern_stats enable row level security;
alter table public.combo_stats enable row level security;
alter table public.hot_topics enable row level security;
alter table public.runs enable row level security;
