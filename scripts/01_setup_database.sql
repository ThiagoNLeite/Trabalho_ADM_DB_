-- =============================================================================
-- 01_setup_database.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 1: Provisionamento de instância e modelagem física do banco próprio
-- -----------------------------------------------------------------------------
-- Este script deve ser executado por um superusuário (ex.: postgres), pois
-- cria o banco de dados da aplicação. Os comandos de conexão (\c) exigem
-- execução via psql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Isolamento de ambiente: banco de dados dedicado da aplicação
-- -----------------------------------------------------------------------------
-- Encoding/locale explícitos evitam herdar configuração de outro ambiente.

CREATE DATABASE movimentador_contas
    ENCODING = 'UTF8'
    TEMPLATE = template0;

COMMENT ON DATABASE movimentador_contas IS
    'Banco próprio do sistema satélite Movimentador de Contas e Rastreabilidade. '
    'Não interfere e não escreve no ERP/MV legado; apenas referencia contas por '
    'código lógico (ver decisão arquitetural no README).';

-- A partir daqui, tudo roda dentro do banco recém-criado.
\connect movimentador_contas

-- Autenticação sempre com hash forte (SCRAM-SHA-256), nunca MD5.
-- (Ajuste equivalente em pg_hba.conf é responsabilidade da infraestrutura;
-- aqui garantimos que qualquer senha definida neste banco use o algoritmo forte.)
SET password_encryption = 'scram-sha-256';

-- -----------------------------------------------------------------------------
-- Esquemas lógicos: separação clara entre dados de negócio (workflow) e
-- dados de infraestrutura/auditoria (audit). Isso também facilita aplicar
-- políticas de privilégio por esquema inteiro na Etapa 2.
-- -----------------------------------------------------------------------------

CREATE SCHEMA workflow AUTHORIZATION postgres;
CREATE SCHEMA audit    AUTHORIZATION postgres;

COMMENT ON SCHEMA workflow IS 'Dados de negócio: setores, usuários, contas em trânsito, movimentações e comentários.';
COMMENT ON SCHEMA audit    IS 'Trilha de auditoria imutável (logged_actions) e objetos de suporte forense.';

-- Extensão usada para gerar identificadores únicos legíveis quando necessário.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- 2. Modelagem relacional do workflow
-- -----------------------------------------------------------------------------

-- SETORES ---------------------------------------------------------------------
CREATE TABLE workflow.setores (
    id          SMALLSERIAL PRIMARY KEY,
    nome        VARCHAR(60)  NOT NULL UNIQUE,
    status      VARCHAR(10)  NOT NULL DEFAULT 'ATIVO'
                    CHECK (status IN ('ATIVO', 'INATIVO')),
    criado_em   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow.setores IS 'Setores hospitalares pelos quais uma conta pode tramitar (ex.: Auditoria, Central de Guias, Faturamento, Recurso de Glosa).';

-- USUARIOS ----------------------------------------------------------------------
-- Observação de segurança: "credencial autenticável" fica em senha_hash.
-- Este NÃO é o mecanismo de login do PostgreSQL (isso é tratado via CREATE ROLE
-- ... LOGIN no script 03) -- é o cadastro funcional do usuário dentro do
-- domínio de negócio, útil para vincular ações a uma pessoa mesmo que o login
-- técnico no SGBD seja feito por um usuário de serviço.
CREATE TABLE workflow.usuarios (
    id              SERIAL PRIMARY KEY,
    login_corporativo VARCHAR(60)  NOT NULL UNIQUE,
    nome_completo   VARCHAR(150) NOT NULL,
    setor_id        SMALLINT     NOT NULL REFERENCES workflow.setores(id),
    senha_hash      VARCHAR(255) NOT NULL,      -- dado sensível: protegido via segurança de coluna (script 03)
    perfil_acesso   VARCHAR(20)  NOT NULL
                        CHECK (perfil_acesso IN ('OPERACIONAL', 'GESTAO', 'ADMINISTRADOR')),
    ativo           BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_em       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow.usuarios IS 'Usuários funcionais da aplicação, vinculados a um setor e a um perfil de acesso (RBAC de negócio).';
COMMENT ON COLUMN workflow.usuarios.senha_hash IS 'Dado sensível. Acesso restrito via GRANT em colunas (ver 03_security_rbac.sql).';

-- CONTAS_WORKFLOW -----------------------------------------------------------------
-- Referência lógica ao atendimento/fatura do sistema MV. O MV continua sendo a
-- fonte oficial; aqui armazenamos apenas o necessário para rastrear o fluxo
-- operacional, sem duplicar dados clínicos do paciente.
CREATE TABLE workflow.contas_workflow (
    id                  SERIAL PRIMARY KEY,
    codigo_conta        VARCHAR(30)  NOT NULL UNIQUE,   -- referência lógica (nr_conta/atendimento no MV)
    convenio            VARCHAR(60)  NOT NULL,
    valor_aproximado    NUMERIC(12,2) NOT NULL CHECK (valor_aproximado >= 0),
    setor_atual_id      SMALLINT     NOT NULL REFERENCES workflow.setores(id),
    data_entrada        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    status_conta        VARCHAR(25)  NOT NULL DEFAULT 'RECEBIDA'
                            CHECK (status_conta IN (
                                'RECEBIDA', 'EM_ANALISE', 'PENDENTE',
                                'AGUARDANDO_AREA', 'AGUARDANDO_DOCUMENTO',
                                'ENCAMINHADA', 'DEVOLVIDA', 'FINALIZADA'
                            )),
    criado_em           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow.contas_workflow IS 'Referência lógica da conta/atendimento em trânsito entre setores. Não é a fonte oficial dos dados financeiros (essa permanece no MV).';

-- MOVIMENTACOES -------------------------------------------------------------------
-- Tabela cuja imutabilidade é regra de negócio central: nunca deve ser possível
-- apagar ou reescrever um registro de trânsito já confirmado (ver script 03,
-- REVOKE de UPDATE/DELETE para role_operacional, e script 04, triggers de auditoria).
CREATE TABLE workflow.movimentacoes (
    id                  BIGSERIAL PRIMARY KEY,
    conta_id            INTEGER      NOT NULL REFERENCES workflow.contas_workflow(id),
    setor_origem_id     SMALLINT     NOT NULL REFERENCES workflow.setores(id),
    setor_destino_id    SMALLINT     NOT NULL REFERENCES workflow.setores(id),
    usuario_executor_id INTEGER      NOT NULL REFERENCES workflow.usuarios(id),
    executado_em        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    observacao          TEXT,
    CHECK (setor_origem_id <> setor_destino_id)
);

COMMENT ON TABLE workflow.movimentacoes IS 'Histórico imutável do trânsito de cada conta entre setores. Toda movimentação gera registro obrigatório (regra de negócio nº 4 da proposta).';

-- COMENTARIOS ---------------------------------------------------------------------
CREATE TABLE workflow.comentarios (
    id              BIGSERIAL PRIMARY KEY,
    conta_id        INTEGER      NOT NULL REFERENCES workflow.contas_workflow(id),
    usuario_autor_id INTEGER     NOT NULL REFERENCES workflow.usuarios(id),
    registrado_em   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    descricao       TEXT         NOT NULL
);

COMMENT ON TABLE workflow.comentarios IS 'Anotações contextuais sobre uma conta (ex.: pendências, ocorrências atípicas). Autor e timestamp são gravados automaticamente pela aplicação/role, nunca informados livremente pelo usuário final.';

-- -----------------------------------------------------------------------------
-- Índices de apoio para consultas operacionais e para a trilha forense
-- -----------------------------------------------------------------------------
CREATE INDEX idx_contas_setor_atual        ON workflow.contas_workflow (setor_atual_id);
CREATE INDEX idx_contas_status             ON workflow.contas_workflow (status_conta);
CREATE INDEX idx_movimentacoes_conta       ON workflow.movimentacoes (conta_id);
CREATE INDEX idx_movimentacoes_usuario     ON workflow.movimentacoes (usuario_executor_id);
CREATE INDEX idx_movimentacoes_executado_em ON workflow.movimentacoes (executado_em);
CREATE INDEX idx_comentarios_conta         ON workflow.comentarios (conta_id);

-- Fim do script 01.
