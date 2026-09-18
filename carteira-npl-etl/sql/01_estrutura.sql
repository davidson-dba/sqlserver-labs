/* =====================================================================
   01_estrutura.sql
   Projeto: Pipeline de ingestao de carteira de credito inadimplente

   O QUE ESTE SCRIPT FAZ
   Cria o banco, os schemas e todas as tabelas do pipeline. E o unico
   script que precisa rodar uma vez so, antes de qualquer outra coisa.

   A IDEIA CENTRAL DO PROJETO
   Um arquivo de carteira cedida por um banco chega sujo por natureza:
   datas em tres formatos, valor ora com virgula ora com ponto, CPF com
   e sem mascara, linha duplicada, parcela apontando para contrato que
   nao existe. Carregar isso direto na base de negocio gera cobranca
   indevida. Rejeitar o arquivo inteiro por 3% de linha ruim trava a
   operacao. A solucao e separar o dado confiavel do duvidoso sem perder
   nenhum dos dois, e e isso que a estrutura abaixo sustenta.
   ===================================================================== */

IF DB_ID('CarteiraNPL') IS NULL
    CREATE DATABASE CarteiraNPL;
GO

USE CarteiraNPL;
GO

/* =====================================================================
   BLOCO 1 - SCHEMAS

   O QUE FAZ
   Separa os objetos por responsabilidade dentro do mesmo banco.

   POR QUE ASSIM
   Schema aqui nao e enfeite, e fronteira. Olhando o nome do objeto voce
   ja sabe em que estagio do pipeline ele vive e o que pode confiar nele:
     util = funcoes auxiliares, sem regra de negocio
     ctl  = controle de execucao, lotes e log
     stg  = staging bruto, espelho do arquivo, nada e confiavel aqui
     qua  = quarentena, o que foi rejeitado e por que
     crd  = modelo de negocio, so entra dado ja validado
     exp  = objetos de exportacao
   Tambem facilita permissao: da para dar leitura em crd para o time de
   negocio sem expor stg, que tem dado nao validado.

   ALTERNATIVA DESCARTADA
   Jogar tudo em dbo com prefixo no nome (stg_contrato, ctl_lote).
   Funciona, mas nao permite controlar permissao por camada e vira uma
   lista gigante de tabelas sem hierarquia no SSMS.
   ===================================================================== */
IF SCHEMA_ID('util') IS NULL EXEC('CREATE SCHEMA util');
IF SCHEMA_ID('ctl')  IS NULL EXEC('CREATE SCHEMA ctl');
IF SCHEMA_ID('stg')  IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('qua')  IS NULL EXEC('CREATE SCHEMA qua');
IF SCHEMA_ID('crd')  IS NULL EXEC('CREATE SCHEMA crd');
IF SCHEMA_ID('exp')  IS NULL EXEC('CREATE SCHEMA exp');
GO

/* =====================================================================
   BLOCO 2 - TABELAS DE DOMINIO

   O QUE FAZ
   Guarda as listas de valores validos: UF, produto e cedente.

   POR QUE ASSIM
   A validacao "esse produto existe?" vira um JOIN contra tabela em vez
   de um IN ('CARTAO','PESSOAL',...) escrito dentro da procedure.
   Quando o negocio passar a comprar um produto novo, alguem insere uma
   linha aqui. Ninguem precisa alterar codigo nem fazer deploy.

   ALTERNATIVA DESCARTADA
   CHECK CONSTRAINT com a lista fixa na coluna. E mais rapido de
   escrever, mas cada valor novo exige ALTER TABLE, o que em tabela
   grande e operacao com bloqueio.
   ===================================================================== */
IF OBJECT_ID('util.uf') IS NULL
CREATE TABLE util.uf (
    sg_uf CHAR(2) NOT NULL PRIMARY KEY,
    nm_uf VARCHAR(40) NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM util.uf)
INSERT INTO util.uf (sg_uf, nm_uf) VALUES
('AC','Acre'),('AL','Alagoas'),('AP','Amapa'),('AM','Amazonas'),
('BA','Bahia'),('CE','Ceara'),('DF','Distrito Federal'),('ES','Espirito Santo'),
('GO','Goias'),('MA','Maranhao'),('MT','Mato Grosso'),('MS','Mato Grosso do Sul'),
('MG','Minas Gerais'),('PA','Para'),('PB','Paraiba'),('PR','Parana'),
('PE','Pernambuco'),('PI','Piaui'),('RJ','Rio de Janeiro'),('RN','Rio Grande do Norte'),
('RS','Rio Grande do Sul'),('RO','Rondonia'),('RR','Roraima'),('SC','Santa Catarina'),
('SP','Sao Paulo'),('SE','Sergipe'),('TO','Tocantins');
GO

IF OBJECT_ID('crd.produto') IS NULL
CREATE TABLE crd.produto (
    cd_produto VARCHAR(20) NOT NULL PRIMARY KEY,
    ds_produto VARCHAR(60) NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM crd.produto)
INSERT INTO crd.produto (cd_produto, ds_produto) VALUES
('CARTAO','Cartao de credito'),
('PESSOAL','Credito pessoal'),
('VEICULO','Financiamento de veiculo'),
('CHEQUE','Cheque especial'),
('CONSIGNADO','Credito consignado');
GO

IF OBJECT_ID('crd.cedente') IS NULL
CREATE TABLE crd.cedente (
    cd_cedente   VARCHAR(10)  NOT NULL PRIMARY KEY,
    nm_cedente   VARCHAR(100) NOT NULL,
    nu_documento VARCHAR(14)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM crd.cedente)
INSERT INTO crd.cedente (cd_cedente, nm_cedente) VALUES
('237','Banco Cedente A'),
('341','Banco Cedente B'),
('033','Banco Cedente C');
GO

/* =====================================================================
   BLOCO 3 - CONTROLE DE EXECUCAO

   O QUE FAZ
   ctl.lote registra cada tentativa de carga de arquivo com contadores e
   status. ctl.log_etapa guarda a linha do tempo de cada execucao.

   POR QUE ASSIM
   Nenhuma linha entra no banco sem estar amarrada a um id_lote. Isso
   responde as tres perguntas que o suporte sempre recebe: de qual
   arquivo veio esse dado, quando entrou, e quantas linhas foram
   recusadas naquele dia. Sem lote, a resposta seria "nao sei".

   O DETALHE MAIS IMPORTANTE DO SCRIPT INTEIRO
   O indice unico filtrado sobre nm_arquivo quando o status e CARREGADO.
   Ele e a primeira camada de idempotencia: o banco fisicamente se recusa
   a ter dois lotes carregados com sucesso para o mesmo arquivo. Nao
   depende de ninguem lembrar de conferir antes.
   Indice filtrado (com WHERE) permite varias linhas ABERTO, ERRO ou
   CANCELADO para o mesmo arquivo, que e o comportamento desejado quando
   uma carga falha e precisa ser refeita.

   ALTERNATIVA DESCARTADA
   UNIQUE CONSTRAINT simples em nm_arquivo. Bloquearia tambem as
   tentativas que falharam, impedindo o reprocessamento legitimo.
   ===================================================================== */
IF OBJECT_ID('ctl.lote') IS NULL
CREATE TABLE ctl.lote (
    id_lote          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    nm_arquivo       VARCHAR(260) NOT NULL,
    cd_cedente       VARCHAR(10)  NOT NULL,
    dt_referencia    DATE         NULL,
    dt_inicio        DATETIME2(0) NOT NULL CONSTRAINT DF_lote_inicio DEFAULT SYSDATETIME(),
    dt_fim           DATETIME2(0) NULL,
    ds_status        VARCHAR(20)  NOT NULL CONSTRAINT DF_lote_status DEFAULT 'ABERTO',
    qt_linhas_lidas  INT NOT NULL CONSTRAINT DF_lote_lidas   DEFAULT 0,
    qt_linhas_ok     INT NOT NULL CONSTRAINT DF_lote_ok      DEFAULT 0,
    qt_linhas_rej    INT NOT NULL CONSTRAINT DF_lote_rej     DEFAULT 0,
    CONSTRAINT CK_lote_status CHECK (ds_status IN ('ABERTO','VALIDADO','CARREGADO','ERRO','CANCELADO'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_lote_arquivo_carregado')
CREATE UNIQUE INDEX UX_lote_arquivo_carregado
    ON ctl.lote (nm_arquivo)
    WHERE ds_status = 'CARREGADO';
GO

IF OBJECT_ID('ctl.log_etapa') IS NULL
CREATE TABLE ctl.log_etapa (
    id_log        BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_lote       INT NOT NULL,
    ds_etapa      VARCHAR(60) NOT NULL,
    ds_mensagem   VARCHAR(500) NULL,
    qt_linhas     INT NULL,
    ms_duracao    INT NULL,
    dt_registro   DATETIME2(0) NOT NULL CONSTRAINT DF_log_dt DEFAULT SYSDATETIME(),
    CONSTRAINT FK_log_lote FOREIGN KEY (id_lote) REFERENCES ctl.lote (id_lote)
);
GO

/* =====================================================================
   BLOCO 4 - REGRAS DE VALIDACAO PARAMETRIZADAS

   O QUE FAZ
   Cataloga cada regra de negocio com um codigo, a entidade a que se
   aplica, a descricao legivel e a severidade.

   POR QUE ASSIM
   Severidade e dado, nao codigo. Hoje "valor atualizado menor que o
   principal" e apenas um alerta e a linha entra mesmo assim. Se amanha
   o negocio decidir que isso bloqueia, alguem faz um UPDATE nesta tabela
   e o comportamento muda, sem deploy. A procedure de validacao consulta
   esta tabela para decidir o que bloqueia, entao ela nunca precisa saber
   as regras de cor.

   Alem disso, ds_regra e a mensagem que o time de negocio le no relatorio
   de rejeicao. Manter esse texto no banco e nao espalhado em CASE dentro
   de procedure evita que a mesma regra tenha tres redacoes diferentes.

   ALTERNATIVA DESCARTADA
   Codigo de erro escrito direto como literal na procedure. E o jeito
   mais rapido e o mais comum, mas a cada regra nova voce mexe em codigo
   testado e o relatorio para o negocio precisa ser mantido a parte.
   ===================================================================== */
IF OBJECT_ID('ctl.regra_validacao') IS NULL
CREATE TABLE ctl.regra_validacao (
    cd_erro     VARCHAR(10)  NOT NULL PRIMARY KEY,
    ds_entidade VARCHAR(20)  NOT NULL,
    ds_regra    VARCHAR(200) NOT NULL,
    ds_severidade VARCHAR(10) NOT NULL,
    fl_ativo    BIT NOT NULL CONSTRAINT DF_regra_ativo DEFAULT 1,
    CONSTRAINT CK_regra_sev CHECK (ds_severidade IN ('BLOQUEIA','ALERTA'))
);
GO

IF NOT EXISTS (SELECT 1 FROM ctl.regra_validacao)
INSERT INTO ctl.regra_validacao (cd_erro, ds_entidade, ds_regra, ds_severidade) VALUES
('E001','CONTRATO','CPF ou CNPJ invalido pelo digito verificador','BLOQUEIA'),
('E002','CONTRATO','Nome do devedor ausente ou com menos de 3 caracteres','BLOQUEIA'),
('E003','CONTRATO','Data de contratacao invalida ou nao convertivel','BLOQUEIA'),
('E004','CONTRATO','Data de contratacao maior que a data atual','BLOQUEIA'),
('E005','CONTRATO','Valor principal invalido ou menor ou igual a zero','BLOQUEIA'),
('E006','CONTRATO','Valor atualizado menor que o valor principal','ALERTA'),
('E007','CONTRATO','Dias de atraso invalido ou negativo','BLOQUEIA'),
('E008','CONTRATO','UF fora da tabela de unidades federativas','ALERTA'),
('E009','CONTRATO','Produto fora do catalogo','BLOQUEIA'),
('E010','CONTRATO','Contrato duplicado dentro do mesmo lote','BLOQUEIA'),
('E020','PARCELA','Parcela orfa, contrato nao existe no lote nem na base','BLOQUEIA'),
('E021','PARCELA','Data de vencimento invalida','BLOQUEIA'),
('E022','PARCELA','Valor da parcela invalido ou menor ou igual a zero','BLOQUEIA'),
('E023','PARCELA','Numero da parcela invalido','BLOQUEIA'),
('E024','PARCELA','Parcela duplicada dentro do mesmo lote','BLOQUEIA');
GO

/* =====================================================================
   BLOCO 5 - STAGING

   O QUE FAZ
   Recebe o conteudo do arquivo exatamente como ele veio.

   POR QUE TODAS AS COLUNAS SAO VARCHAR
   Esta e a decisao mais importante do projeto e a que mais rende
   conversa numa entrevista. Se o staging tivesse dt_contratacao como
   DATE, uma unica linha com "31/02/2024" derrubaria a carga inteira do
   arquivo, e as outras 2999 linhas boas ficariam de fora por causa de
   uma. Com tudo em texto, o arquivo entra sempre. A conversao vira uma
   regra de negocio que roda depois, e quando ela falha o resultado e uma
   linha na quarentena, nao um pacote abortado.
   O efeito colateral bom: da para reprocessar sem reler o arquivo, porque
   o conteudo bruto continua no banco.

   POR QUE EXISTE id_stg IDENTITY
   E o numero da linha. O SSIS nao fornece um contador de linha de graca,
   e a gente precisa de uma forma de apontar exatamente qual registro foi
   rejeitado. O IDENTITY resolve sem nenhum esforco no pacote.

   POR QUE fl_valido E BIT NULL E NAO BIT NOT NULL DEFAULT 0
   Tres estados sao diferentes: NULL significa "ainda nao validado",
   1 significa "passou", 0 significa "reprovado". Se o default fosse 0,
   nao daria para distinguir linha reprovada de linha que nunca passou
   pela validacao, o que esconderia falha de orquestracao.

   SOBRE O INDICE
   IX_stgc_lote com INCLUDE (fl_valido) existe porque praticamente toda
   consulta do pipeline filtra por id_lote e le fl_valido. Com a coluna
   incluida no indice, a consulta se resolve sem ir ate a tabela base.
   ===================================================================== */
IF OBJECT_ID('stg.contrato_carteira') IS NULL
CREATE TABLE stg.contrato_carteira (
    id_stg            BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_lote           INT NOT NULL,
    cd_cedente        VARCHAR(50)  NULL,
    nu_contrato       VARCHAR(50)  NULL,
    nu_documento      VARCHAR(50)  NULL,
    nm_devedor        VARCHAR(150) NULL,
    dt_nascimento     VARCHAR(20)  NULL,
    cd_produto        VARCHAR(50)  NULL,
    dt_contratacao    VARCHAR(20)  NULL,
    dt_vencimento     VARCHAR(20)  NULL,
    vl_principal      VARCHAR(30)  NULL,
    vl_atualizado     VARCHAR(30)  NULL,
    qt_dias_atraso    VARCHAR(20)  NULL,
    sg_uf             VARCHAR(20)  NULL,
    nu_telefone       VARCHAR(30)  NULL,
    ds_email          VARCHAR(120) NULL,
    fl_valido         BIT NULL,
    dt_carga          DATETIME2(0) NOT NULL CONSTRAINT DF_stgc_dt DEFAULT SYSDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_stgc_lote')
CREATE INDEX IX_stgc_lote ON stg.contrato_carteira (id_lote) INCLUDE (fl_valido);
GO

IF OBJECT_ID('stg.parcela_contrato') IS NULL
CREATE TABLE stg.parcela_contrato (
    id_stg          BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_lote         INT NOT NULL,
    cd_cedente      VARCHAR(50) NULL,
    nu_contrato     VARCHAR(50) NULL,
    nu_parcela      VARCHAR(20) NULL,
    dt_vencimento   VARCHAR(20) NULL,
    vl_parcela      VARCHAR(30) NULL,
    ds_situacao     VARCHAR(30) NULL,
    fl_valido       BIT NULL,
    dt_carga        DATETIME2(0) NOT NULL CONSTRAINT DF_stgp_dt DEFAULT SYSDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_stgp_lote')
CREATE INDEX IX_stgp_lote ON stg.parcela_contrato (id_lote) INCLUDE (fl_valido);
GO

/* =====================================================================
   BLOCO 6 - QUARENTENA

   O QUE FAZ
   Guarda uma linha para cada violacao de regra encontrada, apontando
   para o registro de staging que a causou.

   POR QUE ASSIM
   Registro rejeitado nao e lixo, e insumo. Quem precisa dele e o time de
   negocio, para corrigir na origem e cobrar do cedente um arquivo melhor.
   Por isso a rejeicao vira dado consultavel, e nao um email de erro ou
   uma linha perdida num log de texto.

   POR QUE UMA LINHA POR VIOLACAO, E NAO UMA POR REGISTRO
   Um mesmo contrato pode quebrar tres regras ao mesmo tempo. Se a
   quarentena tivesse uma coluna "motivo", so caberia o primeiro erro
   encontrado e o usuario corrigiria um problema por vez, num vai e volta
   sem fim. Com uma linha por violacao, ele ve todos de uma vez.

   POR QUE ds_status
   PENDENTE, CORRIGIDO ou DESCARTADO. Permite saber o que ja foi tratado
   e o que ainda esta em aberto, e da base para o relatorio de qualidade
   por cedente.

   SOBRE AS FOREIGN KEYS
   A FK para ctl.regra_validacao garante que nao existe rejeicao com
   codigo de erro inventado. E barato e evita divergencia entre o codigo
   gravado e o catalogo.
   ===================================================================== */
IF OBJECT_ID('qua.registro_rejeitado') IS NULL
CREATE TABLE qua.registro_rejeitado (
    id_rejeicao   BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_lote       INT NOT NULL,
    ds_entidade   VARCHAR(20) NOT NULL,
    id_stg        BIGINT NOT NULL,
    ds_chave      VARCHAR(120) NULL,
    cd_erro       VARCHAR(10) NOT NULL,
    ds_valor      VARCHAR(200) NULL,
    ds_status     VARCHAR(20) NOT NULL CONSTRAINT DF_rej_status DEFAULT 'PENDENTE',
    dt_rejeicao   DATETIME2(0) NOT NULL CONSTRAINT DF_rej_dt DEFAULT SYSDATETIME(),
    CONSTRAINT FK_rej_lote  FOREIGN KEY (id_lote) REFERENCES ctl.lote (id_lote),
    CONSTRAINT FK_rej_regra FOREIGN KEY (cd_erro) REFERENCES ctl.regra_validacao (cd_erro),
    CONSTRAINT CK_rej_status CHECK (ds_status IN ('PENDENTE','CORRIGIDO','DESCARTADO'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_rej_lote')
CREATE INDEX IX_rej_lote ON qua.registro_rejeitado (id_lote, ds_entidade, id_stg);
GO

/* =====================================================================
   BLOCO 7 - MODELO DE NEGOCIO

   O QUE FAZ
   As tabelas finais, onde so entra dado que passou pela validacao.

   O CONCEITO DE CHAVE NATURAL X CHAVE SUBSTITUTA
   Cada tabela tem duas chaves com papeis diferentes:
     - a substituta (id_devedor, id_contrato), um IDENTITY sem significado
       de negocio, usada nos relacionamentos porque e pequena, estavel e
       nunca muda
     - a natural (nu_documento no devedor, cd_cedente + nu_contrato no
       contrato), que e a identidade real do registro no mundo
   A UNIQUE CONSTRAINT sobre a chave natural e o que torna a carga
   incremental possivel: e por ela que o MERGE decide se a linha que
   chegou e a mesma que ja existe. Sem isso, toda carga viraria insercao
   e o mesmo contrato apareceria varias vezes.

   POR QUE dt_inclusao E dt_atualizacao
   Permitem responder "esse contrato entrou quando e mudou pela ultima vez
   quando", que e a primeira pergunta de qualquer investigacao de
   divergencia de saldo.

   POR QUE id_lote_origem
   Rastreabilidade ate o arquivo. Se um cedente mandar um arquivo errado,
   da para listar exatamente o que aquele arquivo alterou.

   SOBRE tp_pessoa
   Derivado do tamanho do documento (11 = fisica, 14 = juridica) no momento
   da carga. Fica gravado para nao precisar recalcular em toda consulta.
   ===================================================================== */
IF OBJECT_ID('crd.devedor') IS NULL
CREATE TABLE crd.devedor (
    id_devedor    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    nu_documento  VARCHAR(14)  NOT NULL,
    tp_pessoa     CHAR(1)      NOT NULL,
    nm_devedor    VARCHAR(150) NOT NULL,
    dt_nascimento DATE         NULL,
    sg_uf         CHAR(2)      NULL,
    nu_telefone   VARCHAR(20)  NULL,
    ds_email      VARCHAR(120) NULL,
    dt_inclusao   DATETIME2(0) NOT NULL CONSTRAINT DF_dev_inc DEFAULT SYSDATETIME(),
    dt_atualizacao DATETIME2(0) NULL,
    CONSTRAINT UQ_devedor_documento UNIQUE (nu_documento),
    CONSTRAINT CK_devedor_tp CHECK (tp_pessoa IN ('F','J'))
);
GO

IF OBJECT_ID('crd.contrato') IS NULL
CREATE TABLE crd.contrato (
    id_contrato     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    cd_cedente      VARCHAR(10) NOT NULL,
    nu_contrato     VARCHAR(50) NOT NULL,
    id_devedor      INT NOT NULL,
    cd_produto      VARCHAR(20) NOT NULL,
    dt_contratacao  DATE NOT NULL,
    dt_vencimento   DATE NULL,
    vl_principal    DECIMAL(18,2) NOT NULL,
    vl_atualizado   DECIMAL(18,2) NOT NULL,
    qt_dias_atraso  INT NOT NULL,
    id_lote_origem  INT NOT NULL,
    dt_inclusao     DATETIME2(0) NOT NULL CONSTRAINT DF_ctr_inc DEFAULT SYSDATETIME(),
    dt_atualizacao  DATETIME2(0) NULL,
    CONSTRAINT UQ_contrato_natural UNIQUE (cd_cedente, nu_contrato),
    CONSTRAINT FK_contrato_devedor FOREIGN KEY (id_devedor) REFERENCES crd.devedor (id_devedor),
    CONSTRAINT FK_contrato_produto FOREIGN KEY (cd_produto) REFERENCES crd.produto (cd_produto),
    CONSTRAINT FK_contrato_cedente FOREIGN KEY (cd_cedente) REFERENCES crd.cedente (cd_cedente)
);
GO

/* Indice de apoio: a consulta mais frequente do negocio e "tudo o que
   esse devedor deve". As colunas de valor e atraso vao no INCLUDE para
   que o total saia do proprio indice, sem lookup na tabela. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_contrato_devedor')
CREATE INDEX IX_contrato_devedor ON crd.contrato (id_devedor) INCLUDE (vl_atualizado, qt_dias_atraso);
GO

IF OBJECT_ID('crd.parcela') IS NULL
CREATE TABLE crd.parcela (
    id_parcela     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_contrato    INT NOT NULL,
    nu_parcela     INT NOT NULL,
    dt_vencimento  DATE NOT NULL,
    vl_parcela     DECIMAL(18,2) NOT NULL,
    ds_situacao    VARCHAR(20) NOT NULL,
    id_lote_origem INT NOT NULL,
    dt_inclusao    DATETIME2(0) NOT NULL CONSTRAINT DF_par_inc DEFAULT SYSDATETIME(),
    dt_atualizacao DATETIME2(0) NULL,
    CONSTRAINT UQ_parcela_natural UNIQUE (id_contrato, nu_parcela),
    CONSTRAINT FK_parcela_contrato FOREIGN KEY (id_contrato) REFERENCES crd.contrato (id_contrato)
);
GO

PRINT 'Estrutura criada com sucesso.';
GO
