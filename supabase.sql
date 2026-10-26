-- Стопка: публичная таблица лидеров.
-- Вставь весь файл в Supabase: SQL Editor -> New query -> Run.

create table if not exists public.entries (
  id bigint generated always as identity primary key,
  client uuid not null,
  name text not null,
  diff text not null,
  score int not null check (score between 1 and 2000),
  created_at timestamptz not null default now()
);

alter table public.entries drop constraint if exists entries_diff_check;
alter table public.entries add constraint entries_diff_check check (diff in ('normal', 'hard', 'daily', 'stars'));

create index if not exists entries_diff_score on public.entries (diff, score desc);
create index if not exists entries_client_time on public.entries (client, created_at desc);

-- Прямой доступ к таблице закрыт: политик нет, работают только функции ниже.
alter table public.entries enable row level security;

-- Отправка результата. Проверяет имя, потолок очков и частоту (не чаще раза в 20 секунд).
create or replace function public.submit_score(p_client uuid, p_name text, p_diff text, p_score int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  clean text;
begin
  if p_diff not in ('normal', 'hard', 'daily', 'stars') then raise exception 'bad diff'; end if;
  if p_score < 1 or p_score > 2000 then raise exception 'bad score'; end if;
  clean := trim(left(regexp_replace(coalesce(p_name, ''), '[^[:alnum:] _.-]', '', 'g'), 16));
  if length(clean) = 0 then clean := 'Игрок'; end if;
  if exists (select 1 from public.entries where client = p_client and created_at > now() - interval '20 seconds') then
    raise exception 'too fast';
  end if;
  insert into public.entries (client, name, diff, score) values (p_client, clean, p_diff, p_score);
end;
$$;

-- Топ игроков: p_period = 'all' | 'week' | 'day', p_diff = 'normal' | 'hard' | 'daily' | 'stars'.
create or replace function public.top_scores(p_period text, p_diff text, p_limit int default 20)
returns table (client uuid, name text, best int)
language sql
stable
security definer
set search_path = public
as $$
  select t.client, t.name, t.best
  from (
    select e.client,
           (array_agg(e.name order by e.created_at desc))[1] as name,
           max(e.score) as best
    from public.entries e
    where e.diff = p_diff
      and (
        p_period = 'all'
        or (p_period = 'week' and e.created_at >= date_trunc('week', now()))
        or (p_period = 'day' and e.created_at >= date_trunc('day', now()))
      )
    group by e.client
  ) t
  order by t.best desc
  limit least(greatest(p_limit, 1), 50);
$$;

revoke all on function public.submit_score(uuid, text, text, int) from public;
revoke all on function public.top_scores(text, text, int) from public;
grant execute on function public.submit_score(uuid, text, text, int) to anon;
grant execute on function public.top_scores(text, text, int) to anon;
