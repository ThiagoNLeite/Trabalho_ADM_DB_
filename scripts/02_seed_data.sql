-- =============================================================================
-- 02_seed_data.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 1.3: Carga inicial de testes (4 setores, 4 usuários, 3 contas em
-- trânsito, com movimentações e anotações registradas)
-- -----------------------------------------------------------------------------
-- Executar conectado ao banco movimentador_contas, como superusuário/dono do
-- esquema (as roles de aplicação ainda não existem neste ponto -- elas são
-- criadas no script 03).
-- =============================================================================

\connect movimentador_contas

-- -----------------------------------------------------------------------------
-- Setores (mínimo de 4, conforme fluxo real descrito na proposta)
-- -----------------------------------------------------------------------------
INSERT INTO workflow.setores (nome, status) VALUES
    ('Auditoria',        'ATIVO'),
    ('Central de Guias',  'ATIVO'),
    ('Faturamento',       'ATIVO'),
    ('Recurso de Glosa',  'ATIVO');

-- -----------------------------------------------------------------------------
-- Usuários (mínimo de 4, um por setor/perfil)
-- Observação: senha_hash aqui é o cadastro FUNCIONAL do usuário (não é a senha
-- de login do PostgreSQL). Usamos crypt()/gen_salt() do pgcrypto apenas para
-- não gravar texto puro nesta coluna sensível.
-- -----------------------------------------------------------------------------
INSERT INTO workflow.usuarios (login_corporativo, nome_completo, setor_id, senha_hash, perfil_acesso) VALUES
    ('auditor.op',        'Ana Beatriz Souza',      (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'),
        crypt('SenhaForte!123', gen_salt('bf')), 'OPERACIONAL'),
    ('guias.op',          'Carlos Eduardo Lima',    (SELECT id FROM workflow.setores WHERE nome = 'Central de Guias'),
        crypt('SenhaForte!456', gen_salt('bf')), 'OPERACIONAL'),
    ('faturamento.op',    'Débora Nascimento',      (SELECT id FROM workflow.setores WHERE nome = 'Faturamento'),
        crypt('SenhaForte!789', gen_salt('bf')), 'OPERACIONAL'),
    ('coordenador.gestao','Fernando Almeida Rocha', (SELECT id FROM workflow.setores WHERE nome = 'Faturamento'),
        crypt('SenhaForte!000', gen_salt('bf')), 'GESTAO');

-- -----------------------------------------------------------------------------
-- Contas em trânsito (mínimo de 3), já nascendo sob responsabilidade da
-- Auditoria, simulando o cenário descrito na proposta (ex.: "Conta 10").
-- -----------------------------------------------------------------------------
INSERT INTO workflow.contas_workflow (codigo_conta, convenio, valor_aproximado, setor_atual_id, status_conta) VALUES
    ('CTA-000010', 'Unimed',        4582.30, (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'), 'EM_ANALISE'),
    ('CTA-000011', 'Bradesco Saúde', 2190.00, (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'), 'RECEBIDA'),
    ('CTA-000012', 'SUS',            980.75,  (SELECT id FROM workflow.setores WHERE nome = 'Central de Guias'), 'PENDENTE');

-- -----------------------------------------------------------------------------
-- Movimentações simulando a jornada da Conta 10 (Auditoria -> Central de Guias)
-- e o recebimento inicial das demais contas.
-- -----------------------------------------------------------------------------
INSERT INTO workflow.movimentacoes (conta_id, setor_origem_id, setor_destino_id, usuario_executor_id, executado_em, observacao) VALUES
    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000010'),
      (SELECT id FROM workflow.setores WHERE nome = 'Faturamento'),
      (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
      TIMESTAMPTZ '2026-08-10 08:30:00-04', 'Conta recebida pela Auditoria.' ),

    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000011'),
      (SELECT id FROM workflow.setores WHERE nome = 'Faturamento'),
      (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
      TIMESTAMPTZ '2026-08-10 09:05:00-04', 'Conta recebida pela Auditoria.' ),

    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000012'),
      (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'),
      (SELECT id FROM workflow.setores WHERE nome = 'Central de Guias'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'guias.op'),
      TIMESTAMPTZ '2026-08-11 16:00:00-04', 'Auditoria concluída. Encaminhada para Central de Guias.' );

-- -----------------------------------------------------------------------------
-- Comentários (anotações de fluxo)
-- -----------------------------------------------------------------------------
INSERT INTO workflow.comentarios (conta_id, usuario_autor_id, registrado_em, descricao) VALUES
    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000010'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
      TIMESTAMPTZ '2026-08-10 14:20:00-04', 'Conta com erros de MAT/MED. Aguardando correção da área.' ),

    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000010'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
      TIMESTAMPTZ '2026-08-11 09:10:00-04', 'Aguardando guia principal.' ),

    ( (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000012'),
      (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'guias.op'),
      TIMESTAMPTZ '2026-08-11 16:05:00-04', 'Guia recebida. Iniciada conferência.' );

-- -----------------------------------------------------------------------------
-- Conferência rápida da carga
-- -----------------------------------------------------------------------------
\echo '--- Setores ---'
SELECT * FROM workflow.setores ORDER BY id;

\echo '--- Usuarios (sem expor senha_hash) ---'
SELECT id, login_corporativo, nome_completo, setor_id, perfil_acesso FROM workflow.usuarios ORDER BY id;

\echo '--- Contas em trânsito ---'
SELECT * FROM workflow.contas_workflow ORDER BY id;

\echo '--- Movimentações ---'
SELECT * FROM workflow.movimentacoes ORDER BY id;

\echo '--- Comentários ---'
SELECT * FROM workflow.comentarios ORDER BY id;

-- Fim do script 02.
