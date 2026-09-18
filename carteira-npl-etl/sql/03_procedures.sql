/* =====================================================================
   03_procedures.sql

   O QUE ESTE SCRIPT FAZ
   Cria toda a orquestracao do pipeline:
     abrir lote -> (SSIS carrega o staging) -> validar -> carregar -> fechar

   POR QUE A REGRA DE NEGOCIO FICA AQUI E NAO DENTRO DO SSIS
   Essa e uma decisao de arquitetura que vale defender numa entrevista.
   Regra escrita em T-SQL e legivel sem abrir o Visual Studio, entra no
   controle de versao como texto (da para revisar num pull request),
   pode ser testada isoladamente e pode ser reexecutada sem reprocessar
   o arquivo. Regra escrita dentro de um Data Flow do SSIS vira caixa
   preta: o diff no Git e XML ilegivel e so quem tem a ferramenta
   instalada consegue entender o que acontece.
   O papel do SSIS neste projeto e transporte e orquestracao. Ele leva o
   texto bruto para o staging e chama as procedures. So isso.
   ===================================================================== */

USE CarteiraNPL;
GO

/* =====================================================================
   ctl.sp_registrar_log

   O QUE FAZ
   Grava uma linha na trilha de execucao do lote.

   POR QUE UMA PROCEDURE E NAO UM INSERT SOLTO
   Todas as etapas registram log da mesma forma. Centralizar significa
   que, se amanha o log precisar tambem gravar o usuario, o servidor ou
   mandar um alerta, isso muda num lugar so.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ctl.sp_registrar_log
    @id_lote     INT,
    @ds_etapa    VARCHAR(60),
    @ds_mensagem VARCHAR(500) = NULL,
    @qt_linhas   INT = NULL,
    @ms_duracao  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;   -- evita mandar "N linhas afetadas" de volta ao SSIS

    INSERT INTO ctl.log_etapa (id_lote, ds_etapa, ds_mensagem, qt_linhas, ms_duracao)
    VALUES (@id_lote, @ds_etapa, @ds_mensagem, @qt_linhas, @ms_duracao);
END
GO

/* =====================================================================
   ctl.sp_abrir_lote

   O QUE FAZ
   Primeiro passo do pipeline. Abre o lote e devolve o id_lote num
   result set, para o SSIS gravar na variavel User::IdLote.

   POR QUE DEVOLVE EM RESULT SET E NAO SO EM OUTPUT
   O Execute SQL Task do SSIS le resultado de forma muito mais simples
   com ResultSet = Single row do que com parametro de saida. E uma
   concessao deliberada a ferramenta que vai consumir a procedure.

   A SEGUNDA CAMADA DE IDEMPOTENCIA
   O bloco IF EXISTS barra o arquivo que ja foi carregado com sucesso,
   antes de qualquer linha entrar no staging. A primeira camada e o
   indice unico filtrado criado no script 01; esta aqui existe para que
   a falha aconteca cedo e com mensagem clara, em vez de estourar la na
   frente com erro de violacao de indice.
   O parametro @fl_forcar existe porque reprocessar de proposito e uma
   necessidade real, so nao pode ser acidental.

   POR QUE CANCELAR LOTES PENDURADOS
   Se uma carga anterior do mesmo arquivo morreu no meio, ela fica com
   status ABERTO para sempre e polui o relatorio. Marcar como CANCELADO
   antes de abrir o novo mantem o historico limpo sem apagar nada.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ctl.sp_abrir_lote
    @nm_arquivo    VARCHAR(260),
    @cd_cedente    VARCHAR(10),
    @dt_referencia DATE = NULL,
    @fl_forcar     BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @fl_forcar = 0
       AND EXISTS (SELECT 1 FROM ctl.lote
                   WHERE nm_arquivo = @nm_arquivo AND ds_status = 'CARREGADO')
    BEGIN
        RAISERROR('Arquivo %s ja foi carregado com sucesso. Use @fl_forcar = 1 para reprocessar.',
                  16, 1, @nm_arquivo);
        RETURN;
    END

    UPDATE ctl.lote
       SET ds_status = 'CANCELADO',
           dt_fim    = SYSDATETIME()
     WHERE nm_arquivo = @nm_arquivo
       AND ds_status IN ('ABERTO','VALIDADO','ERRO');

    INSERT INTO ctl.lote (nm_arquivo, cd_cedente, dt_referencia)
    VALUES (@nm_arquivo, @cd_cedente, @dt_referencia);

    DECLARE @id_lote INT = SCOPE_IDENTITY();

    EXEC ctl.sp_registrar_log @id_lote, 'ABERTURA', @nm_arquivo;

    SELECT @id_lote AS id_lote;
END
GO

/* =====================================================================
   stg.sp_validar_lote

   O QUE FAZ
   Aplica todas as regras contra o staging, grava as violacoes na
   quarentena e marca cada linha como valida ou invalida.

   O PADRAO USADO: UMA REGRA = UM INSERT
   Cada regra e um INSERT ... SELECT independente na quarentena. Isso tem
   tres consequencias boas:
     1. uma linha pode acumular varias violacoes, e o usuario ve todas de
        uma vez em vez de corrigir uma por carga
     2. adicionar uma regra nova e acrescentar um bloco, sem tocar nos
        anteriores
     3. cada regra e conjunto puro (set-based), sem cursor e sem loop
   So depois de aplicar tudo e que o UPDATE final decide a validade da
   linha, consultando a severidade cadastrada em ctl.regra_validacao.
   Por isso a procedure nao precisa saber quais regras bloqueiam.

   POR QUE APAGA AS REJEICOES ANTES DE COMECAR
   Para que reexecutar a validacao do mesmo lote produza exatamente o
   mesmo resultado, sem duplicar rejeicao. Validacao tem que ser
   repetivel.

   POR QUE A ORDEM IMPORTA
   Contratos sao validados primeiro porque a regra E020 (parcela orfa)
   consulta fl_valido do contrato. Parcela de contrato rejeitado tambem
   deve ser rejeitada, senao entraria parcela sem pai.

   POR QUE TRY...CATCH
   Se algo inesperado acontecer, o lote precisa terminar com status ERRO
   e a mensagem registrada no log. Um THROW no final repassa o erro para
   o SSIS, que entao interrompe o fluxo. Falha silenciosa e pior que
   falha barulhenta.
   ===================================================================== */
CREATE OR ALTER PROCEDURE stg.sp_validar_lote
    @id_lote INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(3) = SYSDATETIME();

    BEGIN TRY
        DELETE FROM qua.registro_rejeitado WHERE id_lote = @id_lote;

        UPDATE stg.contrato_carteira SET fl_valido = NULL WHERE id_lote = @id_lote;
        UPDATE stg.parcela_contrato  SET fl_valido = NULL WHERE id_lote = @id_lote;

        /* =============================================================
           REGRAS DE CONTRATO
           ============================================================= */

        -- E001 documento invalido
        -- Documento errado significa contrato que nao da para cobrar nem
        -- localizar. E a rejeicao mais critica da carteira.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E001', s.nu_documento
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND util.fn_valida_documento(s.nu_documento) = 0;

        -- E002 nome ausente
        -- Menos de 3 caracteres cobre vazio, espaco em branco e inicial
        -- solta, que sao os tres jeitos de o campo vir "preenchido" sem
        -- estar preenchido.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E002', s.nm_devedor
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND LEN(ISNULL(LTRIM(RTRIM(s.nm_devedor)), '')) < 3;

        -- E003 data de contratacao nao convertivel
        -- A funcao devolve NULL quando nao consegue converter, entao o
        -- teste de invalidez e simplesmente IS NULL.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E003', s.dt_contratacao
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND util.fn_converte_data(s.dt_contratacao) IS NULL;

        -- E004 data de contratacao no futuro
        -- Regra de sanidade. Data futura quase sempre indica inversao de
        -- dia e mes na origem, ou campo trocado no layout.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E004', s.dt_contratacao
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND util.fn_converte_data(s.dt_contratacao) > CAST(GETDATE() AS DATE);

        -- E005 valor principal invalido
        -- O ISNULL(...,-1) trata num unico predicado dois casos
        -- diferentes: valor que nao converteu (NULL) e valor zerado ou
        -- negativo. Sem o ISNULL, NULL <= 0 daria UNKNOWN e a linha
        -- invalida escaparia da rejeicao.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E005', s.vl_principal
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND ISNULL(util.fn_converte_decimal(s.vl_principal), -1) <= 0;

        -- E006 valor atualizado menor que principal
        -- Cadastrada como ALERTA, nao bloqueia. Pode ser erro de calculo
        -- do cedente, mas tambem pode ser acordo ou desconto legitimo.
        -- A linha entra e o caso fica registrado para conferencia.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E006', s.vl_atualizado
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND util.fn_converte_decimal(s.vl_atualizado) IS NOT NULL
           AND util.fn_converte_decimal(s.vl_principal)  IS NOT NULL
           AND util.fn_converte_decimal(s.vl_atualizado) < util.fn_converte_decimal(s.vl_principal);

        -- E007 dias de atraso invalido
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E007', s.qt_dias_atraso
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND ISNULL(TRY_CONVERT(INT, s.qt_dias_atraso), -1) < 0;

        -- E008 UF desconhecida (alerta)
        -- Nao bloqueia porque UF errada nao impede cobrar, so atrapalha
        -- a segmentacao geografica da regua de acionamento.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E008', s.sg_uf
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND NOT EXISTS (SELECT 1 FROM util.uf u
                            WHERE u.sg_uf = UPPER(LTRIM(RTRIM(s.sg_uf))));

        -- E009 produto fora do catalogo
        -- NOT EXISTS, e nao NOT IN. Se a tabela de dominio tivesse uma
        -- linha com NULL, o NOT IN devolveria conjunto vazio e nenhuma
        -- linha seria rejeitada, um erro silencioso classico.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', s.id_stg, s.nu_contrato, 'E009', s.cd_produto
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote
           AND NOT EXISTS (SELECT 1 FROM crd.produto p
                            WHERE p.cd_produto = UPPER(LTRIM(RTRIM(s.cd_produto))));

        -- E010 contrato duplicado no lote
        -- ROW_NUMBER particionado pela chave natural numera as repeticoes.
        -- A de numero 1 fica, as demais vao para a quarentena.
        -- ROW_NUMBER e nao RANK: RANK empataria as duplicatas em 1 e
        -- nenhuma seria descartada.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'CONTRATO', d.id_stg, d.nu_contrato, 'E010', d.nu_contrato
          FROM (
                SELECT s.id_stg, s.nu_contrato,
                       ROW_NUMBER() OVER (PARTITION BY s.cd_cedente, s.nu_contrato
                                              ORDER BY s.id_stg) AS rn
                  FROM stg.contrato_carteira s
                 WHERE s.id_lote = @id_lote
               ) d
         WHERE d.rn > 1;

        /* Decide a validade de cada contrato.
           Consulta a severidade cadastrada, entao mudar uma regra de
           ALERTA para BLOQUEIA e um UPDATE na tabela de regras, sem
           tocar nesta procedure. */
        UPDATE s
           SET fl_valido = CASE WHEN EXISTS (
                                    SELECT 1
                                      FROM qua.registro_rejeitado r
                                      JOIN ctl.regra_validacao g ON g.cd_erro = r.cd_erro
                                     WHERE r.id_lote = @id_lote
                                       AND r.ds_entidade = 'CONTRATO'
                                       AND r.id_stg = s.id_stg
                                       AND g.ds_severidade = 'BLOQUEIA')
                                THEN 0 ELSE 1 END
          FROM stg.contrato_carteira s
         WHERE s.id_lote = @id_lote;

        /* =============================================================
           REGRAS DE PARCELA
           ============================================================= */

        -- E020 parcela orfa
        -- Duas condicoes: o contrato nao esta neste lote como valido E
        -- tambem nao existe na base. O segundo NOT EXISTS e essencial,
        -- porque e comum o cedente mandar so as parcelas novas de um
        -- contrato que ja foi carregado em lote anterior.
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'PARCELA', p.id_stg,
               CONCAT(p.nu_contrato, '/', p.nu_parcela), 'E020', p.nu_contrato
          FROM stg.parcela_contrato p
         WHERE p.id_lote = @id_lote
           AND NOT EXISTS (SELECT 1 FROM stg.contrato_carteira c
                            WHERE c.id_lote = @id_lote
                              AND c.cd_cedente = p.cd_cedente
                              AND c.nu_contrato = p.nu_contrato
                              AND c.fl_valido = 1)
           AND NOT EXISTS (SELECT 1 FROM crd.contrato k
                            WHERE k.cd_cedente = p.cd_cedente
                              AND k.nu_contrato = p.nu_contrato);

        -- E021 vencimento invalido
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'PARCELA', p.id_stg,
               CONCAT(p.nu_contrato, '/', p.nu_parcela), 'E021', p.dt_vencimento
          FROM stg.parcela_contrato p
         WHERE p.id_lote = @id_lote
           AND util.fn_converte_data(p.dt_vencimento) IS NULL;

        -- E022 valor invalido
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'PARCELA', p.id_stg,
               CONCAT(p.nu_contrato, '/', p.nu_parcela), 'E022', p.vl_parcela
          FROM stg.parcela_contrato p
         WHERE p.id_lote = @id_lote
           AND ISNULL(util.fn_converte_decimal(p.vl_parcela), -1) <= 0;

        -- E023 numero de parcela invalido
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'PARCELA', p.id_stg,
               CONCAT(p.nu_contrato, '/', p.nu_parcela), 'E023', p.nu_parcela
          FROM stg.parcela_contrato p
         WHERE p.id_lote = @id_lote
           AND ISNULL(TRY_CONVERT(INT, p.nu_parcela), 0) <= 0;

        -- E024 parcela duplicada no lote
        INSERT INTO qua.registro_rejeitado (id_lote, ds_entidade, id_stg, ds_chave, cd_erro, ds_valor)
        SELECT @id_lote, 'PARCELA', d.id_stg,
               CONCAT(d.nu_contrato, '/', d.nu_parcela), 'E024', d.nu_parcela
          FROM (
                SELECT p.id_stg, p.nu_contrato, p.nu_parcela,
                       ROW_NUMBER() OVER (PARTITION BY p.cd_cedente, p.nu_contrato, p.nu_parcela
                                              ORDER BY p.id_stg) AS rn
                  FROM stg.parcela_contrato p
                 WHERE p.id_lote = @id_lote
               ) d
         WHERE d.rn > 1;

        UPDATE p
           SET fl_valido = CASE WHEN EXISTS (
                                    SELECT 1
                                      FROM qua.registro_rejeitado r
                                      JOIN ctl.regra_validacao g ON g.cd_erro = r.cd_erro
                                     WHERE r.id_lote = @id_lote
                                       AND r.ds_entidade = 'PARCELA'
                                       AND r.id_stg = p.id_stg
                                       AND g.ds_severidade = 'BLOQUEIA')
                                THEN 0 ELSE 1 END
          FROM stg.parcela_contrato p
         WHERE p.id_lote = @id_lote;

        /* Contadores do lote.
           O UNION ALL soma contratos e parcelas numa passada so. Esses
           tres numeros sao o que o operador olha de manha para saber se
           o arquivo do dia veio bom. */
        DECLARE @lidas INT, @ok INT, @rej INT;

        SELECT @lidas = COUNT(*),
               @ok    = SUM(CASE WHEN fl_valido = 1 THEN 1 ELSE 0 END),
               @rej   = SUM(CASE WHEN fl_valido = 0 THEN 1 ELSE 0 END)
          FROM (SELECT fl_valido FROM stg.contrato_carteira WHERE id_lote = @id_lote
                UNION ALL
                SELECT fl_valido FROM stg.parcela_contrato  WHERE id_lote = @id_lote) t;

        UPDATE ctl.lote
           SET qt_linhas_lidas = @lidas,
               qt_linhas_ok    = @ok,
               qt_linhas_rej   = @rej,
               ds_status       = 'VALIDADO'
         WHERE id_lote = @id_lote;

        DECLARE @ms INT = DATEDIFF(MILLISECOND, @inicio, SYSDATETIME());
        EXEC ctl.sp_registrar_log @id_lote, 'VALIDACAO',
             'Validacao concluida', @rej, @ms;
    END TRY
    BEGIN CATCH
        UPDATE ctl.lote SET ds_status = 'ERRO' WHERE id_lote = @id_lote;

        DECLARE @erro VARCHAR(500) = LEFT(ERROR_MESSAGE(), 500);
        EXEC ctl.sp_registrar_log @id_lote, 'VALIDACAO', @erro;
        THROW;   -- repassa o erro para quem chamou, o SSIS interrompe o fluxo
    END CATCH
END
GO

/* =====================================================================
   crd.sp_carregar_lote

   O QUE FAZ
   Move o que foi aprovado do staging para o modelo de negocio, usando
   MERGE em tres niveis: devedor, contrato e parcela.

   POR QUE MERGE E NAO DELETE + INSERT
   DELETE seguido de INSERT recria a linha com um id novo a cada carga.
   Isso quebraria as parcelas, que apontam para o id do contrato, e
   destruiria dt_inclusao, que e a informacao de quando aquele contrato
   entrou na carteira. O MERGE preserva a chave substituta e o historico.

   POR QUE A ORDEM DEVEDOR, CONTRATO, PARCELA
   Ordem de dependencia. O contrato precisa do id_devedor ja existente
   para gravar a FK, e a parcela precisa do id_contrato.

   O IDIOMA "WHEN MATCHED AND EXISTS (... EXCEPT ...)"
   Esse e o detalhe que separa MERGE ingenuo de MERGE bem escrito.
   Sem ele, todo registro que veio no arquivo receberia UPDATE, mesmo
   quando nada mudou. Numa carteira de milhoes de linhas isso significa
   log de transacao enorme e fragmentacao de indice todo dia, sem uma
   unica alteracao real de dado.
   EXCEPT compara conjuntos e trata NULL corretamente: NULL EXCEPT NULL
   nao retorna linha, ou seja, nao acusa diferenca. Se a comparacao fosse
   escrita com <>, qualquer coluna NULL daria UNKNOWN e o UPDATE nao
   aconteceria quando deveria.

   POR QUE ROW_NUMBER ... WHERE rn = 1 NA ORIGEM DO MERGE
   MERGE falha com erro se a fonte tiver mais de uma linha para a mesma
   chave de destino. Como o mesmo devedor aparece em varios contratos do
   arquivo, e preciso escolher uma linha por documento antes. O
   ORDER BY id_stg DESC escolhe a ocorrencia mais recente do arquivo,
   partindo do principio de que a ultima linha traz o cadastro mais atual.

   POR QUE XACT_ABORT ON E TRANSACAO EXPLICITA
   As tres cargas tem que ser tudo ou nada. Contrato gravado sem devedor,
   ou parcela sem contrato, deixaria a base num estado inconsistente.
   XACT_ABORT garante que qualquer erro em tempo de execucao aborte a
   transacao inteira, mesmo os que nao passariam pelo CATCH.
   ===================================================================== */
CREATE OR ALTER PROCEDURE crd.sp_carregar_lote
    @id_lote INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inicio DATETIME2(3) = SYSDATETIME();
    DECLARE @qt_dev INT = 0, @qt_ctr INT = 0, @qt_par INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------------- DEVEDOR ----------------
           Chave natural: documento normalizado.
           O mesmo CPF pode chegar mascarado num contrato e limpo em
           outro. Sem normalizar, a mesma pessoa viraria dois cadastros. */
        ;WITH origem AS (
            SELECT util.fn_somente_digitos(s.nu_documento)  AS nu_documento,
                   util.fn_tipo_pessoa(s.nu_documento)      AS tp_pessoa,
                   util.fn_normaliza_nome(s.nm_devedor)     AS nm_devedor,
                   util.fn_converte_data(s.dt_nascimento)   AS dt_nascimento,
                   UPPER(LTRIM(RTRIM(s.sg_uf)))             AS sg_uf,
                   util.fn_somente_digitos(s.nu_telefone)   AS nu_telefone,
                   LOWER(LTRIM(RTRIM(s.ds_email)))          AS ds_email,
                   ROW_NUMBER() OVER (
                       PARTITION BY util.fn_somente_digitos(s.nu_documento)
                           ORDER BY s.id_stg DESC)          AS rn
              FROM stg.contrato_carteira s
             WHERE s.id_lote = @id_lote
               AND s.fl_valido = 1
        )
        MERGE crd.devedor AS alvo
        USING (SELECT * FROM origem WHERE rn = 1) AS org
           ON alvo.nu_documento = org.nu_documento
        WHEN MATCHED AND EXISTS (
                SELECT alvo.nm_devedor, alvo.dt_nascimento, alvo.sg_uf, alvo.nu_telefone, alvo.ds_email
                EXCEPT
                SELECT org.nm_devedor,  org.dt_nascimento,  org.sg_uf,  org.nu_telefone,  org.ds_email)
            THEN UPDATE SET
                 alvo.nm_devedor     = org.nm_devedor,
                 alvo.dt_nascimento  = org.dt_nascimento,
                 alvo.sg_uf          = org.sg_uf,
                 alvo.nu_telefone    = org.nu_telefone,
                 alvo.ds_email       = org.ds_email,
                 alvo.dt_atualizacao = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (nu_documento, tp_pessoa, nm_devedor, dt_nascimento, sg_uf, nu_telefone, ds_email)
                 VALUES (org.nu_documento, org.tp_pessoa, org.nm_devedor, org.dt_nascimento,
                         org.sg_uf, org.nu_telefone, org.ds_email);

        SET @qt_dev = @@ROWCOUNT;

        /* Nao existe WHEN NOT MATCHED BY SOURCE de proposito.
           Contrato que nao veio no arquivo de hoje nao deve ser apagado:
           o cedente pode ter mandado apenas o incremental. Exclusao em
           carteira de credito precisa de ordem explicita, nunca de
           inferencia por ausencia. */

        /* ---------------- CONTRATO ----------------
           Chave natural: cedente + numero do contrato.
           Numero de contrato so e unico dentro do cedente, dois bancos
           diferentes podem usar a mesma numeracao. */
        ;WITH origem AS (
            SELECT s.cd_cedente,
                   LTRIM(RTRIM(s.nu_contrato))              AS nu_contrato,
                   d.id_devedor,
                   UPPER(LTRIM(RTRIM(s.cd_produto)))        AS cd_produto,
                   util.fn_converte_data(s.dt_contratacao)  AS dt_contratacao,
                   util.fn_converte_data(s.dt_vencimento)   AS dt_vencimento,
                   util.fn_converte_decimal(s.vl_principal) AS vl_principal,
                   util.fn_converte_decimal(s.vl_atualizado) AS vl_atualizado,
                   TRY_CONVERT(INT, s.qt_dias_atraso)       AS qt_dias_atraso,
                   ROW_NUMBER() OVER (
                       PARTITION BY s.cd_cedente, LTRIM(RTRIM(s.nu_contrato))
                           ORDER BY s.id_stg DESC)          AS rn
              FROM stg.contrato_carteira s
              JOIN crd.devedor d
                ON d.nu_documento = util.fn_somente_digitos(s.nu_documento)
             WHERE s.id_lote = @id_lote
               AND s.fl_valido = 1
        )
        MERGE crd.contrato AS alvo
        USING (SELECT * FROM origem WHERE rn = 1) AS org
           ON alvo.cd_cedente  = org.cd_cedente
          AND alvo.nu_contrato = org.nu_contrato
        /* Compara so o que muda com o tempo. dt_contratacao e
           vl_principal sao imutaveis por natureza: se mudarem, e erro na
           origem e nao atualizacao, entao nao entram no UPDATE. */
        WHEN MATCHED AND EXISTS (
                SELECT alvo.id_devedor, alvo.vl_atualizado, alvo.qt_dias_atraso, alvo.dt_vencimento
                EXCEPT
                SELECT org.id_devedor,  org.vl_atualizado,  org.qt_dias_atraso,  org.dt_vencimento)
            THEN UPDATE SET
                 alvo.id_devedor     = org.id_devedor,
                 alvo.vl_atualizado  = org.vl_atualizado,
                 alvo.qt_dias_atraso = org.qt_dias_atraso,
                 alvo.dt_vencimento  = org.dt_vencimento,
                 alvo.id_lote_origem = @id_lote,
                 alvo.dt_atualizacao = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (cd_cedente, nu_contrato, id_devedor, cd_produto, dt_contratacao,
                         dt_vencimento, vl_principal, vl_atualizado, qt_dias_atraso, id_lote_origem)
                 VALUES (org.cd_cedente, org.nu_contrato, org.id_devedor, org.cd_produto,
                         org.dt_contratacao, org.dt_vencimento, org.vl_principal,
                         org.vl_atualizado, org.qt_dias_atraso, @id_lote);

        SET @qt_ctr = @@ROWCOUNT;

        /* ---------------- PARCELA ----------------
           Chave natural: contrato + numero da parcela.
           O JOIN com crd.contrato ja resolve as parcelas de contratos
           carregados em lotes anteriores, nao so as deste lote. */
        ;WITH origem AS (
            SELECT c.id_contrato,
                   TRY_CONVERT(INT, p.nu_parcela)          AS nu_parcela,
                   util.fn_converte_data(p.dt_vencimento)  AS dt_vencimento,
                   util.fn_converte_decimal(p.vl_parcela)  AS vl_parcela,
                   UPPER(LTRIM(RTRIM(ISNULL(p.ds_situacao,'ABERTA')))) AS ds_situacao,
                   ROW_NUMBER() OVER (
                       PARTITION BY c.id_contrato, TRY_CONVERT(INT, p.nu_parcela)
                           ORDER BY p.id_stg DESC)         AS rn
              FROM stg.parcela_contrato p
              JOIN crd.contrato c
                ON c.cd_cedente  = p.cd_cedente
               AND c.nu_contrato = LTRIM(RTRIM(p.nu_contrato))
             WHERE p.id_lote = @id_lote
               AND p.fl_valido = 1
        )
        MERGE crd.parcela AS alvo
        USING (SELECT * FROM origem WHERE rn = 1) AS org
           ON alvo.id_contrato = org.id_contrato
          AND alvo.nu_parcela  = org.nu_parcela
        WHEN MATCHED AND EXISTS (
                SELECT alvo.dt_vencimento, alvo.vl_parcela, alvo.ds_situacao
                EXCEPT
                SELECT org.dt_vencimento,  org.vl_parcela,  org.ds_situacao)
            THEN UPDATE SET
                 alvo.dt_vencimento  = org.dt_vencimento,
                 alvo.vl_parcela     = org.vl_parcela,
                 alvo.ds_situacao    = org.ds_situacao,
                 alvo.id_lote_origem = @id_lote,
                 alvo.dt_atualizacao = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (id_contrato, nu_parcela, dt_vencimento, vl_parcela, ds_situacao, id_lote_origem)
                 VALUES (org.id_contrato, org.nu_parcela, org.dt_vencimento,
                         org.vl_parcela, org.ds_situacao, @id_lote);

        SET @qt_par = @@ROWCOUNT;

        UPDATE ctl.lote
           SET ds_status = 'CARREGADO',
               dt_fim    = SYSDATETIME()
         WHERE id_lote = @id_lote;

        COMMIT TRANSACTION;

        DECLARE @ms INT = DATEDIFF(MILLISECOND, @inicio, SYSDATETIME());
        DECLARE @msg VARCHAR(500) = CONCAT('Devedores: ', @qt_dev,
                                           ' | Contratos: ', @qt_ctr,
                                           ' | Parcelas: ', @qt_par);
        EXEC ctl.sp_registrar_log @id_lote, 'CARGA', @msg, @qt_ctr, @ms;
    END TRY
    BEGIN CATCH
        /* XACT_STATE() <> 0 cobre tanto transacao ativa quanto
           transacao condenada, que nao aceita COMMIT mas exige ROLLBACK. */
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE ctl.lote SET ds_status = 'ERRO', dt_fim = SYSDATETIME() WHERE id_lote = @id_lote;

        DECLARE @erro VARCHAR(500) = LEFT(ERROR_MESSAGE(), 500);
        EXEC ctl.sp_registrar_log @id_lote, 'CARGA', @erro;
        THROW;
    END CATCH
END
GO

/* =====================================================================
   exp.vw_retorno_lote

   O QUE FAZ
   Monta o arquivo de retorno: uma linha para cada registro recebido, com
   o desfecho e o motivo quando rejeitado.

   POR QUE ISSO EXISTE
   E a contrapartida do pipeline para o cedente. Ele mandou 3000 linhas,
   precisa saber quantas entraram e por que as outras nao entraram. Sem
   esse retorno, a conversa com o originador vira troca de email e
   planilha. E exatamente o mesmo papel do arquivo de retorno no CNAB.

   POR QUE STRING_AGG
   Um contrato pode ter varias rejeicoes. STRING_AGG junta os codigos
   numa unica celula, para que o arquivo continue com uma linha por
   contrato. Requer SQL Server 2017 ou superior.

   POR QUE OUTER APPLY E NAO JOIN
   OUTER APPLY permite executar a agregacao por linha e ainda assim
   manter os contratos aceitos, que nao tem nenhuma rejeicao. Com JOIN
   seria preciso agrupar antes e o resultado ficaria menos legivel.
   ===================================================================== */
CREATE OR ALTER VIEW exp.vw_retorno_lote
AS
SELECT s.id_lote,
       l.nm_arquivo,
       s.cd_cedente,
       s.nu_contrato,
       s.nu_documento,
       CASE WHEN s.fl_valido = 1 THEN 'ACEITO' ELSE 'REJEITADO' END AS ds_situacao,
       ISNULL(e.cd_erros, '')    AS cd_erros,
       ISNULL(e.ds_motivos, '')  AS ds_motivos
  FROM stg.contrato_carteira s
  JOIN ctl.lote l ON l.id_lote = s.id_lote
 OUTER APPLY (
        SELECT STRING_AGG(r.cd_erro, '+')   AS cd_erros,
               STRING_AGG(g.ds_regra, ' | ') AS ds_motivos
          FROM qua.registro_rejeitado r
          JOIN ctl.regra_validacao g ON g.cd_erro = r.cd_erro
         WHERE r.id_lote = s.id_lote
           AND r.ds_entidade = 'CONTRATO'
           AND r.id_stg = s.id_stg
           AND g.ds_severidade = 'BLOQUEIA'
      ) e;
GO

/* =====================================================================
   exp.sp_gerar_retorno

   Consumida pelo package de exportacao do SSIS (OLE DB Source -> Flat
   File Destination). Existe como procedure, e nao como consulta solta
   dentro do pacote, para que o formato do retorno seja versionado junto
   com o resto do codigo.
   ===================================================================== */
CREATE OR ALTER PROCEDURE exp.sp_gerar_retorno
    @id_lote INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT cd_cedente,
           nu_contrato,
           nu_documento,
           ds_situacao,
           cd_erros,
           ds_motivos
      FROM exp.vw_retorno_lote
     WHERE id_lote = @id_lote
     ORDER BY ds_situacao DESC, nu_contrato;
END
GO

/* =====================================================================
   qua.sp_reprocessar_lote

   O QUE FAZ
   Fecha o ciclo da quarentena: depois que o dado foi corrigido na
   origem, marca as rejeicoes como tratadas e roda validacao e carga de
   novo sobre o mesmo staging.

   POR QUE NAO PRECISA DO ARQUIVO DE NOVO
   Porque o conteudo bruto continua em stg. Esse e o retorno pratico da
   decisao de manter o staging em texto: reprocessar e barato e nao
   depende de o arquivo original ainda existir na pasta.
   ===================================================================== */
CREATE OR ALTER PROCEDURE qua.sp_reprocessar_lote
    @id_lote INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE qua.registro_rejeitado
       SET ds_status = 'CORRIGIDO'
     WHERE id_lote = @id_lote
       AND ds_status = 'PENDENTE';

    EXEC stg.sp_validar_lote @id_lote;
    EXEC crd.sp_carregar_lote @id_lote;

    EXEC ctl.sp_registrar_log @id_lote, 'REPROCESSAMENTO', 'Lote reprocessado a partir da quarentena';
END
GO

PRINT 'Procedures criadas com sucesso.';
GO
