# Movimentador de Contas e Rastreabilidade

**Disciplina:** Administração de Banco de Dados (DBA)
**Instituição:** Hospital Universitário — projeto acadêmico simulando o sistema satélite "Movimentador de Contas e Rastreabilidade"
**Trabalho:** Administração, Segurança e Governança de Dados
**Data limite de entrega:** 18/09/2026
**SGBD utilizado:** PostgreSQL 16

## 1. Identificação dos integrantes

| Nome completo | Função no projeto |
|---|---|
| Thiago Nascimento Leite | DBA / Analista de Segurança e Governança de Dados |

> Trabalho entregue na modalidade **individual**. Se este repositório for adaptado para um grupo, adicione os demais integrantes (nome completo) nesta tabela antes da entrega.

---

## 2. Contexto do projeto

O Hospital Universitário enfrenta gargalos operacionais no trânsito de contas/faturas entre setores (Auditoria, Central de Guias, Faturamento, Recurso de Glosa): dificuldade de localizar uma conta física ou sistemicamente, controles paralelos em planilha, ausência de notificação de repasse e falta de histórico imutável das ações.

Este repositório contém a modelagem, a configuração de segurança (RBAC + LGPD) e a trilha de auditoria forense do **banco de dados próprio** de um sistema satélite de workflow que endereça esses problemas — sem substituir ou escrever no ERP/MV legado, que permanece como fonte oficial e imutável dos dados financeiros da conta (princípio detalhado na seção [5](#5-decisões-de-modelagem-e-arquitetura)).

---

## 3. Estrutura do repositório

```
├── README.md
├── scripts/
│   ├── 01_setup_database.sql      # Criação do banco, schemas e tabelas
│   ├── 02_seed_data.sql           # Carga de dados iniciais para testes
│   ├── 03_security_rbac.sql       # Roles, privilégios e views LGPD
│   ├── 04_audit_setup.sql         # Tabela de auditoria e triggers
│   ├── 05_attack_simulation.sql   # Bateria de testes: operações autorizadas vs. negadas
│   └── 06_forensic_queries.sql    # Consultas que extraem as evidências da auditoria
└── evidencias/
    ├── 05_attack_simulation_output.txt   # Saída real da bateria de testes ofensivos
    ├── 06_forensic_queries_output.txt    # Saída real das consultas forenses
    ├── demo_conexoes_reais.txt           # Mesmos cenários, com conexões TCP reais por usuário
    └── trecho_log_servidor.txt           # Trecho do log nativo do PostgreSQL confirmando os bloqueios
```

---

## 4. Guia de instalação e execução

### 4.1 Pré-requisitos

- PostgreSQL 16 (ou compatível) instalado e em execução.
- Acesso via `psql` com um usuário com privilégio de superusuário (ex.: `postgres`) para os scripts `01` a `04`.
- Extensão `pgcrypto` disponível (usada apenas para gerar o hash de senha funcional de demonstração — instalada automaticamente pelo script `01`).

### 4.2 Ordem de execução (obrigatória)

Os scripts têm dependência sequencial — **execute exatamente nesta ordem**:

```bash
# 1. Cria o banco, os schemas (workflow/audit) e as tabelas
psql -U postgres -f scripts/01_setup_database.sql

# 2. Popula setores, usuários, contas e movimentações de teste
psql -U postgres -f scripts/02_seed_data.sql

# 3. Higieniza PUBLIC, cria roles/usuários (RBAC), grants de coluna e a view segura
psql -U postgres -f scripts/03_security_rbac.sql

# 4. Cria a tabela de auditoria, a função SECURITY DEFINER e os triggers
psql -U postgres -f scripts/04_audit_setup.sql

# 5. Roda a bateria de testes ofensivos (erros são esperados e fazem parte do teste)
psql -U postgres -f scripts/05_attack_simulation.sql | tee evidencias/05_attack_simulation_output.txt

# 6. Consulta a trilha de auditoria e produz as evidências forenses
psql -U postgres -f scripts/06_forensic_queries.sql | tee evidencias/06_forensic_queries_output.txt
```

> Os scripts `01` e demais já se conectam ao banco correto internamente via `\connect movimentador_contas` — não é necessário passar `-d` na linha de comando (exceto para reconexões manuais).

### 4.3 Credenciais dos usuários de teste (criadas pelo script 03)

| Usuário (role de login) | Senha (demo) | Role de grupo | Perfil de negócio |
|---|---|---|---|
| `usr_auditor_op` | `Operacional#2026` | `role_operacional` | Operacional (setor Auditoria) |
| `usr_coordenador_gestao` | `Gestao#2026` | `role_gestao` | Gestão (dashboards) |
| `usr_dba_admin` | `AdminWorkflow#2026` | `role_admin_workflow` | Administrador do workflow |

> **Aviso:** estas senhas existem apenas para viabilizar a correção/demonstração deste trabalho acadêmico. Em qualquer ambiente real, credenciais nunca devem ser gravadas em um script versionado — ver seção [5.6](#56-segurança-e-lgpd).

Para reproduzir qualquer cenário com uma conexão de verdade (útil na apresentação em sala):

```bash
PGPASSWORD='Operacional#2026' psql -h 127.0.0.1 -U usr_auditor_op -d movimentador_contas
```

---

## 5. Decisões de modelagem e arquitetura

### 5.1 Separação de esquemas

O banco `movimentador_contas` é dividido em dois schemas lógicos:

- **`workflow`** — dados de negócio: setores, usuários funcionais, contas em trânsito, movimentações e comentários.
- **`audit`** — trilha de auditoria (`logged_actions`), isolada do schema de negócio para que os privilégios de escrita possam ser tratados de forma completamente diferente (ninguém tem INSERT/UPDATE/DELETE nela, nem o DBA).

### 5.2 Princípio de não alteração do MV/ERP legado

O sistema **não escreve no MV**. `workflow.contas_workflow.codigo_conta` é apenas uma **referência lógica** ao número de conta/atendimento do sistema legado — o suficiente para rastrear o fluxo operacional (setor atual, histórico de trânsito, comentários), sem duplicar dados clínicos ou financeiros sensíveis do paciente. Isso segue a premissa da proposta conceitual que originou este projeto: o MV continua sendo a fonte oficial e imutável dos dados da conta; a aplicação atua apenas como camada de workflow, rastreabilidade e gestão operacional. Uma eventual integração real de leitura (READ ONLY) ao MV é um passo de integração de infraestrutura fora do escopo deste trabalho acadêmico, mas a arquitetura já foi desenhada para não exigir nenhum privilégio de escrita além do próprio banco `movimentador_contas`.

### 5.3 Dicionário de dados (schema `workflow`)

| Tabela | Campo | Tipo | Restrição / observação |
|---|---|---|---|
| `setores` | `id` | SMALLSERIAL | PK |
| | `nome` | VARCHAR(60) | UNIQUE, NOT NULL |
| | `status` | VARCHAR(10) | CHECK (`ATIVO`/`INATIVO`) |
| `usuarios` | `id` | SERIAL | PK |
| | `login_corporativo` | VARCHAR(60) | UNIQUE, NOT NULL |
| | `nome_completo` | VARCHAR(150) | NOT NULL |
| | `setor_id` | SMALLINT | FK → `setores.id` |
| | `senha_hash` | VARCHAR(255) | **Sensível** — coluna protegida por segurança de coluna (5.5) |
| | `perfil_acesso` | VARCHAR(20) | CHECK (`OPERACIONAL`/`GESTAO`/`ADMINISTRADOR`) |
| `contas_workflow` | `id` | SERIAL | PK |
| | `codigo_conta` | VARCHAR(30) | UNIQUE — referência lógica ao nr. de conta/atendimento do MV |
| | `convenio` | VARCHAR(60) | NOT NULL |
| | `valor_aproximado` | NUMERIC(12,2) | CHECK ≥ 0 |
| | `setor_atual_id` | SMALLINT | FK → `setores.id` |
| | `status_conta` | VARCHAR(25) | CHECK — enumeração de status operacionais |
| `movimentacoes` | `id` | BIGSERIAL | PK — **histórico imutável** |
| | `conta_id` | INTEGER | FK → `contas_workflow.id` |
| | `setor_origem_id` / `setor_destino_id` | SMALLINT | FK → `setores.id`; CHECK origem ≠ destino |
| | `usuario_executor_id` | INTEGER | FK → `usuarios.id` |
| | `executado_em` | TIMESTAMPTZ | DEFAULT `now()` |
| `comentarios` | `id` | BIGSERIAL | PK — **histórico imutável** |
| | `conta_id` | INTEGER | FK → `contas_workflow.id` |
| | `usuario_autor_id` | INTEGER | FK → `usuarios.id` |
| | `registrado_em` | TIMESTAMPTZ | DEFAULT `now()` |

Todas as chaves estrangeiras garantem integridade referencial; `CHECK` constraints garantem integridade de domínio (status, valores não-negativos, origem ≠ destino da movimentação).

### 5.4 Modelo de controle de acesso (RBAC)

Adotou-se o padrão **role de grupo (NOLOGIN) + usuário de login (LOGIN) que herda a role**, o que centraliza toda a matriz de privilégios nas três roles de grupo — qualquer auditoria de "quem pode fazer o quê" se resume a inspecionar três roles, não N usuários individuais.

| Role de grupo | Escopo de acesso | Privilégios concedidos | Privilégios explicitamente negados |
|---|---|---|---|
| `role_operacional` | Contas e setores do fluxo operacional | SELECT em `setores`/`contas_workflow`; UPDATE restrito a `setor_atual_id`/`status_conta`; SELECT+INSERT em `movimentacoes`/`comentarios`; SELECT de colunas públicas em `usuarios` | DELETE em qualquer tabela; UPDATE em `movimentacoes`/`comentarios` (imutabilidade); SELECT de `senha_hash` |
| `role_gestao` | Indicadores agregados | SELECT na view `workflow.vw_dashboard_gestao`; SELECT em `setores`; SELECT de colunas públicas em `usuarios` | Qualquer acesso direto às tabelas `contas_workflow`, `movimentacoes`, `comentarios` |
| `role_admin_workflow` | Administração completa do schema `workflow` | ALL PRIVILEGES em tabelas/sequências de `workflow`; SELECT (somente leitura) em `audit.logged_actions` | INSERT/UPDATE/DELETE em `audit.logged_actions` — imutabilidade da trilha vale até para o administrador do sistema |

A política inicial é **zero trust**: todo privilégio herdado por padrão pela role `PUBLIC` (USAGE em schema, CONNECT no banco, SELECT/INSERT/etc. em tabela) é revogado explicitamente no início do script `03`, e `ALTER DEFAULT PRIVILEGES` garante que até objetos criados no futuro nasçam sem acesso para `PUBLIC`.

### 5.5 Segurança em nível de coluna e view segura (LGPD)

- **Coluna sensível isolada:** `workflow.usuarios.senha_hash` nunca é concedida via `GRANT SELECT ON workflow.usuarios`; em vez disso, o grant é feito coluna a coluna (`GRANT SELECT (id, login_corporativo, nome_completo, setor_id, perfil_acesso) ON workflow.usuarios ...`), de forma que um `SELECT *` simplesmente falha com `permission denied` para quem não tem acesso à coluna restrita (comprovado no Cenário B da bateria de testes).
- **View gerencial sem PII:** `workflow.vw_dashboard_gestao` entrega apenas indicadores agregados por setor (total de contas, contas abertas/concluídas, tempo médio) — nenhum identificador pessoal, nenhuma referência a paciente, nenhuma coluna de `usuarios`. `role_gestao` não recebe nenhum grant nas tabelas base: o único caminho de leitura gerencial é essa view.

### 5.6 Segurança e LGPD

- Autenticação com hash forte (`password_encryption = scram-sha-256`), nunca MD5.
- Least privilege como princípio norteador de todas as roles (Etapa 2 do enunciado).
- Trilha de auditoria com estado anterior/posterior (OLD/NEW) em JSONB para rastreabilidade completa sem expor dados fora do necessário.
- Minimização de dados: a base própria nunca duplica dados clínicos do paciente; apenas referências operacionais (código da conta, convênio, valor aproximado).
- **Nota de transparência:** as senhas deste repositório estão em texto plano nos scripts **apenas porque este é um ambiente de demonstração acadêmica descartável**. Em produção, credenciais viriam de um cofre de segredos (ex.: Vault, AWS Secrets Manager) e o script de criação de roles usaria uma variável de ambiente ou um placeholder a ser preenchido no momento do deploy — nunca um valor fixo versionado no Git.

### 5.7 Auditoria imutável (SECURITY DEFINER)

A função `audit.if_modified_func()` é `SECURITY DEFINER`, de propriedade de `postgres`, com `search_path` fixado (mitiga *search_path hijacking*). Isso permite que um trigger disparado por uma sessão sem nenhum privilégio em `audit.logged_actions` (ex.: `usr_auditor_op`) ainda assim grave um evento de auditoria — porque, durante a execução da função, o PostgreSQL usa os privilégios do **dono da função**, não os do usuário que disparou o `INSERT`/`UPDATE`/`DELETE` na tabela de negócio.

A imutabilidade da trilha é garantida em duas camadas:
1. Nenhuma role de aplicação — nem `role_admin_workflow` — recebe `INSERT`/`UPDATE`/`DELETE` em `audit.logged_actions`; apenas a função `SECURITY DEFINER` escreve ali.
2. As tabelas de negócio mais sensíveis (`movimentacoes`, `comentarios`) não recebem `UPDATE`/`DELETE` do perfil operacional — o histórico só cresce, nunca é reescrito.

Requisito mínimo do enunciado: triggers em `movimentacoes` e `contas_workflow`. Este projeto estende o mesmo tratamento a `comentarios`, por ter o mesmo nível de sensibilidade de histórico.

---

## 6. Relatório de incidentes e parecer forense

### 6.1 Metodologia

O script `05_attack_simulation.sql` conecta como cada usuário de teste (via `SET SESSION AUTHORIZATION`, que também atualiza `session_user` — o mesmo campo gravado pela trilha de auditoria) e executa cinco cenários. Os dois primeiros são os cenários mínimos exigidos pelo enunciado; os demais (C, D, E) foram adicionados para reforçar a cobertura de RBAC e de imutabilidade.

A saída completa e literal, gerada rodando os scripts deste repositório contra uma instância real do PostgreSQL 16, está em [`evidencias/05_attack_simulation_output.txt`](evidencias/05_attack_simulation_output.txt). Uma segunda rodada, usando conexões TCP reais e independentes por usuário (mais próxima do que será demonstrado ao vivo em sala), está em [`evidencias/demo_conexoes_reais.txt`](evidencias/demo_conexoes_reais.txt), com o trecho correspondente do log nativo do servidor em [`evidencias/trecho_log_servidor.txt`](evidencias/trecho_log_servidor.txt).

### 6.2 Cenário A — Tentativa de adulteração de histórico

**Ação:** conectado como `usr_auditor_op`, tentar `DELETE` e `UPDATE` em `workflow.movimentacoes`.

**Resultado obtido (saída real do terminal):**

```
--- (A1) DELETE indevido em movimentacoes ---
psql:.../05_attack_simulation.sql:49: ERROR:  permission denied for table movimentacoes
--- (A2) UPDATE indevido em movimentacoes (tentativa de reescrever histórico) ---
psql:.../05_attack_simulation.sql:54: ERROR:  permission denied for table movimentacoes
```

**Parecer:** bloqueio confirmado pelo SGBD em nível de privilégio de tabela, antes mesmo de qualquer linha ser afetada — o histórico permanece intacto porque `role_operacional` nunca recebeu `UPDATE`/`DELETE` em `movimentacoes` (ver 5.4).

### 6.3 Cenário B — Tentativa de acesso a coluna restrita (PII)

**Ação:** conectado como `usr_auditor_op`, tentar `SELECT *` e `SELECT senha_hash` em `workflow.usuarios`.

**Resultado obtido:**

```
--- (B1) SELECT * (inclui senha_hash) -- deve ser NEGADO ---
psql:.../05_attack_simulation.sql:69: ERROR:  permission denied for table usuarios
--- (B2) SELECT explícito da coluna senha_hash -- deve ser NEGADO ---
psql:.../05_attack_simulation.sql:72: ERROR:  permission denied for table usuarios
--- (B3) Controle: SELECT apenas de colunas públicas -- deve FUNCIONAR ---
 id | login_corporativo  |     nome_completo      | setor_id | perfil_acesso
----+--------------------+------------------------+----------+---------------
  1 | auditor.op         | Ana Beatriz Souza      |        1 | OPERACIONAL
  2 | guias.op           | Carlos Eduardo Lima    |        2 | OPERACIONAL
  3 | faturamento.op     | Débora Nascimento      |        3 | OPERACIONAL
  4 | coordenador.gestao | Fernando Almeida Rocha |        3 | GESTAO
(4 rows)
```

**Parecer:** a segurança de coluna funciona mesmo em `SELECT *` — o PostgreSQL nega a consulta inteira quando qualquer coluna referenciada não está autorizada, provando que não há caminho indireto para vazar a credencial.

### 6.4 Cenário C — Operação operacional válida, com rastreamento

**Ação:** `usr_auditor_op` transfere a conta `CTA-000010` da Auditoria para a Central de Guias e registra um comentário.

**Resultado obtido:** `INSERT 0 1`, `UPDATE 1`, `INSERT 0 1` — todas as operações permitidas foram concluídas com sucesso, exatamente porque estão dentro do escopo de privilégio de `role_operacional`.

### 6.5 Cenários adicionais (D e E)

- **D:** `usr_coordenador_gestao` recebe `permission denied` ao tentar `SELECT` direto em `contas_workflow`/`movimentacoes`, mas consulta normalmente `workflow.vw_dashboard_gestao` — prova de que a visão de gestão é servida exclusivamente pela view segura.
- **E:** mesmo `usr_dba_admin` (perfil administrador do workflow) recebe `permission denied` ao tentar `UPDATE`/`DELETE` em `audit.logged_actions`, embora consiga lê-la normalmente — prova de que a imutabilidade da trilha não depende de disciplina do administrador, e sim de privilégio efetivamente ausente no SGBD.

### 6.6 Consulta final à tabela de auditoria (autoria e integridade)

Executando `scripts/06_forensic_queries.sql` (saída completa em [`evidencias/06_forensic_queries_output.txt`](evidencias/06_forensic_queries_output.txt)):

```
--- 1.2 Autoria detalhada das movimentações de conta, com nome do responsável ---
            quando             |   login_sgbd   |    responsavel    | setor_do_responsavel |   conta    | setor_origem |  setor_destino
--------------------------------+----------------+-------------------+----------------------+------------+--------------+------------------
 2026-09-11 23:39:38.138487+00 | usr_auditor_op | Ana Beatriz Souza | Auditoria            | CTA-000010 | Auditoria    | Central de Guias
observação: Auditoria concluída sem pendências. Encaminhada para conferência de guias.

--- 2.1 Prova indireta: nenhuma alteração (U) ou exclusão (D) jamais foi efetivada
        nas tabelas de histórico imutável ---
(0 rows)

--- 3.1 Comprovação de que a trilha de auditoria em si nunca foi alterada ---
 eventos_de_alteracao_na_propria_auditoria
--------------------------------------------
                                          0
```

**Conclusão do parecer forense:**
1. **Autoria** — cada ação válida está associada, de forma verificável, ao login técnico (`session_user_name`) e, por junção com `workflow.usuarios`, ao nome completo e setor do responsável (consulta 1.2).
2. **Tentativas de violação** — todas as tentativas de adulteração de histórico, acesso a coluna restrita e leitura direta indevida (Cenários A, B e D) resultaram em `ERROR: permission denied`, sem qualquer efeito no banco. A ausência dessas operações em `audit.logged_actions` (consulta 2.1) é, por construção, a prova de que elas nunca chegaram a ser efetivadas — um trigger `AFTER` só dispara sobre uma operação que já foi aceita pelo controle de privilégios.
3. **Imutabilidade** — não existe nenhum evento de `UPDATE`/`DELETE` sobre a própria `audit.logged_actions` (consulta 3.1), e o Cenário E comprova, na prática, que nem o perfil administrador consegue alterá-la.

### 6.7 Nota técnica sobre atribuição no log do servidor

Durante os testes, observou-se uma nuance relevante para quem for reproduzir a demonstração: quando a troca de usuário é feita dentro de uma mesma conexão via `SET SESSION AUTHORIZATION` (usado no script `05` para permitir testar os três perfis em uma única sessão não-interativa), a função SQL `session_user` — e portanto a trilha de auditoria — reflete corretamente o usuário trocado (ex.: `usr_auditor_op`). Já o prefixo de log nativo do PostgreSQL (`%u` em `log_line_prefix`) continua mostrando o usuário da conexão TCP original (`postgres`), pois não é atualizado por `SET SESSION AUTHORIZATION`.

Por isso, o repositório também inclui `evidencias/demo_conexoes_reais.txt` e `evidencias/trecho_log_servidor.txt`: nessa segunda rodada, cada cenário foi reproduzido com uma conexão TCP real e independente por usuário (`psql -h 127.0.0.1 -U usr_auditor_op ...`), e o log do servidor passou a atribuir corretamente cada tentativa negada (`usr_auditor_op@movimentador_contas`, `usr_coordenador_gestao@movimentador_contas`, `usr_dba_admin@movimentador_contas`). Essa é a forma recomendada para a apresentação ao vivo em sala.

---

## 7. Critérios de avaliação (referência do enunciado)

| Critério | Peso | Onde este repositório o atende |
|---|---|---|
| Modelagem física e integridade | 20% | `01_setup_database.sql` — tipos, PK/FK, `CHECK`, separação por schemas |
| Controle de acesso (RBAC & LGPD) | 25% | `03_security_rbac.sql` — menor privilégio, roles, segurança de coluna, view segura |
| Auditoria e imutabilidade | 20% | `04_audit_setup.sql` — trigger `SECURITY DEFINER`, OLD/NEW em JSONB, sem escrita de app na auditoria |
| Bateria ofensiva e relatório forense | 15% | `05_attack_simulation.sql` + seção [6](#6-relatório-de-incidentes-e-parecer-forense) |
| Documentação no GitHub e README | 10% | Este arquivo |
| Apresentação em sala | 10% | Roteiro de demonstração com conexões reais em `evidencias/demo_conexoes_reais.txt` |
