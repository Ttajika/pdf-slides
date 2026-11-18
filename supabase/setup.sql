-- ════════════════════════════════════════════════════════════════════════
--  pdf-slides：PDF アップロード（共有リンク・発表者リンク）用の設定
--
--  Supabase ダッシュボード → SQL Editor にこのファイル全体を貼り付けて Run。
--  そのあと、最後の「アップロード用パスワード」の行を自分のパスワードにして実行する。
--  何度実行しても壊れない（作り直すだけ）。
--
--  仕組み
--    ・PDF は公開バケット slides に置く。パスは毎回ランダム（推測できない）。
--      一覧（list）は許可しないので、パスは slide_get（共有リンクの ID が必要）でしか分からない
--    ・slide_uploads に 1 件 = 1 つの共有リンク。expires_at（既定 30 日）を過ぎると slide_get が何も返さない
--    ・アップロードは「パスワード → slide_create」で発行された、15 分だけ有効な 1 つのパスにだけ書ける
--    ・差し替え・延長・削除は発表者リンクの秘密鍵（edit key、DB にはハッシュだけ保存）で行う
--    ・参加者へのダウンロードボタンは発表者が切り替えられる（allow_download。公開 URL なので完全には防げない）
--    ・期限切れ・差し替え前の古いファイルは、末尾の「掃除」の SQL で消す（たまにでよい）
-- ════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;

-- ── テーブル ─────────────────────────────────────────────────────────────
create table if not exists public.slide_config (
  k text primary key,
  v text not null
);
alter table public.slide_config enable row level security;   -- ポリシーなし = API からは読めない

create table if not exists public.slide_uploads (
  id            text primary key,
  edit_key_hash text not null,
  title         text not null default '',
  current_path  text,
  pending_path  text,
  pending_until timestamptz,
  version       int  not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '30 days'
);
alter table public.slide_uploads enable row level security;  -- 直接は読めない。下の関数経由のみ
-- 参加者に PDF のダウンロードボタンを出すか（あとから追加した列）
alter table public.slide_uploads add column if not exists allow_download boolean not null default true;

-- ── バケット（公開・50MB・PDF のみ）──────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('slides', 'slides', true, 52428800, array['application/pdf'])
on conflict (id) do update
  set public = true, file_size_limit = 52428800, allowed_mime_types = array['application/pdf'];

-- ── 内部用の関数 ─────────────────────────────────────────────────────────
create or replace function public.slide_rand(n int) returns text
language sql volatile set search_path = '' as $$
  select translate(encode(extensions.gen_random_bytes(n), 'base64'), '+/=', '-_');
$$;

create or replace function public.slide_hash(t text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(t, 'sha256'), 'hex');
$$;

-- 秘密鍵が正しい・期限内の行を返す（なければ例外）
create or replace function public.slide_auth(p_id text, p_key text) returns public.slide_uploads
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads;
begin
  select * into r from public.slide_uploads
   where id = p_id and edit_key_hash = public.slide_hash(coalesce(p_key, ''));
  if not found then raise exception 'invalid key' using errcode = '28000'; end if;
  if r.expires_at <= now() then raise exception 'expired' using errcode = '22023'; end if;
  return r;
end $$;

-- ストレージのポリシーから呼ぶ判定（RLS で slide_uploads が見えないので security definer）
create or replace function public.slide_can_write(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.slide_uploads
                  where pending_path = p_name and pending_until > now() and expires_at > now());
$$;
create or replace function public.slide_can_delete(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.slide_uploads
                      where expires_at > now()
                        and (current_path = p_name or (pending_path = p_name and pending_until > now())));
$$;

-- ── API（anon / authenticated から rpc で呼ぶ）──────────────────────────
-- 新規：パスワードを確かめて、共有 ID・秘密鍵・アップロード先パスを発行
create or replace function public.slide_create(p_password text, p_title text)
returns table (id text, edit_key text, upload_path text)
language plpgsql security definer set search_path = '' as $$
declare h text; v_id text; v_key text; v_path text;
begin
  select v into h from public.slide_config where k = 'upload_password';
  if h is null or extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform pg_sleep(1);   -- 総当たり対策
    raise exception 'wrong password' using errcode = '28P01';
  end if;
  v_id := public.slide_rand(9);
  v_key := public.slide_rand(18);
  v_path := v_id || '/' || public.slide_rand(12) || '.pdf';
  insert into public.slide_uploads (id, edit_key_hash, title, pending_path, pending_until)
  values (v_id, public.slide_hash(v_key), left(coalesce(p_title, ''), 200), v_path, now() + interval '15 minutes');
  return query select v_id, v_key, v_path;
end $$;

-- 差し替え：新しいアップロード先パスを発行（共有リンクは変わらない）
create or replace function public.slide_begin_replace(p_id text, p_key text)
returns text
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads; v_path text;
begin
  r := public.slide_auth(p_id, p_key);
  v_path := r.id || '/' || public.slide_rand(12) || '.pdf';
  update public.slide_uploads set pending_path = v_path, pending_until = now() + interval '15 minutes'
   where id = r.id;
  return v_path;
end $$;

-- アップロード完了：ファイルが実際にあることを確かめて公開版にする
create or replace function public.slide_commit(p_id text, p_key text, p_title text)
returns int
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads;
begin
  r := public.slide_auth(p_id, p_key);
  if r.pending_path is null or not exists (
       select 1 from storage.objects where bucket_id = 'slides' and name = r.pending_path) then
    raise exception 'file not uploaded' using errcode = '22023';
  end if;
  update public.slide_uploads
     set current_path = r.pending_path, pending_path = null, pending_until = null,
         title = coalesce(nullif(left(p_title, 200), ''), title),
         version = version + 1, updated_at = now()
   where id = r.id;
  return r.version + 1;
end $$;

-- 閲覧：期限内なら題名・ファイルのパスなどを返す（返す列を増やしたので作り直す）
drop function if exists public.slide_get(text);
create function public.slide_get(p_id text)
returns table (title text, path text, version int, updated_at timestamptz, expires_at timestamptz, allow_download boolean)
language sql stable security definer set search_path = '' as $$
  select u.title, u.current_path, u.version, u.updated_at, u.expires_at, u.allow_download
    from public.slide_uploads u
   where u.id = p_id and u.expires_at > now() and u.current_path is not null;
$$;

-- 発表者リンクの確認（正しければ期限を返す）
create or replace function public.slide_check(p_id text, p_key text)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare r public.slide_uploads;
begin
  r := public.slide_auth(p_id, p_key);
  return r.expires_at;
end $$;

-- 期限を「今から 30 日後」に延長
create or replace function public.slide_extend(p_id text, p_key text)
returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads; v timestamptz := now() + interval '30 days';
begin
  r := public.slide_auth(p_id, p_key);
  update public.slide_uploads set expires_at = v where id = r.id;
  return v;
end $$;

-- 参加者のダウンロードを許可する / しない
create or replace function public.slide_set_download(p_id text, p_key text, p_on boolean)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads;
begin
  r := public.slide_auth(p_id, p_key);
  update public.slide_uploads set allow_download = coalesce(p_on, true) where id = r.id;
  return coalesce(p_on, true);
end $$;

-- 削除（すぐに期限切れにする。ファイルは次の掃除で消える）
create or replace function public.slide_delete(p_id text, p_key text)
returns void
language plpgsql security definer set search_path = '' as $$
declare r public.slide_uploads;
begin
  r := public.slide_auth(p_id, p_key);
  update public.slide_uploads set expires_at = now(), pending_path = null, pending_until = null where id = r.id;
end $$;


-- アップロード用パスワードの設定（SQL Editor からだけ実行できる）
create or replace function public.slide_set_password(p text)
returns void
language sql security definer set search_path = '' as $$
  insert into public.slide_config (k, v) values ('upload_password', extensions.crypt(p, extensions.gen_salt('bf', 10)))
  on conflict (k) do update set v = excluded.v;
$$;

-- ── 実行権限：API から呼べるものだけ anon / authenticated に許可 ──────────
revoke all on function public.slide_rand(int), public.slide_hash(text), public.slide_auth(text, text),
  public.slide_set_password(text), public.slide_can_write(text), public.slide_can_delete(text),
  public.slide_create(text, text), public.slide_begin_replace(text, text),
  public.slide_commit(text, text, text), public.slide_get(text), public.slide_check(text, text),
  public.slide_extend(text, text), public.slide_delete(text, text), public.slide_set_download(text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.slide_create(text, text), public.slide_begin_replace(text, text),
  public.slide_commit(text, text, text), public.slide_get(text), public.slide_check(text, text),
  public.slide_extend(text, text), public.slide_delete(text, text), public.slide_set_download(text, text, boolean),
  public.slide_can_write(text)   -- ポリシーの中で呼ばれる（呼び出し元の権限で実行されるので必要）
  to anon, authenticated;

-- ── ストレージのポリシー ─────────────────────────────────────────────────
--   読み出しは公開 URL（ポリシー不要）。select は「アップロード中の 1 ファイル」だけ許可する
--   （アップロード処理が書いた行を読み返す場合に備えて。完了するとすぐ対象外になる）。
--   一覧・削除・上書きは許可しない。
drop policy if exists "slides read"   on storage.objects;
drop policy if exists "slides insert" on storage.objects;
drop policy if exists "slides delete" on storage.objects;
create policy "slides insert" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'slides' and public.slide_can_write(name));
create policy "slides read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'slides' and public.slide_can_write(name));

-- ── アップロード用パスワード（ここを書き換えてから、この 1 行だけ選んで Run）──
-- select public.slide_set_password('ここに長めのパスワード');

-- ── 掃除（たまに SQL Editor で実行）────────────────────────────────────────
--   使われていない（期限切れ・差し替え前・放置された）ファイルの一覧。
--   出てきたものは ダッシュボード → Storage → slides で選んで削除する。
-- select o.name, o.created_at, pg_size_pretty((o.metadata->>'size')::bigint) as size
--   from storage.objects o
--  where o.bucket_id = 'slides' and public.slide_can_delete(o.name)
--    and o.created_at < now() - interval '20 minutes'
--  order by o.created_at;
