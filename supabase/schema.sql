-- psst database schema (run once in the Supabase SQL editor)
-- Everything is locked down: clients can only call the functions below,
-- never read or write the tables directly.

create extension if not exists pgcrypto with schema extensions;

create table public.app_config (
  id int primary key default 1 check (id = 1),
  salt text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.app_config default values;

create table public.users (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  pass_hash text not null,
  prompt text not null default 'send me anonymous messages!',
  paused boolean not null default false,
  filter_words text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table public.sessions (
  token_hash text primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '30 days'
);
create index on public.sessions(user_id);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  body text not null,
  sender_hash text not null,
  seen boolean not null default false,
  answer text,
  answered_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.messages(user_id, created_at desc);
create index on public.messages(sender_hash, created_at desc);

create table public.blocks (
  user_id uuid not null references public.users(id) on delete cascade,
  sender_hash text not null,
  primary key (user_id, sender_hash)
);

create table public.attempts (
  id bigserial primary key,
  kind text not null,
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index on public.attempts(kind, ip_hash, created_at desc);

alter table public.app_config enable row level security;
alter table public.users enable row level security;
alter table public.sessions enable row level security;
alter table public.messages enable row level security;
alter table public.blocks enable row level security;
alter table public.attempts enable row level security;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- helpers (not callable by clients)
-- sender identity = salted hash of the IP, so senders stay anonymous even to the database owner
create function public._ip_hash() returns text
language sql stable security definer set search_path = public, extensions as $$
  select encode(extensions.digest(
    coalesce(
      nullif(trim(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1)), ''),
      current_setting('request.headers', true)::json->>'cf-connecting-ip',
      'unknown'
    ) || (select salt from public.app_config), 'sha256'), 'hex');
$$;

create function public._uid(p_token text) returns uuid
language plpgsql stable security definer set search_path = public, extensions as $$
declare v uuid;
begin
  select user_id into v from public.sessions
   where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
     and expires_at > now();
  if v is null then raise exception 'not_logged_in'; end if;
  return v;
end $$;

create function public._new_session(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from public.sessions where user_id = p_user and expires_at < now();
  insert into public.sessions(token_hash, user_id)
  values (encode(extensions.digest(t, 'sha256'), 'hex'), p_user);
  return t;
end $$;

-- public API
create function public.signup(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare u text := lower(trim(p_username)); ip text := public._ip_hash(); new_id uuid;
begin
  if u !~ '^[a-z0-9_.]{3,20}$' then raise exception 'bad_username'; end if;
  if u = any(array['inbox','login','signup','settings','app','admin','api','about','help','privacy','terms','psst','index.html','favicon.svg','icon.svg','og.jpg','og.png','robots.txt','manifest.webmanifest','sitemap.xml']) then raise exception 'reserved'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'short_password'; end if;
  if (select count(*) from public.attempts where kind='signup' and ip_hash=ip and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'slow_down'; end if;
  insert into public.attempts(kind, ip_hash) values ('signup', ip);
  if exists (select 1 from public.users where username = u) then raise exception 'username_taken'; end if;
  insert into public.users(username, pass_hash) values (u, extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
  returning id into new_id;
  return public._new_session(new_id);
end $$;

create function public.login(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare ip text := public._ip_hash(); r public.users;
begin
  if (select count(*) from public.attempts where kind='login_fail' and ip_hash=ip and created_at > now() - interval '15 minutes') >= 10 then
    raise exception 'slow_down'; end if;
  select * into r from public.users where username = lower(trim(p_username));
  if r.id is null or r.pass_hash <> extensions.crypt(coalesce(p_password,''), r.pass_hash) then
    insert into public.attempts(kind, ip_hash) values ('login_fail', ip);
    raise exception 'wrong_login';
  end if;
  return public._new_session(r.id);
end $$;

create function public.logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from public.sessions where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
$$;

create function public.me(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token); r json;
begin
  select json_build_object('username', u.username, 'prompt', u.prompt, 'paused', u.paused,
    'filter_words', u.filter_words,
    'unread', (select count(*) from public.messages m where m.user_id = u.id and not m.seen))
  into r from public.users u where u.id = uid;
  return r;
end $$;

create function public.get_profile(p_username text) returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('username', username, 'prompt', prompt, 'paused', paused)
  from public.users where username = lower(trim(p_username));
$$;

create function public.send_message(p_username text, p_body text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare ip text := public._ip_hash(); u public.users; b text := trim(coalesce(p_body,'')); w text;
  default_words text[] := array['kys','kill yourself','kill urself','killyourself','go die','end yourself','unalive yourself'];
begin
  select * into u from public.users where username = lower(trim(p_username));
  if u.id is null then raise exception 'no_user'; end if;
  if u.paused then raise exception 'paused'; end if;
  if length(b) < 1 or length(b) > 300 then raise exception 'bad_length'; end if;
  if (select count(*) from public.messages where sender_hash = ip and user_id = u.id and created_at > now() - interval '1 minute') >= 3
     or (select count(*) from public.messages where sender_hash = ip and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'slow_down'; end if;
  if exists (select 1 from public.messages where sender_hash = ip and user_id = u.id and lower(body) = lower(b) and created_at > now() - interval '10 minutes') then
    return json_build_object('ok', true); end if;
  -- blocked senders and filtered words: pretend it worked, store nothing
  if exists (select 1 from public.blocks where user_id = u.id and sender_hash = ip) then
    return json_build_object('ok', true); end if;
  foreach w in array (default_words || u.filter_words) loop
    if length(trim(w)) > 0 and position(lower(trim(w)) in lower(b)) > 0 then
      return json_build_object('ok', true); end if;
  end loop;
  insert into public.messages(user_id, body, sender_hash) values (u.id, b, ip);
  return json_build_object('ok', true);
end $$;

create function public.get_inbox(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token);
begin
  return coalesce((select json_agg(json_build_object('id', id, 'body', body, 'seen', seen,
      'answer', answer, 'created_at', created_at) order by created_at desc)
    from (select * from public.messages where user_id = uid order by created_at desc limit 200) m), '[]'::json);
end $$;

create function public.mark_seen(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.messages set seen = true where id = p_id and user_id = public._uid(p_token);
end $$;

create function public.answer_message(p_token text, p_id uuid, p_answer text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(trim(coalesce(p_answer,''))) > 500 then raise exception 'bad_length'; end if;
  update public.messages set answer = nullif(trim(p_answer),''), answered_at = now(), seen = true
   where id = p_id and user_id = public._uid(p_token);
end $$;

create function public.delete_message(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.messages where id = p_id and user_id = public._uid(p_token);
end $$;

create function public.block_sender(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token); h text;
begin
  select sender_hash into h from public.messages where id = p_id and user_id = uid;
  if h is null then return; end if;
  insert into public.blocks(user_id, sender_hash) values (uid, h) on conflict do nothing;
  delete from public.messages where user_id = uid and sender_hash = h;
end $$;

create function public.update_settings(p_token text, p_prompt text, p_paused boolean, p_filter_words text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(trim(coalesce(p_prompt,''))) > 80 or coalesce(array_length(p_filter_words,1),0) > 100 then raise exception 'bad_length'; end if;
  update public.users set
    prompt = coalesce(nullif(trim(p_prompt),''), 'send me anonymous messages!'),
    paused = coalesce(p_paused, false),
    filter_words = coalesce(p_filter_words, '{}')
  where id = public._uid(p_token);
end $$;

create function public.delete_account(p_token text, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token); r public.users;
begin
  select * into r from public.users where id = uid;
  if r.pass_hash <> extensions.crypt(coalesce(p_password,''), r.pass_hash) then raise exception 'wrong_login'; end if;
  delete from public.users where id = uid;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.signup(text,text), public.login(text,text), public.logout(text), public.me(text),
  public.get_profile(text), public.send_message(text,text), public.get_inbox(text),
  public.mark_seen(text,uuid), public.answer_message(text,uuid,text), public.delete_message(text,uuid),
  public.block_sender(text,uuid), public.update_settings(text,text,boolean,text[]),
  public.delete_account(text,text)
to anon, authenticated;
