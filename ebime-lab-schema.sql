-- ============================================================
-- EBIME LAB — Esquema de base de datos (Supabase / PostgreSQL)
-- Plataforma académica de acceso vascular
-- v1.0
-- ============================================================

-- ---------- EXTENSIONES ----------
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- ---------- ENUMS ----------
create type user_role       as enum ('alumno', 'instructor', 'admin');
create type course_level    as enum ('novato', 'principiante_avanzado', 'competente', 'eficiente', 'experto'); -- Benner
create type course_status   as enum ('borrador', 'publicado', 'archivado');
create type lesson_type     as enum ('video', 'pdf', 'texto', 'quiz', 'enlace');
create type enrollment_state as enum ('activa', 'completada', 'expirada', 'cancelada');

-- ============================================================
-- 1. PERFILES
-- ============================================================
create table profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  nombre          text not null,
  apellidos       text,
  profesion       text,                       -- Enfermería, Medicina, TSU...
  institucion     text,
  pais            text,
  ciudad          text,
  telefono        text,
  avatar_url      text,
  rol             user_role not null default 'alumno',
  bio             text,
  creado_en       timestamptz not null default now(),
  actualizado_en  timestamptz not null default now()
);

-- Trigger: crear perfil automáticamente al registrarse
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)));
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ============================================================
-- 2. CATÁLOGO
-- ============================================================
create table categories (
  id          uuid primary key default uuid_generate_v4(),
  nombre      text not null,
  slug        text not null unique,
  descripcion text,
  icono       text,          -- nombre de icono o URL SVG
  orden       int not null default 0
);

create table instructors (
  id           uuid primary key default uuid_generate_v4(),
  profile_id   uuid references profiles(id) on delete set null,
  nombre       text not null,
  credenciales text,          -- "MSc, EPA, Enfermero especialista en accesos vasculares"
  bio          text,
  foto_url     text,
  linkedin     text,
  publicado    boolean not null default true
);

create table courses (
  id              uuid primary key default uuid_generate_v4(),
  titulo          text not null,
  slug            text not null unique,
  subtitulo       text,
  descripcion     text,
  objetivos       jsonb default '[]'::jsonb,     -- array de strings
  dirigido_a      text,
  category_id     uuid references categories(id) on delete set null,
  instructor_id   uuid references instructors(id) on delete set null,
  nivel           course_level not null default 'principiante_avanzado',
  horas           numeric(5,1) not null default 0,
  portada_url     text,
  trailer_url     text,
  precio_cop      numeric(12,0) default 0,
  precio_mxn      numeric(12,0) default 0,
  gratuito        boolean not null default false,
  estado          course_status not null default 'borrador',
  emite_certificado boolean not null default true,
  nota_minima     int not null default 70,       -- % para aprobar
  publicado_en    timestamptz,
  creado_en       timestamptz not null default now(),
  actualizado_en  timestamptz not null default now()
);

create index on courses (category_id);
create index on courses (estado);

-- ============================================================
-- 3. CONTENIDO
-- ============================================================
create table modules (
  id          uuid primary key default uuid_generate_v4(),
  course_id   uuid not null references courses(id) on delete cascade,
  titulo      text not null,
  descripcion text,
  orden       int not null default 0
);
create index on modules (course_id);

create table lessons (
  id             uuid primary key default uuid_generate_v4(),
  module_id      uuid not null references modules(id) on delete cascade,
  titulo         text not null,
  tipo           lesson_type not null default 'video',
  contenido      text,          -- HTML/markdown para tipo 'texto'
  media_url      text,          -- embed Vimeo/Bunny, URL de PDF, etc.
  duracion_min   int default 0,
  orden          int not null default 0,
  vista_previa   boolean not null default false,  -- accesible sin matrícula
  creado_en      timestamptz not null default now()
);
create index on lessons (module_id);

create table lesson_resources (
  id         uuid primary key default uuid_generate_v4(),
  lesson_id  uuid not null references lessons(id) on delete cascade,
  titulo     text not null,
  archivo_url text not null,
  tipo       text            -- pdf, xlsx, pptx...
);

-- ============================================================
-- 4. MATRÍCULAS Y PROGRESO
-- ============================================================
create table enrollments (
  id           uuid primary key default uuid_generate_v4(),
  user_id      uuid not null references profiles(id) on delete cascade,
  course_id    uuid not null references courses(id) on delete cascade,
  estado       enrollment_state not null default 'activa',
  matriculado_en timestamptz not null default now(),
  completado_en  timestamptz,
  expira_en      timestamptz,
  unique (user_id, course_id)
);
create index on enrollments (user_id);

create table lesson_progress (
  id            uuid primary key default uuid_generate_v4(),
  user_id       uuid not null references profiles(id) on delete cascade,
  lesson_id     uuid not null references lessons(id) on delete cascade,
  completado    boolean not null default false,
  segundos_vistos int not null default 0,
  actualizado_en timestamptz not null default now(),
  unique (user_id, lesson_id)
);
create index on lesson_progress (user_id);

-- ============================================================
-- 5. EVALUACIÓN
-- ============================================================
create table quiz_questions (
  id          uuid primary key default uuid_generate_v4(),
  lesson_id   uuid not null references lessons(id) on delete cascade,
  enunciado   text not null,
  opciones    jsonb not null,          -- [{"id":"a","texto":"..."}, ...]
  correcta    text not null,           -- "a"
  explicacion text,
  orden       int not null default 0
);

create table quiz_attempts (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references profiles(id) on delete cascade,
  lesson_id   uuid not null references lessons(id) on delete cascade,
  respuestas  jsonb not null,
  puntaje     numeric(5,2) not null,
  aprobado    boolean not null default false,
  intento_en  timestamptz not null default now()
);
create index on quiz_attempts (user_id, lesson_id);

-- ============================================================
-- 6. CERTIFICADOS
-- ============================================================
create table certificates (
  id                  uuid primary key default uuid_generate_v4(),
  user_id             uuid not null references profiles(id) on delete cascade,
  course_id           uuid not null references courses(id) on delete cascade,
  codigo_verificacion text not null unique default upper(encode(gen_random_bytes(6),'hex')),
  nombre_alumno       text not null,   -- snapshot al momento de emitir
  titulo_curso        text not null,
  horas               numeric(5,1),
  pdf_url             text,
  emitido_en          timestamptz not null default now(),
  unique (user_id, course_id)
);
create index on certificates (codigo_verificacion);

-- ============================================================
-- 7. VISTA DE PROGRESO POR CURSO
-- ============================================================
create or replace view v_course_progress as
select
  e.user_id,
  e.course_id,
  count(l.id)                                    as total_lecciones,
  count(lp.id) filter (where lp.completado)      as lecciones_completadas,
  case when count(l.id) = 0 then 0
       else round(100.0 * count(lp.id) filter (where lp.completado) / count(l.id), 1)
  end                                            as porcentaje
from enrollments e
join modules m on m.course_id = e.course_id
join lessons l on l.module_id = m.id
left join lesson_progress lp on lp.lesson_id = l.id and lp.user_id = e.user_id
group by e.user_id, e.course_id;

-- ============================================================
-- 8. FUNCIÓN AUXILIAR DE ROL
-- ============================================================
create or replace function is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and rol = 'admin');
$$;

create or replace function is_enrolled(c uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from enrollments
    where user_id = auth.uid() and course_id = c and estado in ('activa','completada')
  );
$$;

-- ============================================================
-- 9. ROW LEVEL SECURITY
-- ============================================================
alter table profiles         enable row level security;
alter table categories       enable row level security;
alter table instructors      enable row level security;
alter table courses          enable row level security;
alter table modules          enable row level security;
alter table lessons          enable row level security;
alter table lesson_resources enable row level security;
alter table enrollments      enable row level security;
alter table lesson_progress  enable row level security;
alter table quiz_questions   enable row level security;
alter table quiz_attempts    enable row level security;
alter table certificates     enable row level security;

-- PROFILES
create policy "perfil propio: leer"     on profiles for select using (auth.uid() = id or is_admin());
create policy "perfil propio: editar"   on profiles for update using (auth.uid() = id or is_admin());

-- CATÁLOGO PÚBLICO
create policy "categorias publicas"     on categories  for select using (true);
create policy "instructores publicos"   on instructors for select using (publicado or is_admin());
create policy "cursos publicados"       on courses     for select using (estado = 'publicado' or is_admin());

create policy "admin gestiona categorias"  on categories  for all using (is_admin()) with check (is_admin());
create policy "admin gestiona instructores" on instructors for all using (is_admin()) with check (is_admin());
create policy "admin gestiona cursos"       on courses     for all using (is_admin()) with check (is_admin());

-- MÓDULOS: visibles si el curso está publicado
create policy "modulos visibles" on modules for select
  using (exists (select 1 from courses c where c.id = course_id and (c.estado='publicado' or is_admin())));
create policy "admin gestiona modulos" on modules for all using (is_admin()) with check (is_admin());

-- LECCIONES: vista previa abierta; resto solo matriculados
create policy "lecciones accesibles" on lessons for select
  using (
    vista_previa
    or is_admin()
    or exists (
      select 1 from modules m where m.id = module_id and is_enrolled(m.course_id)
    )
  );
create policy "admin gestiona lecciones" on lessons for all using (is_admin()) with check (is_admin());

-- RECURSOS: solo matriculados
create policy "recursos matriculados" on lesson_resources for select
  using (
    is_admin() or exists (
      select 1 from lessons l join modules m on m.id = l.module_id
      where l.id = lesson_id and is_enrolled(m.course_id)
    )
  );
create policy "admin gestiona recursos" on lesson_resources for all using (is_admin()) with check (is_admin());

-- MATRÍCULAS
create policy "matriculas propias"        on enrollments for select using (user_id = auth.uid() or is_admin());
create policy "auto-matricula gratuitos"  on enrollments for insert
  with check (
    user_id = auth.uid()
    and exists (select 1 from courses c where c.id = course_id and c.gratuito and c.estado='publicado')
  );
create policy "admin gestiona matriculas" on enrollments for all using (is_admin()) with check (is_admin());

-- PROGRESO
create policy "progreso propio: leer"     on lesson_progress for select using (user_id = auth.uid() or is_admin());
create policy "progreso propio: escribir" on lesson_progress for insert with check (user_id = auth.uid());
create policy "progreso propio: update"   on lesson_progress for update using (user_id = auth.uid());

-- QUIZ: preguntas visibles a matriculados, SIN exponer 'correcta' al cliente
-- (exponer vía RPC; ver nota abajo)
create policy "preguntas matriculados" on quiz_questions for select
  using (
    is_admin() or exists (
      select 1 from lessons l join modules m on m.id = l.module_id
      where l.id = lesson_id and is_enrolled(m.course_id)
    )
  );
create policy "admin gestiona preguntas" on quiz_questions for all using (is_admin()) with check (is_admin());

create policy "intentos propios: leer"    on quiz_attempts for select using (user_id = auth.uid() or is_admin());
create policy "intentos propios: crear"   on quiz_attempts for insert with check (user_id = auth.uid());

-- CERTIFICADOS
create policy "certificados propios" on certificates for select using (user_id = auth.uid() or is_admin());
create policy "admin gestiona certificados" on certificates for all using (is_admin()) with check (is_admin());

-- Verificación pública de certificado por código (RPC, sin RLS de tabla)
create or replace function verificar_certificado(codigo text)
returns table (nombre_alumno text, titulo_curso text, horas numeric, emitido_en timestamptz)
language sql security definer stable set search_path = public as $$
  select nombre_alumno, titulo_curso, horas, emitido_en
  from certificates where codigo_verificacion = upper(codigo);
$$;

-- ============================================================
-- 10. SEED MÍNIMO DE CATEGORÍAS
-- ============================================================
insert into categories (nombre, slug, descripcion, orden) values
  ('Accesos Vasculares',      'accesos-vasculares',      'Selección, inserción y manejo de DAV', 1),
  ('Ultrasonido Vascular',    'ultrasonido-vascular',    'RaPeVA, RaCeVA, RaFeVA, RAVESTO',      2),
  ('Cuidado y Mantenimiento', 'cuidado-mantenimiento',   'ANTT, bundles, prevención CRBSI',      3),
  ('Terapia Infusional',      'terapia-infusional',      'Fármacos, pH, osmolaridad, vesicantes',4),
  ('Pediatría y Neonatal',    'pediatria-neonatal',      'Accesos en población pediátrica',      5),
  ('Gestión de Equipos',      'gestion-equipos',         'EIAV, indicadores, sostenibilidad',    6)
on conflict (slug) do nothing;
