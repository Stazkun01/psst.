-- psst: hints, games, profile pics and push notifications.
-- Run after schema.sql. Then fill in your own keys (see README) and deploy supabase/functions/notify.

create extension if not exists pg_net;
alter table public.app_config add column if not exists vapid_public text, add column if not exists vapid_private text, add column if not exists hook_secret text;
-- update public.app_config set vapid_public = '<VAPID public key>', vapid_private = '<VAPID private key>', hook_secret = '<random string>' where id = 1;

alter table public.users add column if not exists avatar text, add column if not exists game text not null default 'messages';
alter table public.messages add column if not exists device text, add column if not exists city text, add column if not exists country text,
  add column if not exists game text not null default 'messages', add column if not exists prompt text;

create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  sub jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_user on public.push_subs(user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

create or replace function public._clean(t text, n int) returns text
language sql immutable as $$ select nullif(left(regexp_replace(trim(coalesce(t,'')), '[\r\n\t<>]', '', 'g'), n), '') $$;
revoke execute on function public._clean(text,int) from public, anon, authenticated;

-- hints: phone type + approximate city/country, captured when a message is sent and shown to the inbox owner.
-- the send page tells senders this up front.
create or replace function public.send_message(p_username text, p_body text, p_device text, p_city text, p_country text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare ip text := public._ip_hash(); u public.users; b text := trim(coalesce(p_body,'')); w text;
  default_words text[] := array['kys','kill yourself','kill urself','killyourself','go die','end yourself','unalive yourself'];
  cc text := upper(coalesce(p_country,''));
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
  if exists (select 1 from public.blocks where user_id = u.id and sender_hash = ip) then
    return json_build_object('ok', true); end if;
  foreach w in array (default_words || u.filter_words) loop
    if length(trim(w)) > 0 and position(lower(trim(w)) in lower(b)) > 0 then
      return json_build_object('ok', true); end if;
  end loop;
  insert into public.messages(user_id, body, sender_hash, device, city, country, game, prompt)
  values (u.id, b, ip, public._clean(p_device, 40), public._clean(p_city, 40),
          case when cc ~ '^[A-Z]{2}$' then cc end, u.game, u.prompt);
  return json_build_object('ok', true);
end $$;

create or replace function public.get_profile(p_username text) returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('username', username, 'prompt', prompt, 'paused', paused, 'avatar', avatar, 'game', game)
  from public.users where username = lower(trim(p_username));
$$;

create or replace function public.me(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token); r json;
begin
  select json_build_object('username', u.username, 'prompt', u.prompt, 'paused', u.paused,
    'filter_words', u.filter_words, 'avatar', u.avatar, 'game', u.game,
    'vapid', (select vapid_public from public.app_config),
    'push_count', (select count(*) from public.push_subs p where p.user_id = u.id),
    'unread', (select count(*) from public.messages m where m.user_id = u.id and not m.seen))
  into r from public.users u where u.id = uid;
  return r;
end $$;

create or replace function public.get_inbox(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token);
begin
  return coalesce((select json_agg(json_build_object('id', id, 'body', body, 'seen', seen,
      'answer', answer, 'created_at', created_at, 'device', device, 'city', city, 'country', country,
      'game', game, 'prompt', prompt) order by created_at desc)
    from (select * from public.messages where user_id = uid order by created_at desc limit 200) m), '[]'::json);
end $$;

create or replace function public.set_game(p_token text, p_game text, p_prompt text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_game not in ('messages','tbh','nhie','confess','words','rate','shoot','ama','flags') then raise exception 'bad_game'; end if;
  if length(trim(coalesce(p_prompt,''))) not between 1 and 80 then raise exception 'bad_length'; end if;
  update public.users set game = p_game, prompt = trim(p_prompt) where id = public._uid(p_token);
end $$;

create or replace function public.set_avatar(p_token text, p_avatar text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_avatar is not null and (length(p_avatar) > 150000 or p_avatar !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$') then
    raise exception 'bad_image'; end if;
  update public.users set avatar = p_avatar where id = public._uid(p_token);
end $$;

create or replace function public.save_push(p_token text, p_sub jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._uid(p_token); ep text := p_sub->>'endpoint';
begin
  if ep is null or ep !~ '^https://' or length(p_sub::text) > 4000 then raise exception 'bad_sub'; end if;
  insert into public.push_subs(endpoint, user_id, sub) values (ep, uid, p_sub)
  on conflict (endpoint) do update set user_id = excluded.user_id, sub = excluded.sub, created_at = now();
end $$;

-- new message -> ping the notify edge function (replace <project-ref>)
create or replace function public._notify_new_message() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from public.push_subs where user_id = new.user_id) then
    perform net.http_post(
      url := 'https://<project-ref>.supabase.co/functions/v1/notify',
      body := jsonb_build_object('user_id', new.user_id, 'game', new.game),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-psst-secret', (select hook_secret from public.app_config))
    );
  end if;
  return new;
end $$;
revoke execute on function public._notify_new_message() from public, anon, authenticated;
create or replace trigger messages_notify after insert on public.messages
  for each row execute function public._notify_new_message();

revoke execute on function public.send_message(text,text,text,text,text), public.get_profile(text), public.me(text),
  public.get_inbox(text), public.set_game(text,text,text), public.set_avatar(text,text), public.save_push(text,jsonb) from public;
grant execute on function public.send_message(text,text,text,text,text), public.get_profile(text), public.me(text),
  public.get_inbox(text), public.set_game(text,text,text), public.set_avatar(text,text), public.save_push(text,jsonb) to anon, authenticated;
