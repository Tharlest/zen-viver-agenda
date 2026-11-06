-- ============================================================
--  ZEN VIVER — Migracao: Liberacao da agenda
--  * Abertura automatica passa de domingo 20h -> domingo 11:00
--  * Liberacao MANUAL de semanas (config.liberadas = ['YYYY-MM-DD' da segunda])
--  * Botao usa app_liberacao (ler) e app_liberar_semana (gravar)
--  Idempotente. Reproduz as funcoes centrais com mudanca cirurgica.
-- ============================================================
set search_path = public, extensions;

-- ---------- Abertura automatica: domingo 11:00 ----------
create or replace function _semana_aberta(out ini date, out fim date)
  language plpgsql stable as $$
declare agora timestamp; hoje date; seg_corrente date; seg_proxima date; abertura timestamp;
begin
  agora := _agora_sp();
  hoje := agora::date;
  seg_corrente := date_trunc('week', hoje::timestamp)::date;   -- segunda desta semana
  seg_proxima := seg_corrente + 7;
  abertura := seg_proxima::timestamp - interval '13 hours';     -- domingo 11:00 (anterior a segunda)
  if agora >= abertura then ini := seg_proxima; else ini := seg_corrente; end if;
  fim := ini + 6;
end; $$;

-- ---------- Semana liberada? (automatica OU manual) ----------
create or replace function _semana_liberada(p_empresa uuid, p_data date) returns boolean
  language plpgsql stable set search_path=public, extensions as $$
declare v_ini date; v_fim date; v_seg text; v_libs jsonb;
begin
  select (_semana_aberta()).* into v_ini, v_fim;
  if p_data >= v_ini and p_data <= v_fim then return true; end if;        -- janela automatica
  v_seg := to_char(date_trunc('week', p_data::timestamp)::date, 'YYYY-MM-DD');
  select config->'liberadas' into v_libs from empresas where id=p_empresa; -- liberadas manualmente
  if v_libs is not null and jsonb_typeof(v_libs)='array' and v_libs ? v_seg then return true; end if;
  return false;
end; $$;

-- ---------- app_get_agenda_colaborador (usa _semana_liberada) ----------
create or replace function app_get_agenda_colaborador(p_slug text, p_email text, p_ano int, p_mes int) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare e record; v_email text; v_hoje date; v_ini date; v_fim date; v_ano int; v_mes int;
        v_dias_no_mes int; v_d int; v_ds date; v_ter uuid; v_ter_nome text; v_lib boolean;
        v_dias jsonb := '[]'::jsonb; v_grade jsonb := '[]'::jsonb; v_slots jsonb; v_min int; v_usadas int;
begin
  v_email := lower(trim(p_email));
  select * into e from empresas where slug=p_slug and ativa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  v_hoje := _hoje_sp(); select (_semana_aberta()).* into v_ini, v_fim;
  v_min := extract(hour from _agora_sp())::int*60 + extract(minute from _agora_sp())::int;
  v_ano := coalesce(p_ano, extract(year from v_hoje)::int);
  v_mes := coalesce(p_mes, extract(month from v_hoje)::int);
  v_dias_no_mes := extract(day from (make_date(v_ano,v_mes,1) + interval '1 month - 1 day'))::int;
  for v_d in 1..v_dias_no_mes loop
    v_ds := make_date(v_ano,v_mes,v_d);
    v_ter := _terapeuta_do_dia(e.id, v_ds);
    if v_ter is not null then
      select nome into v_ter_nome from terapeutas where id=v_ter;
      v_lib := (_semana_liberada(e.id, v_ds) and v_ds>=v_hoje);
      v_dias := v_dias || jsonb_build_object('data',to_char(v_ds,'YYYY-MM-DD'),'dow',extract(dow from v_ds)::int,'terapeuta',v_ter_nome,'liberado',v_lib,'passado',(v_ds<v_hoje));
      if v_lib then
        select coalesce(jsonb_agg(jsonb_build_object(
            'hora',h.hora,
            'status', case
               when a.id is not null and lower(a.colaborador_email)=v_email then 'MEU'
               when a.id is not null then 'OCUPADO'
               when v_ds=v_hoje and _min_do_horario(h.hora) <= v_min then 'PASSOU'
               else 'LIVRE' end,
            'agId', a.id) order by h.hora),'[]'::jsonb)
          into v_slots
          from unnest(_horarios()) as h(hora)
          left join agendamentos a on a.empresa_id=e.id and a.data=v_ds and a.hora=h.hora;
        v_grade := v_grade || jsonb_build_object('data',to_char(v_ds,'YYYY-MM-DD'),'dow',extract(dow from v_ds)::int,'terapeuta',v_ter_nome,'slots',v_slots);
      end if;
    end if;
  end loop;
  select count(*) into v_usadas from agendamentos where empresa_id=e.id and lower(colaborador_email)=v_email and data>=v_ini and data<=v_fim;
  return jsonb_build_object('empresa',e.nome,'email',v_email,'limiteSemana',e.limite_semana,'usadasNaSemana',v_usadas,
    'semana',jsonb_build_object('ini',to_char(v_ini,'YYYY-MM-DD'),'fim',to_char(v_fim,'YYYY-MM-DD')),
    'proximaAbertura',to_char(v_fim,'YYYY-MM-DD'),'mes',jsonb_build_object('ano',v_ano,'mes',v_mes),
    'dias',v_dias,'grade',v_grade);
end; $$;

-- ---------- app_marcar (usa _semana_liberada) ----------
create or replace function app_marcar(p_slug text, p_email text, p_nome text, p_data date, p_hora text) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare e record; v_email text; v_hoje date; v_ter uuid; v_ter_nome text;
        v_simi date; v_sfim date; v_usadas int; v_min int; v_nomec text; v_id uuid;
begin
  v_email := lower(trim(p_email));
  select * into e from empresas where slug=p_slug and ativa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  v_hoje := _hoje_sp();
  if not _semana_liberada(e.id, p_data) then raise exception 'DATA_NAO_LIBERADA'; end if;
  if p_data<v_hoje then raise exception 'DATA_PASSADA'; end if;
  v_ter := _terapeuta_do_dia(e.id, p_data);
  if v_ter is null then raise exception 'SEM_ATENDIMENTO'; end if;
  if not (p_hora = any(_horarios())) then raise exception 'HORARIO_INVALIDO'; end if;
  v_min := extract(hour from _agora_sp())::int*60 + extract(minute from _agora_sp())::int;
  if p_data=v_hoje and _min_do_horario(p_hora) <= v_min then raise exception 'HORARIO_PASSOU'; end if;
  select (_semana_da_data(p_data)).* into v_simi, v_sfim;
  select count(*) into v_usadas from agendamentos where empresa_id=e.id and lower(colaborador_email)=v_email and data>=v_simi and data<=v_sfim;
  if v_usadas >= e.limite_semana then raise exception 'LIMITE_SEMANAL'; end if;
  if p_nome is not null and trim(p_nome)<>'' then perform app_cadastrar_colaborador(p_slug, p_nome, v_email); end if;
  select nome into v_nomec from colaboradores where empresa_id=e.id and lower(email)=v_email;
  v_nomec := coalesce(v_nomec, nullif(trim(p_nome),''), v_email);
  select nome into v_ter_nome from terapeutas where id=v_ter;
  begin
    insert into agendamentos(empresa_id,data,hora,colaborador_nome,colaborador_email,terapeuta_id,terapeuta_nome)
      values (e.id,p_data,p_hora,v_nomec,v_email,v_ter,v_ter_nome) returning id into v_id;
  exception when unique_violation then raise exception 'HORARIO_OCUPADO';
  end;
  return jsonb_build_object('ok',true,'id',v_id);
end; $$;

-- ---------- Ler info de liberacao (para o calendario do botao) ----------
create or replace function app_liberacao(p_token uuid, p_empresa uuid)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; v_ini date; v_fim date; e record;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  if v_role='gestor' then p_empresa := v_ref; end if;
  select * into e from empresas where id=p_empresa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  select (_semana_aberta()).* into v_ini, v_fim;
  return jsonb_build_object('empresa',e.nome,'dias',to_jsonb(e.dias),
    'hoje',to_char(_hoje_sp(),'YYYY-MM-DD'),
    'auto',jsonb_build_object('ini',to_char(v_ini,'YYYY-MM-DD'),'fim',to_char(v_fim,'YYYY-MM-DD')),
    'liberadas',coalesce(e.config->'liberadas','[]'::jsonb));
end; $$;

-- ---------- Liberar/fechar uma semana manualmente (master e gestor) ----------
create or replace function app_liberar_semana(p_token uuid, p_empresa uuid, p_segunda text, p_liberar boolean)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; v_libs jsonb; v_seg text;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  if v_role='gestor' then p_empresa := v_ref; end if;
  v_seg := to_char(date_trunc('week', p_segunda::date::timestamp)::date, 'YYYY-MM-DD');
  select coalesce(config->'liberadas','[]'::jsonb) into v_libs from empresas where id=p_empresa;
  if v_libs is null or jsonb_typeof(v_libs)<>'array' then v_libs := '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x),'[]'::jsonb) into v_libs from jsonb_array_elements_text(v_libs) x where x <> v_seg;
  if p_liberar then v_libs := v_libs || to_jsonb(v_seg); end if;
  update empresas set config = jsonb_set(coalesce(config,'{}'::jsonb), '{liberadas}', v_libs) where id=p_empresa;
  return jsonb_build_object('ok',true,'liberadas',v_libs);
end; $$;

-- ---------- Grants ----------
grant execute on function app_liberacao(uuid,uuid)                   to anon, authenticated;
grant execute on function app_liberar_semana(uuid,uuid,text,boolean) to anon, authenticated;
