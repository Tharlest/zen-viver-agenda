-- ============================================================
--  ZEN VIVER — Migracao: Questionario de bem-estar
--  * Coluna questionario (jsonb) no agendamento
--  * app_marcar passa a receber e guardar o questionario
--  * agenda do terapeuta/gestor/master passa a devolver o questionario
--  * relatorio de bem-estar em tempo real (medias, dores, setores)
--  Idempotente.
-- ============================================================
set search_path = public, extensions;

alter table agendamentos add column if not exists questionario jsonb;

-- ---------- app_marcar: captura o questionario ----------
drop function if exists app_marcar(text,text,text,date,text);
create or replace function app_marcar(p_slug text, p_email text, p_nome text, p_data date, p_hora text, p_questionario jsonb default null) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare e record; v_email text; v_hoje date; v_ter uuid; v_ter_nome text;
        v_simi date; v_sfim date; v_usadas int; v_min int; v_nomec text; v_id uuid; v_q jsonb;
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
  v_q := case when jsonb_typeof(p_questionario)='object' then p_questionario else null end;
  begin
    insert into agendamentos(empresa_id,data,hora,colaborador_nome,colaborador_email,terapeuta_id,terapeuta_nome,questionario)
      values (e.id,p_data,p_hora,v_nomec,v_email,v_ter,v_ter_nome,v_q) returning id into v_id;
  exception when unique_violation then raise exception 'HORARIO_OCUPADO';
  end;
  return jsonb_build_object('ok',true,'id',v_id);
end; $$;

-- ---------- app_listar_agendamentos: inclui questionario ----------
create or replace function app_listar_agendamentos(p_token uuid, p_filtro jsonb) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; v_emp uuid; v_de date; v_ate date;
begin
  select (s).v_role, (s).v_ref into v_role, v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  p_filtro := coalesce(p_filtro,'{}'::jsonb);
  if v_role='gestor' then v_emp := v_ref;
  else v_emp := nullif(p_filtro->>'empresaId','')::uuid; end if;
  v_de := nullif(p_filtro->>'de','')::date; v_ate := nullif(p_filtro->>'ate','')::date;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',a.id,'empresa',e.nome,'data',to_char(a.data,'YYYY-MM-DD'),'hora',a.hora,
      'nome',a.colaborador_nome,'email',a.colaborador_email,'terapeuta',a.terapeuta_nome,
      'status',a.status,'criadoEm',a.criado_em,'questionario',a.questionario) order by a.data desc, a.hora desc),'[]'::jsonb)
    from agendamentos a join empresas e on e.id=a.empresa_id
    where (v_emp is null or a.empresa_id=v_emp)
      and (v_de is null or a.data>=v_de) and (v_ate is null or a.data<=v_ate)
  );
end; $$;

-- ---------- app_terapeuta_agenda: inclui questionario ----------
create or replace function app_terapeuta_agenda(p_token uuid) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare v_ref uuid; v_nome text;
begin
  select (s).v_ref into v_ref from (select _sessao(p_token, array['terapeuta']) s) z;
  select nome into v_nome from terapeutas where id=v_ref;
  return jsonb_build_object('nome', coalesce(v_nome,'Terapeuta'),
    'agendamentos', (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'empresa',e.nome,'data',to_char(a.data,'YYYY-MM-DD'),'hora',a.hora,'nome',a.colaborador_nome,'status',a.status,'criadoEm',a.criado_em,'questionario',a.questionario) order by a.data, a.hora),'[]'::jsonb)
                     from agendamentos a join empresas e on e.id=a.empresa_id where a.terapeuta_id=v_ref and a.data>=_hoje_sp()));
end; $$;

-- ---------- Relatorio de bem-estar (master, gestor e terapeuta) ----------
create or replace function app_relatorio_bem_estar(p_token uuid, p_filtro jsonb) returns jsonb
  language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; v_emp uuid; v_de date; v_ate date;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor','terapeuta']) s) z;
  p_filtro := coalesce(p_filtro,'{}'::jsonb);
  if v_role='gestor' then v_emp := v_ref; else v_emp := nullif(p_filtro->>'empresaId','')::uuid; end if;
  v_de := nullif(p_filtro->>'de','')::date; v_ate := nullif(p_filtro->>'ate','')::date;
  return (
    with q as (
      select a.questionario qq, a.colaborador_nome, a.data, a.hora, e.nome empresa, a.terapeuta_nome
      from agendamentos a join empresas e on e.id=a.empresa_id
      where a.questionario is not null
        and (v_role<>'terapeuta' or a.terapeuta_id=v_ref)
        and (v_emp is null or a.empresa_id=v_emp)
        and (v_de is null or a.data>=v_de) and (v_ate is null or a.data<=v_ate)
    )
    select jsonb_build_object(
      'respostas', (select count(*) from q),
      'medias', jsonb_build_object(
        'estresse',       (select round(avg((qq->>'estresse')::numeric),1)       from q where qq ? 'estresse'),
        'ansiedade',      (select round(avg((qq->>'ansiedade')::numeric),1)      from q where qq ? 'ansiedade'),
        'irritabilidade', (select round(avg((qq->>'irritabilidade')::numeric),1) from q where qq ? 'irritabilidade'),
        'dor',            (select round(avg((qq->>'dor')::numeric),1)            from q where qq ? 'dor')
      ),
      'dores', (select coalesce(jsonb_object_agg(parte, c),'{}'::jsonb) from (
          select parte, count(*) c from q, jsonb_array_elements_text(coalesce(qq->'dores','[]'::jsonb)) parte group by parte
        ) d),
      'setores', (select coalesce(jsonb_object_agg(setor, c),'{}'::jsonb) from (
          select coalesce(nullif(trim(qq->>'setor'),''),'(não informado)') setor, count(*) c from q group by 1
        ) s),
      'registros', (select coalesce(jsonb_agg(jsonb_build_object('nome',colaborador_nome,'data',to_char(data,'YYYY-MM-DD'),'hora',hora,'empresa',empresa,'terapeuta',terapeuta_nome,'q',qq) order by data desc, hora),'[]'::jsonb) from q)
    )
  );
end; $$;

-- ---------- Grants ----------
grant execute on function app_marcar(text,text,text,date,text,jsonb) to anon, authenticated;
grant execute on function app_relatorio_bem_estar(uuid,jsonb)        to anon, authenticated;
