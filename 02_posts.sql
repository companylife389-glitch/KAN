-- KAN — phase 2: posts, comments (+replies), likes, bookmarks, post media.
-- Run after 01_accounts.sql.

create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  text        text not null default '' check (char_length(text) <= 2000),
  media_url   text check (char_length(media_url) <= 1000),
  media_type  text check (media_type in ('image', 'video')),
  created_at  timestamptz not null default now(),
  check (char_length(text) > 0 or media_url is not null),
  check ((media_url is null) = (media_type is null))
);
create index if not exists posts_created_at_idx on public.posts (created_at desc);
create index if not exists posts_user_id_idx on public.posts (user_id);

-- A reply is a comment whose parent_id points to a top-level comment.
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts(id) on delete cascade,
  parent_id   uuid references public.comments(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  text        text not null check (char_length(text) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index if not exists comments_post_id_idx on public.comments (post_id, created_at);
create index if not exists comments_parent_id_idx on public.comments (parent_id);

create or replace function public.check_comment_parent()
returns trigger language plpgsql set search_path = public as $$
declare par record;
begin
  if new.parent_id is not null then
    select post_id, parent_id into par from public.comments where id = new.parent_id;
    if not found or par.post_id <> new.post_id or par.parent_id is not null then
      raise exception 'invalid reply target';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists comments_check_parent on public.comments;
create trigger comments_check_parent before insert on public.comments
  for each row execute function public.check_comment_parent();

create table if not exists public.post_likes (
  post_id     uuid not null references public.posts(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);
create table if not exists public.comment_likes (
  comment_id  uuid not null references public.comments(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (comment_id, user_id)
);
create table if not exists public.bookmarks (
  post_id     uuid not null references public.posts(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index if not exists post_likes_user_idx on public.post_likes (user_id);
create index if not exists comment_likes_user_idx on public.comment_likes (user_id);
create index if not exists bookmarks_user_idx on public.bookmarks (user_id);

revoke all on public.posts, public.comments, public.post_likes, public.comment_likes, public.bookmarks from anon;

alter table public.posts         enable row level security;
alter table public.comments      enable row level security;
alter table public.post_likes    enable row level security;
alter table public.comment_likes enable row level security;
alter table public.bookmarks     enable row level security;

-- posts
drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select to authenticated using (true);
drop policy if exists "posts insert own" on public.posts;
create policy "posts insert own" on public.posts for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "posts delete own" on public.posts;
create policy "posts delete own" on public.posts for delete to authenticated using (auth.uid() = user_id);

-- comments
drop policy if exists "comments readable" on public.comments;
create policy "comments readable" on public.comments for select to authenticated using (true);
drop policy if exists "comments insert own" on public.comments;
create policy "comments insert own" on public.comments for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "comments delete own" on public.comments;
create policy "comments delete own" on public.comments for delete to authenticated using (auth.uid() = user_id);

-- likes (public counts)
drop policy if exists "post likes readable" on public.post_likes;
create policy "post likes readable" on public.post_likes for select to authenticated using (true);
drop policy if exists "post likes insert own" on public.post_likes;
create policy "post likes insert own" on public.post_likes for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "post likes delete own" on public.post_likes;
create policy "post likes delete own" on public.post_likes for delete to authenticated using (auth.uid() = user_id);

drop policy if exists "comment likes readable" on public.comment_likes;
create policy "comment likes readable" on public.comment_likes for select to authenticated using (true);
drop policy if exists "comment likes insert own" on public.comment_likes;
create policy "comment likes insert own" on public.comment_likes for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "comment likes delete own" on public.comment_likes;
create policy "comment likes delete own" on public.comment_likes for delete to authenticated using (auth.uid() = user_id);

-- bookmarks (private)
drop policy if exists "bookmarks read own" on public.bookmarks;
create policy "bookmarks read own" on public.bookmarks for select to authenticated using (auth.uid() = user_id);
drop policy if exists "bookmarks insert own" on public.bookmarks;
create policy "bookmarks insert own" on public.bookmarks for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "bookmarks delete own" on public.bookmarks;
create policy "bookmarks delete own" on public.bookmarks for delete to authenticated using (auth.uid() = user_id);

-- Storage bucket for post images/videos (public read, upload only into your own folder)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-media', 'post-media', true, 20971520,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "post media upload own folder" on storage.objects;
create policy "post media upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'post-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "post media delete own" on storage.objects;
create policy "post media delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'post-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- Live updates
do $$
declare t text;
begin
  foreach t in array array['profiles','follows','posts','comments','post_likes','comment_likes'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
